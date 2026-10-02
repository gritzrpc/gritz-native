# frozen_string_literal: true

require "spec_helper"
require "gritz/native"
require "grpc"
require "google/rpc/status_pb"
require "google/rpc/error_details_pb"
require "logger"
require "stringio"
require "socket"

$LOAD_PATH.unshift File.expand_path("fixtures/hello", __dir__)
require "hello_services_pb"

RSpec.describe "gRPC transport" do
  let(:logger) { Logger.new(StringIO.new) }

  def controller(&block)
    Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      def say_hello = Helloworld::HelloReply.new(message: "Hello, #{request.message.name}")
      def record_names = Helloworld::HelloReply.new(count: request.each_message.count)

      def list_greetings
        3.times { |index| stream.write(Helloworld::HelloReply.new(message: "#{request.message.name}:#{index}")) }
      end

      def chat
        request.each_message { |message| stream.write(Helloworld::HelloReply.new(message: message.name.upcase)) }
      end
      class_eval(&block) if block
    end
  end

  def with_server(klass = controller, config: nil, **options)
    Gritz::Testing::Server.start(config, controllers: [klass], logger:, **options) do |server|
      stub = Helloworld::Greeter::Stub.new(server.address, :this_channel_is_insecure)
      yield stub, server
    end
  end

  def message(name) = Helloworld::HelloRequest.new(name:)

  it "serves all four RPC forms over a real socket" do
    with_server do |stub, server|
      expect(server.port).to be > 0
      expect(stub.say_hello(message("Ruby")).message).to eq "Hello, Ruby"
      expect(stub.record_names([message("a"), message("b")]).count).to eq 2
      expect(stub.list_greetings(message("x")).map(&:message)).to eq %w[x:0 x:1 x:2]
      expect(stub.chat([message("a"), message("b")]).map(&:message)).to eq %w[A B]
      expect(server.transport.stats).to include(inflight: 0, capacity: 16, requests_total: 4)
    end
  end

  it "sends server responses before the action finishes and wraps the entire stream in middleware" do
    release = Queue.new
    events = Queue.new
    klass = controller do
      define_method(:list_greetings) do
        stream.write(Helloworld::HelloReply.new(message: "first"))
        release.pop
        events << :action_finished
        stream.write(Helloworld::HelloReply.new(message: "second"))
      end
    end
    around = Class.new do
      define_method(:initialize) { |app| @app = app }
      define_method(:call) do |context|
        events << :before
        @app.call(context)
      ensure
        events << :after
      end
    end
    stack = Gritz::Middleware::Stack.default
    stack.use(around)
    with_server(klass, middleware: stack) do |stub, _server|
      replies = stub.list_greetings(message("x"), deadline: Time.now + 5)
      expect(replies.next.message).to eq "first"
      expect(events.pop(timeout: 2)).to eq :before
      expect(events.empty?).to be true
      release << true
      expect(replies.next.message).to eq "second"
      expect { replies.next }.to raise_error(StopIteration)
      expect([events.pop(timeout: 2), events.pop(timeout: 2)]).to eq %i[action_finished after]
    ensure
      release << true
    end
  end

  it "answers bidi messages while the input stream remains open" do
    input = Queue.new
    requests = Enumerator.new do |yielder|
      yielder << message("first")
      input.pop
      yielder << message("second")
    end
    with_server do |stub, _server|
      replies = stub.chat(requests, deadline: Time.now + 5)
      expect(replies.next.message).to eq "FIRST"
      input << true
      expect(replies.next.message).to eq "SECOND"
      expect { replies.next }.to raise_error(StopIteration)
    ensure
      input << true
    end
  end

  it "passes initial metadata, writable trailers, deadline and peer to controllers" do
    observations = Queue.new
    klass = controller do
      define_method(:say_hello) do
        observations << [context.metadata, context.deadline, context.peer, context.peer_identity]
        context.call.send_initial_metadata("answer" => "initial")
        context.call.trailing_metadata["answer"] = "trailing"
        Helloworld::HelloReply.new(message: context.request_id)
      end
    end
    with_server(klass) do |stub, _server|
      deadline = Time.now + 5
      operation = stub.say_hello(message("x"), metadata: { "x-request-id" => "req-1", "request" => "yes" }, deadline:, return_op: true)
      expect(operation.execute.message).to eq "req-1"
      expect(operation.metadata).to include("x-request-id" => "req-1", "answer" => "initial")
      expect(operation.trailing_metadata).to include("answer" => "trailing")
      metadata, actual_deadline, peer, identity = observations.pop(timeout: 2)
      expect(metadata).to include("request" => "yes")
      expect(actual_deadline).to be_within(0.1).of(deadline)
      expect(peer).to match(/ipv[46]:/)
      expect(identity).to be_nil
    end
  end

  it "encodes rich application errors as google.rpc.Status trailers" do
    klass = controller do
      def say_hello
        detail = Google::Rpc::ResourceInfo.new(resource_type: "name", resource_name: request.message.name)
        fail!(:not_found, "missing name", details: [detail], metadata: { "lookup" => "failed" })
      end
    end
    with_server(klass) do |stub, _server|
      expect { stub.say_hello(message("missing")) }.to raise_error(GRPC::NotFound) do |error|
        expect(error.details).to eq "missing name"
        expect(error.metadata).to include("lookup" => "failed")
        status = Google::Rpc::Status.decode(error.metadata.fetch("grpc-status-details-bin"))
        expect([status.code, status.message]).to eq [5, "missing name"]
        expect(status.details.first.unpack(Google::Rpc::ResourceInfo).resource_name).to eq "missing"
      end
    end
  end

  it "maps streaming errors after the first response" do
    klass = controller do
      def list_greetings
        stream.write(Helloworld::HelloReply.new(message: "first"))
        fail!(:permission_denied, "stop", metadata: { "reason" => "revoked" })
      end
    end
    with_server(klass) do |stub, _server|
      replies = stub.list_greetings(message("x"))
      expect(replies.next.message).to eq "first"
      expect { replies.next }.to raise_error(GRPC::PermissionDenied) do |error|
        expect(error.metadata).to include("reason" => "revoked")
      end
    end
  end

  it "hides failures when an application supplies invalid rich error details" do
    klass = controller do
      def say_hello = fail!(:not_found, "missing", details: ["database secret"])
    end
    with_server(klass) do |stub, _server|
      expect { stub.say_hello(message("x")) }.to raise_error(GRPC::Internal) do |error|
        expect(error.details).not_to include("database secret", "NoMethodError")
      end
    end
  end

  it "redacts invalid unary and streaming responses before native serialization" do
    klass = controller do
      def say_hello = "database secret"
      def list_greetings = stream.write("database secret")
    end
    with_server(klass) do |stub, _server|
      [-> { stub.say_hello(message("x")) }, -> { stub.list_greetings(message("x")).to_a }].each do |invoke|
        expect(&invoke).to raise_error(GRPC::Internal) do |error|
          expect(error.details).not_to include("database secret", "TypeError")
          expect(error.metadata).to have_key("error-id")
        end
      end
    end
  end

  it "honors client cancellation of an active unary call" do
    entered = Queue.new
    release = Queue.new
    klass = controller do
      define_method(:say_hello) do
        entered << true
        release.pop
        Helloworld::HelloReply.new(message: "done")
      end
    end
    with_server(klass) do |stub, _server|
      operation = stub.say_hello(message("x"), deadline: Time.now + 5, return_op: true)
      caller = Thread.new do
        operation.execute
      rescue GRPC::BadStatus => e
        e
      end
      expect(entered.pop(timeout: 2)).to be true
      operation.cancel
      expect(caller.join(2)).to equal(caller)
      expect(caller.value).to be_a(GRPC::Cancelled)
      release << true
    ensure
      release << true
      caller&.join(5)
    end
  end

  it "counts rejections when the thread pool is full" do
    entered = Queue.new
    release = Queue.new
    klass = controller do
      define_method(:say_hello) do
        entered << true
        release.pop
        Helloworld::HelloReply.new(message: "done")
      end
    end
    config = Gritz::Configuration.new
    config.bind = "127.0.0.1:0"
    config.threads = 1
    with_server(klass, config:) do |stub, server|
      caller = Thread.new { stub.say_hello(message("x"), deadline: Time.now + 5) }
      expect(entered.pop(timeout: 2)).to be true
      expect { stub.say_hello(message("x"), deadline: Time.now + 2) }.to raise_error(GRPC::ResourceExhausted)
      expect(server.transport.stats).to include(inflight: 1, busy: 1, capacity: 1, rejected_total: 1)
      release << true
      expect(caller.value.message).to eq "done"
    ensure
      release << true
      caller&.join(5)
    end
  end

  it "stops a blocked action by the supplied shutdown deadline" do
    entered = Queue.new
    klass = controller do
      define_method(:say_hello) do
        entered << true
        Queue.new.pop
      end
    end
    with_server(klass) do |stub, server|
      caller = Thread.new do
        stub.say_hello(message("x"), deadline: Time.now + 5)
      rescue GRPC::BadStatus => e
        e
      end
      expect(entered.pop(timeout: 2)).to be true
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.transport.stop(deadline: Time.now + 0.05)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(caller.join(2)).to equal(caller)
      expect(caller.value).to be_a(GRPC::BadStatus)
      expect(server.transport.running?).to be false
    end
  end

  it "releases a listener that was bound but never started" do
    config = Gritz::Configuration.new
    config.bind = "127.0.0.1:0"
    config.controllers = [controller]
    router = Gritz::Router.new(controllers: config.controllers)
    dispatcher = Gritz::Dispatcher.new(router:, logger:)
    adapter = Gritz::Transport::Native.new(config:, dispatcher:, logger:)
    port = adapter.bind
    adapter.stop(deadline: Time.now)
    listener = TCPServer.new("127.0.0.1", port)
    expect(listener.addr[1]).to eq port
  ensure
    listener&.close
    adapter&.kill
  end

  it "keeps the current server running when bind is accidentally called twice" do
    with_server do |stub, server|
      expect { server.transport.bind }.to raise_error(ArgumentError, /already bound/)
      expect(server.transport.running?).to be true
      expect(stub.say_hello(message("Ruby")).message).to eq "Hello, Ruby"
    end
  end

  it "returns UNIMPLEMENTED for actions absent from a bound service" do
    klass = Class.new(Gritz::Controller) { bind Helloworld::Greeter::Service }
    with_server(klass) do |stub, _server|
      expect { stub.say_hello(message("x")) }.to raise_error(GRPC::Unimplemented)
    end
  end

  it "preserves an in-flight response during graceful shutdown" do
    entered = Queue.new
    release = Queue.new
    klass = controller do
      define_method(:say_hello) do
        entered << true
        release.pop
        Helloworld::HelloReply.new(message: "completed")
      end
    end
    with_server(klass) do |stub, server|
      caller = Thread.new { stub.say_hello(message("x"), deadline: Time.now + 5) }
      expect(entered.pop(timeout: 2)).to be true
      stopper = Thread.new { server.transport.stop(deadline: Time.now + 3) }
      release << true
      expect(caller.value.message).to eq "completed"
      expect(stopper.join(4)).to equal(stopper)
      expect(server.transport.stats).to include(inflight: 0)
    ensure
      release << true
      caller&.join(5)
      stopper&.join(5)
    end
  end
end
