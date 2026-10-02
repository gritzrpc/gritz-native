# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "grpc/health/v1/health_services_pb"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Single-process CLI lifecycle" do
  after { @cluster&.stop(timeout: 3) }

  def free_address
    listener = TCPServer.new("127.0.0.1", 0)
    "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
  end

  def start_cluster
    @address = free_address
    @admin = free_address
    @cluster = Gritz::Testing::Cluster.new(
      config_path: File.expand_path("integration/cluster/config.rb", __dir__),
      env: { "CLUSTER_WORKERS" => "0", "CLUSTER_BIND" => @address, "GRITZ_ADMIN_BIND" => @admin,
             "GRITZ_DRAIN_DELAY" => "0.3", "GRITZ_SHUTDOWN_TIMEOUT" => "0.6", "GRITZ_STATUS_INTERVAL" => "0.01" }
    ).start.wait_until(workers: 1)
  end

  def admin(path)
    Net::HTTP.start("127.0.0.1", @admin.split(":").last.to_i, nil, open_timeout: 1, read_timeout: 1) { |http| http.get(path) }
  end

  def stub = Helloworld::Greeter::Stub.new(@address, :this_channel_is_insecure)
  def call(name) = stub.say_hello(Helloworld::HelloRequest.new(name:), deadline: Time.now + 2).message

  it "keeps readiness and RPC service when the single serving process receives USR1 directly" do
    start_cluster
    @cluster.signal("USR1", pid: @cluster.master_pid).wait_until(workers: 1, timeout: 2) do
      @cluster.logs.include?("USR1 requires workers > 0")
    end
    expect(admin("/readyz").code).to eq("200")
    expect(call("after USR1")).to eq("Hello, after USR1")
  end

  it "serves probes and RPCs while draining and gives in-flight work its shutdown grace after the delay" do
    start_cluster
    health = Grpc::Health::V1::Health::Stub.new(@address, :this_channel_is_insecure)
    request = Grpc::Health::V1::HealthCheckRequest.new
    expect(health.check(request, deadline: Time.now + 1).status).to eq(:SERVING)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @cluster.signal("TERM").wait_until(state: "draining", timeout: 2) do |snapshot|
      snapshot[:workers].first&.fetch(:state) == "draining"
    end
    expect(admin("/livez").code).to eq("200")
    expect(admin("/readyz").code).to eq("503")
    expect(JSON.parse(admin("/status").body).fetch("state")).to eq("draining")
    expect(health.check(request, deadline: Time.now + 1).status).to eq(:NOT_SERVING)
    expect(call("during drain")).to eq("Hello, during drain")
    @cluster.wait_until(state: "draining", timeout: 1) do
      admin("/metrics").body.include?('rpc_server_duration_seconds_count{rpc_service="helloworld.Greeter",rpc_method="SayHello",rpc_grpc_status_code="0"} 1')
    end
    expect(call("slow:0.5")).to eq("Hello, slow:0.5")
    expect(@cluster.wait(timeout: 3)).to be_success
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.3
  end
end
