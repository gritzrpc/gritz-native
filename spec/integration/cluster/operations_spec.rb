# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "tmpdir"
require "grpc/health/v1/health_services_pb"

$LOAD_PATH.unshift(File.expand_path("../../fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Linux production operations", skip: RUBY_PLATFORM.include?("linux") ? false : "reuseport requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-operations") do |directory|
      @directory = directory
      example.run
    ensure
      @cluster&.stop(timeout: 5)
    end
  end

  def free_address
    listener = TCPServer.new("127.0.0.1", 0)
    "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
  end

  def start_cluster(**env)
    @address = free_address
    @admin = free_address
    @cluster = Gritz::Testing::Cluster.new(
      config_path: File.expand_path("config.rb", __dir__),
      env: { "CLUSTER_BIND" => @address, "GRITZ_ADMIN_BIND" => @admin }.merge(env.transform_keys(&:to_s))
    ).start.wait_until(workers: Integer(env.fetch(:CLUSTER_WORKERS, 2)))
  end

  def stub
    Helloworld::Greeter::Stub.new(@address, :this_channel_is_insecure,
                                  channel_args: { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 })
  end

  def call(client, name) = client.say_hello(Helloworld::HelloRequest.new(name: name), deadline: Time.now + 3).message
  def pids = @cluster.workers.map { |worker| worker.fetch(:pid) }

  def admin(path)
    Net::HTTP.start("127.0.0.1", @admin.split(":").last.to_i, nil, open_timeout: 1, read_timeout: 1) do |http|
      http.get(path)
    end
  end

  def rpc_count
    admin("/metrics").body.lines.grep(/\Arpc_server_duration_seconds_count\{/).sum { |line| Integer(line.split.last) }
  end

  def expect_reaped(old)
    old.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
  end

  def write_revision(path, revision, failing: false)
    source = File.read(File.expand_path("config.rb", __dir__))
                 .sub('File.expand_path("../../fixtures/hello", __dir__)', File.expand_path("../../fixtures/hello", __dir__).inspect)
    source << <<~RUBY
      class ClusterGreeterController
        def say_hello = Helloworld::HelloReply.new(message: #{revision.inspect})
      end
    RUBY
    source << 'on_worker_boot { raise "requested revision failure" }' if failing
    File.write(path, source)
  end

  it "aggregates every worker's RPCs and retains totals after a phased restart" do
    start_cluster
    old = pids
    counts = Hash.new(0)
    @cluster.wait_until do
      16.times { counts[Integer(call(stub, "pid"))] += 1 } unless (old - counts.keys).empty?
      (old - counts.keys).empty? && @cluster.workers.sum { |worker| worker[:requests_total] } == counts.values.sum
    end
    before = counts.values.sum
    @cluster.wait_until { rpc_count == before }
    expect(admin("/livez").code).to eq "200"
    expect(admin("/readyz").code).to eq "200"
    expect(JSON.parse(admin("/status").body).fetch("workers").map { |worker| worker.fetch("pid") }.sort).to eq(old.sort)

    @cluster.signal("USR1").wait_until(workers: 2) do |status|
      !status[:phased_restart] && !old.intersect?(pids)
    end
    expect_reaped(old)
    expect(rpc_count).to eq before
    expect(call(stub, "after restart")).to eq "Hello, after restart"
    @cluster.wait_until { rpc_count == before + 1 }
    expect(admin("/metrics").body).to include('gritz_worker_restarts_total{reason="phased_restart"} 2')
  end

  it "recycles a worker after its configured request count without losing metrics" do
    start_cluster(CLUSTER_WORKERS: "1", GRITZ_WORKER_RECYCLE: '{"max_requests":3,"jitter":0}')
    old = pids
    client = stub
    3.times { expect(Integer(call(client, "pid"))).to eq old.first }
    @cluster.wait_until(workers: 1) { !old.intersect?(pids) }
    expect_reaped(old)
    @cluster.wait_until { rpc_count == 3 }
    expect(admin("/metrics").body).to include('gritz_worker_restarts_total{reason="max_requests"} 1')
    expect(call(stub, "recycled")).to eq "Hello, recycled"
  end

  it "recycles a worker after its configured lifetime" do
    start_cluster(CLUSTER_WORKERS: "1", GRITZ_WORKER_RECYCLE: '{"max_lifetime":0.7,"jitter":0}')
    old = pids
    @cluster.wait_until(workers: 1, timeout: 5) { !old.intersect?(pids) }
    expect_reaped(old)
    expect(admin("/metrics").body).to include('gritz_worker_restarts_total{reason="max_lifetime"} 1')
    expect(call(stub, "new lifetime")).to eq "Hello, new lifetime"
  end

  it "links user health checks to HTTP readiness, diagnostics, and gRPC health before draining" do
    path = File.join(@directory, "dependency")
    File.write(path, "ready")
    start_cluster(CLUSTER_WORKERS: "1", CLUSTER_HEALTH_FILE: path)
    client = Grpc::Health::V1::Health::Stub.new(@address, :this_channel_is_insecure)
    request = Grpc::Health::V1::HealthCheckRequest.new
    File.write(path, "unhealthy")
    @cluster.wait_until(state: nil) { |status| status[:workers].first[:healthy] == false && admin("/readyz").code == "503" }
    expect(admin("/livez").code).to eq "200"
    expect(admin("/readyz").code).to eq "503"
    expect(client.check(request, deadline: Time.now + 2).status).to eq :NOT_SERVING
    expect(@cluster.workers.first.fetch(:checks)).to eq(dependency: false)
    File.write(path, "ready")
    @cluster.wait_until { |status| status[:workers].first[:healthy] && admin("/readyz").code == "200" }
    operation = client.watch(request, deadline: Time.now + 3, return_op: true)
    replies = operation.execute
    expect(replies.next.status).to eq :SERVING
    @cluster.signal("TERM").wait_until(state: "draining")
    expect(admin("/readyz").code).to eq "503"
    expect(replies.next.status).to eq :NOT_SERVING
    expect { replies.next }.to raise_error(StopIteration)
    expect(@cluster.wait).to be_success
  ensure
    operation&.cancel
  end

  it "reexecs fresh application code across three generations and rolls back a failed replacement" do
    path = File.join(@directory, "config.rb")
    events_path = File.join(@directory, "events.jsonl")
    @address = free_address
    @admin = free_address
    write_revision(path, "a")
    @cluster = Gritz::Testing::Cluster.new(config_path: path,
                                           env: { "CLUSTER_BIND" => @address, "GRITZ_ADMIN_BIND" => @admin,
                                                  "CLUSTER_EVENTS" => events_path }).start.wait_until(workers: 2)
    launcher = @cluster.pid
    expect(call(stub, "revision")).to eq "a"
    first = pids
    write_revision(path, "b")
    @cluster.signal("USR2").wait_until(workers: 2) do |status|
      status.dig(:reexec, :state) == "complete" && !first.intersect?(pids) && call(stub, "revision") == "b"
    end
    second = pids
    expect_reaped(first)
    write_revision(path, "broken", failing: true)
    @cluster.signal("USR2").wait_until(workers: 2) do |status|
      status.dig(:reexec, :state) == "failed" && @cluster.logs.include?("requested revision failure") &&
        pids.sort == second.sort && call(stub, "revision") == "b"
    end
    write_revision(path, "c")
    @cluster.signal("USR2").wait_until(workers: 2) do |status|
      status.dig(:reexec, :state) == "complete" && !second.intersect?(pids) && call(stub, "revision") == "c"
    end
    expect(@cluster.pid).to eq launcher
    expect_reaped(second)
    booted = File.readlines(events_path).map { |line| JSON.parse(line) }.select { |event| event["event"] == "boot" }
                 .map { |event| event.fetch("pid") }
    expect_reaped(booted - pids)
    expect(admin("/readyz").code).to eq "200"
  end
end
