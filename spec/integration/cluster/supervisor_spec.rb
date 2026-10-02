# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../../fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Linux supervised cluster", skip: RUBY_PLATFORM.include?("linux") ? false : "multiprocess reuseport requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-cluster") do |dir|
      @events_path = File.join(dir, "events.jsonl")
      example.run
    ensure
      @cluster&.stop(timeout: 5)
    end
  end

  def start_cluster(**env)
    listener = TCPServer.new("127.0.0.1", 0)
    @address = "127.0.0.1:#{listener.addr[1]}"
    listener.close
    @cluster = Gritz::Testing::Cluster.new(
      config_path: File.expand_path("config.rb", __dir__),
      env: { "CLUSTER_BIND" => @address, "CLUSTER_EVENTS" => @events_path }.merge(env.transform_keys(&:to_s))
    ).start
  end

  def stub = Helloworld::Greeter::Stub.new(@address, :this_channel_is_insecure)
  def message(name) = Helloworld::HelloRequest.new(name: name)
  def events = File.exist?(@events_path) ? File.readlines(@events_path).map { |line| JSON.parse(line, symbolize_names: true) } : []
  def worker_pids = @cluster.workers.map { |worker| worker.fetch(:pid) }

  def expect_reaped(pids)
    pids.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
  end

  it "serves all four RPC forms after preloading and running per-worker hooks" do
    start_cluster.wait_until(workers: 2)
    client = stub
    expect(client.say_hello(message("Ruby"), deadline: Time.now + 5).message).to eq("Hello, Ruby")
    expect(client.record_names([message("a"), message("b")], deadline: Time.now + 5).count).to eq(2)
    expect(client.list_greetings(message("x"), deadline: Time.now + 5).map(&:message)).to eq(%w[x:0 x:1 x:2])
    expect(client.chat([message("a"), message("b")], deadline: Time.now + 5).map(&:message)).to eq(%w[A B])
    pids = worker_pids
    @cluster.stop
    expect(events.count { |event| event[:event] == "preload" }).to eq(1)
    expect(events.select { |event| event[:event] == "boot" }.map { |event| event[:pid] }.sort).to eq(pids.sort)
    expect(events.select { |event| event[:event] == "shutdown" }.map { |event| event[:pid] }.sort).to eq(pids.sort)
    expect_reaped(pids)
  end

  it "marks the master draining and preserves an in-flight RPC during TERM" do
    start_cluster.wait_until(workers: 2)
    pids = worker_pids
    client = stub
    caller = Thread.new { client.say_hello(message("slow:0.5"), deadline: Time.now + 5) }
    @cluster.wait_until { |status| status[:workers].any? { |worker| worker[:inflight].to_i.positive? } }
    @cluster.signal("TERM").wait_until(state: "draining")
    expect(caller.value.message).to eq("Hello, slow:0.5")
    expect(@cluster.wait(timeout: 5)).to be_success
    expect_reaped(pids)
  ensure
    caller&.join(5)
  end

  it "reaps and replaces a SIGKILLed worker within one second" do
    start_cluster.wait_until(workers: 2)
    old = worker_pids
    killed = old.first
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @cluster.signal("KILL", pid: killed).wait_until(workers: 2) do |status|
      status[:workers].none? { |worker| worker[:pid] == killed }
    end
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(worker_pids & old).to eq(old - [killed])
    expect_reaped([killed])
    expect(stub.say_hello(message("replacement"), deadline: Time.now + 5).message).to eq("Hello, replacement")
  end

  it "resizes with TTIN/TTOU and remains available after HUP" do
    start_cluster.wait_until(workers: 2)
    @cluster.signal("TTIN").wait_until(workers: 3)
    enlarged = worker_pids
    @cluster.signal("TTOU").wait_until(workers: 2)
    expect_reaped(enlarged - worker_pids)
    @cluster.signal("HUP")
    expect(stub.say_hello(message("reopened"), deadline: Time.now + 5).message).to eq("Hello, reopened")
  end

  it "reopens a rotated file logger in the master and its serving worker after HUP" do
    listener = TCPServer.new("127.0.0.1", 0)
    @address = "127.0.0.1:#{listener.addr[1]}"
    listener.close
    path = File.join(File.dirname(@events_path), "gritz.log")
    source = <<~RUBY
      require "logger"
      config = Gritz::Configuration.load(path: ARGV.fetch(0))
      logger = Logger.new(ENV.fetch("CLUSTER_LOG"))
      exit Gritz::Supervisor::Master.new(config, logger: logger, status_io: IO.for_fd(3)).run
    RUBY
    command = [RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-rgritz/core", "-rgritz/native", "-e", source,
               File.expand_path("config.rb", __dir__)]
    @cluster = Gritz::Testing::Cluster.new(config_path: File.expand_path("config.rb", __dir__), command: command,
                                           env: { "CLUSTER_BIND" => @address, "CLUSTER_LOG" => path }).start.wait_until(workers: 2)
    client = stub
    expect(client.say_hello(message("before rotation"), metadata: { "x-request-id" => "before-rotation" }, deadline: Time.now + 5).message)
      .to eq("Hello, before rotation")
    @cluster.wait_until { File.read(path).include?("before-rotation") }
    File.rename(path, "#{path}.1")
    @cluster.signal("HUP").wait_until { File.exist?(path) && File.read(path).include?("Log reopened") }
    @cluster.wait_until do
      client.say_hello(message("after rotation"), metadata: { "x-request-id" => "after-rotation" }, deadline: Time.now + 5)
      File.read(path).include?("after-rotation")
    end
    expect(File.read(path)).not_to include("before-rotation")
  end

  it "replaces a worker whose stopped process cannot send heartbeats" do
    start_cluster.wait_until(workers: 2)
    stopped = worker_pids.first
    @cluster.signal("STOP", pid: stopped).wait_until(workers: 2, timeout: 5) do |status|
      status[:workers].none? { |worker| worker[:pid] == stopped }
    end
    expect_reaped([stopped])
    expect(stub.say_hello(message("healthy"), deadline: Time.now + 5).message).to eq("Hello, healthy")
  end

  it "rejects TTIN for an ephemeral reuseport listener and preserves the existing endpoint" do
    start_cluster(CLUSTER_WORKERS: "1", CLUSTER_BIND: "127.0.0.1:0").wait_until(workers: 1)
    worker = @cluster.workers.first.dup
    @address = "127.0.0.1:#{worker.fetch(:port)}"
    @cluster.signal("TTIN").wait_until(workers: 1) { @cluster.logs.include?("Cannot add a reuseport worker with port 0") }
    expect(@cluster.workers.first).to include(pid: worker.fetch(:pid), port: worker.fetch(:port))
    expect(stub.say_hello(message("still serving"), deadline: Time.now + 5).message).to eq("Hello, still serving")
  end

  it "kills and replaces a worker that never finishes its boot hook" do
    start_cluster(CLUSTER_WORKERS: "1", CLUSTER_BOOT_MODE: "hang", GRITZ_WORKER_BOOT_TIMEOUT: "0.3")
      .wait_until(state: nil, workers: 1)
    stuck = worker_pids.first
    @cluster.wait_until(state: nil, workers: 1, timeout: 5) { |status| status[:workers].first[:pid] != stuck }
    expect_reaped([stuck])
  end

  it "uses QUIT immediately and forcefully ends an overdue graceful shutdown" do
    start_cluster.wait_until(workers: 2)
    pids = worker_pids
    @cluster.signal("QUIT")
    expect(@cluster.wait(timeout: 2)).to be_success
    expect_reaped(pids)
    @cluster.stop

    start_cluster(GRITZ_SHUTDOWN_TIMEOUT: "0.2").wait_until(workers: 2)
    pids = worker_pids
    caller = Thread.new do
      stub.say_hello(message("hang"), deadline: Time.now + 5)
    rescue GRPC::BadStatus => e
      e
    end
    @cluster.wait_until { |status| status[:workers].any? { |worker| worker[:inflight].to_i.positive? } }
    @cluster.signal("TERM")
    expect(@cluster.wait(timeout: 2)).to be_success
    expect(caller.value).to be_a(GRPC::BadStatus)
    expect_reaped(pids)
  ensure
    caller&.join(5)
  end

  it "fails startup and cleans up when an application boot hook raises" do
    start_cluster(CLUSTER_BOOT_MODE: "fail")
    expect(@cluster.wait(timeout: 5).exitstatus).to eq(1)
    pids = events.select { |event| event[:event] == "boot" }.map { |event| event[:pid] }
    @cluster.stop
    expect(@cluster.logs).to include("requested boot failure")
    expect(pids).not_to be_empty
    expect_reaped(pids)
  end

  it "cleans up without running inherited master code when a boot hook calls exit" do
    start_cluster(CLUSTER_BOOT_MODE: "exit")
    expect(@cluster.wait(timeout: 5).exitstatus).to eq(1)
    pids = events.select { |event| event[:event] == "boot" }.map { |event| event[:pid] }
    expect(pids).not_to be_empty
    expect_reaped(pids)
  end
end
