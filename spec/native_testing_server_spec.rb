# frozen_string_literal: true

require "spec_helper"
require "gritz/native"
require "logger"
require "socket"

$LOAD_PATH.unshift File.expand_path("fixtures/hello", __dir__)
require "hello_services_pb"

RSpec.describe Gritz::Testing::Server do
  let(:logger) { Logger.new(File::NULL) }
  let(:controller) do
    Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      def say_hello = Helloworld::HelloReply.new(message: "started")
    end
  end
  let(:config) do
    Gritz::Configuration.new.tap do |settings|
      settings.bind = "127.0.0.1:0"
      settings.controllers = [controller]
    end
  end

  it "rejects unsupported runtime features before binding a native server" do
    { transport: :async, listener_strategy: :port_per_worker }.each do |setting, value|
      config.public_send("#{setting}=", value)
      helper = nil
      expect { helper = described_class.start(config, logger:) }.to raise_error(Gritz::ConfigurationError)
    ensure
      helper&.stop
      config.public_send("#{setting}=", Gritz::Configuration::DEFAULTS.fetch(setting).dup)
    end
  end

  it "preloads before building routes and runs worker hooks exactly once" do
    events = []
    preloaded_controller = Class.new(controller) do
      def say_hello = Helloworld::HelloReply.new(message: "preloaded")
    end
    config.add_preloader do
      events << :preload
      config.controllers = [preloaded_controller]
    end
    config.add_hook(:on_worker_boot) { |index| events << [:boot, index] }
    config.add_hook(:on_worker_shutdown) { |index| events << [:shutdown, index] }
    described_class.start(config, logger:) do |helper|
      stub = Helloworld::Greeter::Stub.new(helper.address, :this_channel_is_insecure)
      expect(stub.say_hello(Helloworld::HelloRequest.new).message).to eq "preloaded"
      expect(events).to eq [:preload, [:boot, 0]]
      expect { helper.start }.to raise_error(ArgumentError, /already started/)
      helper.stop
      helper.stop
    end
    expect(events).to eq [:preload, [:boot, 0], [:shutdown, 0]]
  end

  it "runs the shutdown hook once when the test block raises" do
    events = []
    config.add_hook(:on_worker_shutdown) { |index| events << index }
    helper = nil
    expect do
      described_class.start(config, logger:) do |server|
        helper = server
        raise "test failed"
      end
    end.to raise_error("test failed")
    helper.stop
    expect(events).to eq [0]
    expect(helper.transport.running?).to be false
  end

  it "runs shutdown cleanup when a boot hook fails" do
    events = []
    config.add_hook(:on_worker_boot) do
      events << :boot
      raise "boot failed"
    end
    config.add_hook(:on_worker_shutdown) { events << :shutdown }
    helper = described_class.new(config, logger:)
    expect { helper.start }.to raise_error("boot failed")
    helper.stop
    expect(events).to eq %i[boot shutdown]
  ensure
    helper&.stop
  end

  it "does not begin the worker lifecycle when preload fails" do
    events = []
    config.add_preloader do
      events << :preload
      raise "preload failed"
    end
    config.add_hook(:on_worker_boot) { events << :boot }
    config.add_hook(:on_worker_shutdown) { events << :shutdown }
    helper = described_class.new(config, logger:)
    expect { helper.start }.to raise_error("preload failed")
    expect { helper.start }.to raise_error(ArgumentError, /already started/)
    helper.stop
    expect(events).to eq [:preload]
    expect(helper.transport).to be_nil
  end

  it "releases the bound native listener when transport startup fails" do
    events = []
    config.add_hook(:on_worker_shutdown) { events << :shutdown }
    allow(Gritz::Transport::Native).to receive(:new).and_wrap_original do |constructor, **arguments|
      constructor.call(**arguments).tap do |adapter|
        allow(adapter).to receive(:start).and_raise("native startup failed")
      end
    end
    helper = described_class.new(config, logger:)
    expect { helper.start }.to raise_error("native startup failed")
    listener = TCPServer.new("127.0.0.1", helper.port)
    expect(listener.addr[1]).to eq helper.port
    helper.stop
    expect(events).to eq [:shutdown]
  ensure
    listener&.close
    helper&.stop
  end
end
