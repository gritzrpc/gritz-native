# frozen_string_literal: true

require "spec_helper"
require "grpc/health/v1/health_services_pb"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Native health watch lifecycle" do
  let(:logger) { Logger.new(File::NULL) }
  let(:config) do
    Gritz::Configuration.new.tap do |settings|
      settings.bind = "127.0.0.1:0"
      settings.threads = 1
      settings.controllers = [Class.new(Gritz::Controller) do
        bind Helloworld::Greeter::Service
        def say_hello = Helloworld::HelloReply.new(message: "ok")
      end]
    end
  end

  def with_adapter
    router = Gritz::Router.new(controllers: config.controllers)
    dispatcher = Gritz::Dispatcher.new(router:, logger:)
    adapter = Gritz::Transport::Native.new(config: config.validate!, dispatcher:, logger:)
    port = adapter.bind
    adapter.start
    yield adapter, "127.0.0.1:#{port}"
  ensure
    adapter&.stop(deadline: Time.now + 0.5)
  end

  def wait_for_pool(stub)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return stub.check(Grpc::Health::V1::HealthCheckRequest.new, deadline: Time.now + 0.2)
    rescue GRPC::ResourceExhausted
      raise "health watch retained the only pool thread" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  it "preserves a handler's non-OK status and metadata before releasing its native close observer" do
    health = Gritz::Transport::Native::Health.new(["helloworld.Greeter"])
    health.define_singleton_method(:watch) do |_request, _call|
      raise GRPC::PermissionDenied.new("watch denied", { "error-tag" => "health-auth" })
    end
    allow(Gritz::Transport::Native::Health).to receive(:new).and_return(health)
    with_adapter do |_adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      expect { stub.watch(Grpc::Health::V1::HealthCheckRequest.new, deadline: Time.now + 1).to_a }
        .to raise_error(GRPC::PermissionDenied, /watch denied/) { |error| expect(error.metadata).to include("error-tag" => "health-auth") }
      expect(wait_for_pool(stub).status).to eq(:SERVING)
    end
  end

  it "maps unexpected handler failures before closing the call and keeps the pool usable" do
    health = Gritz::Transport::Native::Health.new(["helloworld.Greeter"])
    health.define_singleton_method(:watch) { |_request, _call| raise "watch failed" }
    allow(Gritz::Transport::Native::Health).to receive(:new).and_return(health)
    with_adapter do |_adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      expect { stub.watch(Grpc::Health::V1::HealthCheckRequest.new, deadline: Time.now + 1).to_a }
        .to raise_error(GRPC::Unknown, /Health handler failed/) { |error| expect(error.details).not_to include("watch failed") }
      expect(wait_for_pool(stub).status).to eq(:SERVING)
    end
  end

  it "releases expired watches repeatedly without retaining observers or pool slots" do
    with_adapter do |_adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      baseline = Thread.list
      5.times do
        replies = stub.watch(Grpc::Health::V1::HealthCheckRequest.new, deadline: Time.now + 0.05)
        expect(replies.next.status).to eq(:SERVING)
        expect { replies.next }.to raise_error(GRPC::DeadlineExceeded)
        expect(wait_for_pool(stub).status).to eq(:SERVING)
        expect(Thread.list - baseline).to be_empty
      end
    end
  end

  it "counts occupied health pool threads separately from application requests" do
    with_adapter do |adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      operation = stub.watch(Grpc::Health::V1::HealthCheckRequest.new, deadline: Time.now + 3, return_op: true)
      replies = operation.execute
      expect(replies.next.status).to eq(:SERVING)
      expect(adapter.stats).to include(busy: 1, inflight: 0, requests_total: 0, capacity: 1)

      operation.cancel
      expect { replies.next }.to raise_error(GRPC::Cancelled)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until adapter.stats[:busy].zero?
        raise "cancelled health watch kept the pool busy" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      expect(adapter.stats).to include(busy: 0, inflight: 0, requests_total: 0)
      expect(wait_for_pool(stub).status).to eq(:SERVING)
    ensure
      operation&.cancel
    end
  end
end
