# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Native shutdown acceptance" do
  it "keeps accepting calls until C-core begins its shutdown instead of waiting on the running-state mutex" do
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      def say_hello = Helloworld::HelloReply.new(message: request.message.name)
    end
    config = Gritz::Configuration.new
    config.bind = "127.0.0.1:0"
    config.controllers = [controller]
    logger = Logger.new(File::NULL)
    dispatcher = Gritz::Dispatcher.new(router: Gritz::Router.new(controllers: [controller]), middleware: config.middleware, logger:)
    adapter = Gritz::Transport::Native.new(config:, dispatcher:, logger:)
    port = adapter.bind
    core = adapter.instance_variable_get(:@server).instance_variable_get(:@server)
    accepting = Queue.new
    allow(core).to receive(:request_call).and_wrap_original do |original|
      accepting << true
      original.call
    end
    adapter.start
    expect(accepting.pop(timeout: 2)).to be true
    stopping = Queue.new
    release = Queue.new
    # Hold the shutdown entry so the Ruby mutex-created acceptance gap is reproducible.
    allow(core).to receive(:shutdown_and_notify).and_wrap_original do |original, deadline|
      stopping << true
      raise "shutdown barrier timed out" unless release.pop(timeout: 2)

      original.call(deadline)
    end
    stopper = Thread.new { adapter.stop(deadline: Time.now + 3) }
    expect(stopping.pop(timeout: 2)).to be true
    client = Helloworld::Greeter::Stub.new("127.0.0.1:#{port}", :this_channel_is_insecure)
    %w[first second].each do |name|
      expect(client.say_hello(Helloworld::HelloRequest.new(name: name), deadline: Time.now + 0.5).message).to eq name
    end
  ensure
    release&.push(true)
    begin
      raise "native shutdown did not finish" if stopper && !stopper.join(4)

      stopper&.value
    ensure
      adapter&.kill
    end
  end
end
