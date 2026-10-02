# frozen_string_literal: true

require "spec_helper"
require "google/rpc/error_details_pb"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Native client stream lifecycle" do
  before do
    Gritz::ChannelRegistry.reset!
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
    @connections = []
    allow(Gritz::Transport::Native::Client).to receive(:connect).and_wrap_original do |original, **options|
      original.call(**options).tap { |connection| @connections << connection }
    end
  end
  after do
    @connections.each { |connection| connection.channel.close }
    Gritz::ChannelRegistry.reset!
    Gritz::Client.middleware = @previous_middleware
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return if yield
      raise "client cancellation did not reach the server" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.005
    end
  end

  it "stops a running server stream promptly when a lazy consumer breaks" do
    completed = Queue.new
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      define_method(:list_greetings) do
        loop do
          context.check_cancelled!
          stream.write(Helloworld::HelloReply.new(message: "reply"))
          sleep 0.005
        end
      ensure
        completed << true
      end
    end
    Gritz::Testing::Server.start(controllers: [controller]) do |server|
      client = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, deadline: 5)
      replies = 0
      client.list_greetings(Helloworld::HelloRequest.new).each do |_reply|
        replies += 1
        break if replies == 1
      end
      wait_until { !completed.empty? }
      expect(replies).to eq(1)
      expect(server.transport.stats[:inflight]).to eq(0)
    end
  end

  it "restores the captured parent on the native bidi producer thread and cancels after a consumer error" do
    completed = Queue.new
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      define_method(:chat) do
        request.each_message do |message|
          stream.write(Helloworld::HelloReply.new(message: message.name))
        end
      ensure
        completed << true
      end
    end
    parent = Struct.new(:deadline, :metadata, :request_id, :trace_context, :logger) do
      def cancelled? = false
    end.new(Time.now + 5, {}, "parent", nil, Logger.new(File::NULL))
    produced_contexts = Queue.new
    input = Enumerator.new do |output|
      2.times do
        produced_contexts << Gritz::Context.current
        output << Helloworld::HelloRequest.new(name: "request")
      end
    end
    Gritz::Testing::Server.start(controllers: [controller]) do |server|
      client = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, deadline: 5)
      stream = Gritz::Context.with(parent) { client.chat(input) }
      expect { stream.each { |reply| raise "consumer failed" if reply.message == "request" } }.to raise_error(RuntimeError, "consumer failed")
      wait_until { !completed.empty? }
      expect(produced_contexts.size).to eq(2)
      expect(2.times.map { produced_contexts.pop }).to eq([parent, parent])
      expect(Gritz::Context.current).to be_nil
    end
  end

  it "decodes rich errors delivered after partial server-stream output" do
    detail = Google::Rpc::ResourceInfo.new(resource_type: "user", resource_name: "users/404")
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      define_method(:list_greetings) do
        stream.write(Helloworld::HelloReply.new(message: "first"))
        fail!(:not_found, "missing", details: [detail])
      end
    end
    Gritz::Testing::Server.start(controllers: [controller]) do |server|
      client = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, deadline: 2)
      replies = []
      expect { client.list_greetings(Helloworld::HelloRequest.new).each { |reply| replies << reply.message } }
        .to raise_error(Gritz::Errors::NotFound) { |error| expect(error.details).to eq([detail]) }
      expect(replies).to eq(["first"])
    end
  end
end
