# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe Gritz::Transport::Native::Client do
  before do
    Gritz::ChannelRegistry.reset!
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
  end
  after do
    @connections&.each { |connection| connection.channel.close }
    Gritz::ChannelRegistry.reset!
    Gritz::Client.middleware = @previous_middleware
    Gritz::ForkGuard.deactivate
  end

  def controller
    Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      def say_hello = Helloworld::HelloReply.new(message: request.message.name)
      def record_names = Helloworld::HelloReply.new(count: request.each_message.count)

      def list_greetings
        3.times { |index| stream.write(Helloworld::HelloReply.new(message: "#{request.message.name}:#{index}")) }
      end

      def chat
        request.each_message { |message| stream.write(Helloworld::HelloReply.new(message: message.name.upcase)) }
      end
    end
  end

  def message(name) = Helloworld::HelloRequest.new(name:)

  def track_connections
    @connections = []
    allow(described_class).to receive(:connect).and_wrap_original do |original, **options|
      original.call(**options).tap { |connection| @connections << connection }
    end
  end

  it "uses one shared channel for all four RPC forms and separate client definitions" do
    track_connections
    Gritz::Testing::Server.start(controllers: [controller]) do |server|
      client = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, deadline: 2)
      second = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, deadline: 2)
      expect(client.say_hello(message("one")).message).to eq("one")
      expect(second.record_names([message("a"), message("b")]).count).to eq(2)
      expect(client.list_greetings(message("x")).map(&:message)).to eq(%w[x:0 x:1 x:2])
      expect(second.chat([message("a"), message("b")]).map(&:message)).to eq(%w[A B])
      replies = []
      client.list_greetings(message("block")) { |reply| replies << reply.message }
      expect(replies).to eq(%w[block:0 block:1 block:2])
      expect(@connections.size).to eq(1)
    end
  end

  it "resolves lazy credentials once per connection and never while defining a master constant" do
    track_connections
    resolved = 0
    credentials = lambda {
      resolved += 1
      :this_channel_is_insecure
    }
    Gritz::Testing::Server.start(controllers: [controller]) do |server|
      Gritz::ForkGuard.activate
      client = Gritz::Client.define(Helloworld::Greeter::Stub, target: server.address, credentials:, deadline: 2)
      expect(resolved).to eq(0)
      expect { client.say_hello(message("blocked")) }.to raise_error(Gritz::ForkGuard::Violation)
      expect(resolved).to eq(0)
      Gritz::ForkGuard.deactivate
      2.times { expect(client.say_hello(message("allowed")).message).to eq("allowed") }
      expect(resolved).to eq(1)
      expect(@connections.size).to eq(1)
    end
  end

  it "preserves channel args and creates official call-credential stubs with a secure shared channel" do
    credentials = GRPC::Core::CallCredentials.new(->(_context) { { "authorization" => "token" } })
    args = { GRPC::Core::Channel::SSL_TARGET => "server.test", "grpc.primary_user_agent" => "custom" }.freeze
    connection = described_class.connect(target: "localhost:1", credentials:, args:)
    @connections = [connection]
    expect(connection.credentials).to equal(credentials)
    expect(connection.args).to equal(args)
    expect(args["grpc.primary_user_agent"]).to eq("custom")
    expect(GRPC::ClientStub).to receive(:setup_channel).with(connection.channel, "localhost:1", an_instance_of(GRPC::Core::ChannelCredentials), args)
                                                       .and_call_original
    Helloworld::Greeter::Stub.new(connection.target, connection.credentials,
                                  channel_override: connection.channel, channel_args: connection.args.dup)
  end

  it "rejects expired and unsupported Operation calls before creating native objects" do
    expect(described_class).not_to receive(:connect)
    client = Gritz::Client.define(Helloworld::Greeter::Stub, target: "localhost:1")
    expect { client.say_hello(message("x"), deadline: Time.now - 1) }.to raise_error(Gritz::Errors::DeadlineExceeded)
    expect { client.say_hello(message("x"), return_op: true) }.to raise_error(ArgumentError, /return_op/)
  end
end
