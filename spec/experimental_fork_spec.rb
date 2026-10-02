# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"
require "json"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Experimental native fork support", skip: RUBY_PLATFORM.include?("linux") ? false : "grpc fork support requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-experimental-fork") do |dir|
      @events_path = File.join(dir, "events.jsonl")
      example.run
    ensure
      @cluster&.stop(timeout: 5)
    end
  end

  def with_upstream
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service

      def say_hello = Helloworld::HelloReply.new(message: "upstream:#{request.message.name}")
    end
    Gritz::Testing::Server.start(controllers: [controller]) { |server| yield server.address }
  end

  def start_cluster(upstream, flag: "1")
    listener = TCPServer.new("127.0.0.1", 0)
    @address = "127.0.0.1:#{listener.addr[1]}"
    listener.close
    @cluster = Gritz::Testing::Cluster.new(
      config_path: File.expand_path("fixtures/experimental_fork/config.rb", __dir__),
      env: { "GRPC_ENABLE_FORK_SUPPORT" => flag, "EXPERIMENTAL_BIND" => @address,
             "EXPERIMENTAL_UPSTREAM" => upstream, "EXPERIMENTAL_EVENTS" => @events_path }
    ).start
  end

  it "calls grpc in the master before each fork and serves with new native servers in children" do
    with_upstream do |upstream|
      start_cluster(upstream).wait_until(workers: 1)
      client = Helloworld::Greeter::Stub.new(@address, :this_channel_is_insecure)
      reply = client.say_hello(Helloworld::HelloRequest.new(name: "child"), deadline: Time.now + 5)
      expect(reply.message).to eq("#{@cluster.workers.first[:pid]}:child")

      @cluster.signal("TTIN").wait_until(workers: 2)
      events = File.readlines(@events_path).map { |line| JSON.parse(line, symbolize_names: true) }
      expect(events.map { |event| event[:pid] }).to eq([@cluster.pid, @cluster.pid])
      expect(events.map { |event| event[:message] }).to eq(%w[upstream:master:0 upstream:master:1])
      expect(@cluster.workers.map { |worker| worker[:port] }.uniq).to eq([@address.split(":").last.to_i])
      @cluster.stop
      expect(@cluster.wait).to be_success
    end
  end

  it "fails startup with an actionable message when the pre-require flag is absent" do
    with_upstream do |upstream|
      start_cluster(upstream, flag: "0")
      expect(@cluster.wait(timeout: 5).exitstatus).to eq(1)
      expect(@cluster.logs).to include("GRPC_ENABLE_FORK_SUPPORT=1 before requiring grpc")
      expect(@cluster.workers).to be_empty
    end
  end
end
