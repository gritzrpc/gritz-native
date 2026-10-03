# frozen_string_literal: true

require "spec_helper"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe Gritz::Transport::Native::Cancellation do
  def observed_call(closed:, received:, fail_status: false)
    Class.new do
      define_method(:run_batch) do |operations|
        if operations.key?(GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER)
          received << true
          raise GRPC::Core::CallError, "close already observed" if received.size > 1

          closed.pop
        elsif fail_status && operations.key?(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER)
          raise GRPC::Core::CallError, "client closed before status"
        end
      end
      define_method(:cancel) { closed << true }
      def close; end
    end.new.extend(described_class::CoreCall)
  end

  it "starts only one close observer when application threads query concurrently" do
    closed = Queue.new
    received = Queue.new
    raw = observed_call(closed:, received:)
    creating = Queue.new
    continue_creation = Queue.new
    querying = Queue.new
    allow(Thread).to receive(:new).and_wrap_original do |original, *arguments, &block|
      observer = original.call(*arguments, &block)
      creating << true
      raise "observer creation barrier timed out" unless continue_creation.pop(timeout: 1)

      observer
    end
    first = Thread.start { raw.gritz_cancelled? }
    expect(creating.pop(timeout: 1)).to be true
    second = Thread.start do
      querying << true
      raw.gritz_cancelled?
    end
    expect(querying.pop(timeout: 1)).to be true
    expect(creating.pop(timeout: 0.05)).to be_nil
    2.times { continue_creation << true }
    expect(first.join(1)).not_to be_nil
    expect(second.join(1)).not_to be_nil
    expect(received.size).to eq(1)
    expect(raw.gritz_cancelled?).to be false
  ensure
    2.times { continue_creation&.push(true) }
    first&.join(1)
    second&.join(1)
    raw&.finish_gritz_call
  end

  it "waits for observer creation before sending the ordinary status batch" do
    closed = Queue.new
    received = Queue.new
    raw = observed_call(closed:, received:)
    creating = Queue.new
    continue_creation = Queue.new
    sent = Queue.new
    allow(Thread).to receive(:new).and_wrap_original do |original, *arguments, &block|
      observer = original.call(*arguments, &block)
      creating << true
      raise "observer creation barrier timed out" unless continue_creation.pop(timeout: 1)

      observer
    end
    query = Thread.start { raw.gritz_cancelled? }
    expect(creating.pop(timeout: 1)).to be true
    sender = Thread.start do
      raw.run_batch(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER => Struct::Status.new(0, "OK", {}),
                    GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER => nil)
      sent << true
    rescue GRPC::Core::CallError => e
      sent << e
    end
    expect(sent.pop(timeout: 0.05)).to be_nil
    continue_creation << true
    expect(query.join(1)).not_to be_nil
    expect(sender.join(1)).not_to be_nil
    expect(sent.pop(timeout: 1)).to be true
    closed << true
    raw.finish_gritz_call
    expect(raw.gritz_cancelled?).to be false
  ensure
    continue_creation&.push(true)
    query&.join(1)
    sender&.join(1)
    raw&.finish_gritz_call
  end

  it "waits for observer creation before releasing native call resources" do
    closed = Queue.new
    received = Queue.new
    raw = observed_call(closed:, received:)
    creating = Queue.new
    continue_creation = Queue.new
    finished = Queue.new
    allow(Thread).to receive(:new).and_wrap_original do |original, *arguments, &block|
      observer = original.call(*arguments, &block)
      creating << true
      raise "observer creation barrier timed out" unless continue_creation.pop(timeout: 1)

      observer
    end
    query = Thread.start { raw.gritz_cancelled? }
    expect(creating.pop(timeout: 1)).to be true
    closer = Thread.start do
      raw.finish_gritz_call
      finished << true
    end
    expect(finished.pop(timeout: 0.05)).to be_nil
    continue_creation << true
    expect(query.join(1)).not_to be_nil
    expect(closer.join(1)).not_to be_nil
    expect(finished.pop(timeout: 1)).to be true
    expect(raw.gritz_cancelled?).to be true
  ensure
    continue_creation&.push(true)
    query&.join(1)
    closer&.join(1)
    raw&.finish_gritz_call
  end

  it "keeps cancellation latched when a failed status precedes the close observer's return" do
    closed = Queue.new
    received = Queue.new
    raw = observed_call(closed:, received:, fail_status: true)
    expect(raw.gritz_cancelled?).to be false
    expect(received.pop(timeout: 1)).to be true
    expect do
      raw.run_batch(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER => Struct::Status.new(0, "OK", {}))
    end.to raise_error(GRPC::Core::CallError)
    closed << true
    raw.finish_gritz_call
    expect(raw.gritz_cancelled?).to be true
  ensure
    raw&.finish_gritz_call
  end

  it "preserves failed-status cancellation when first queried after handler completion" do
    closed = Queue.new
    received = Queue.new
    raw = observed_call(closed:, received:, fail_status: true)
    expect do
      raw.run_batch(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER => Struct::Status.new(0, "OK", {}))
    end.to raise_error(GRPC::Core::CallError)
    expect(raw.gritz_cancelled?).to be true
    raw.finish_gritz_call
    expect(raw.gritz_cancelled?).to be true
  ensure
    raw&.finish_gritz_call
  end

  it "releases observer threads and the serving slot across repeated real client cancellations" do
    entered = Queue.new
    release = Queue.new
    controller = Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      define_method(:say_hello) do
        context.cancelled?
        entered << context
        return Helloworld::HelloReply.new(message: "available") unless request.message.name == "cancel"

        context.check_cancelled! until release.pop(timeout: 0.005)
        Helloworld::HelloReply.new
      end
    end
    config = Gritz::Configuration.new
    config.bind = "127.0.0.1:0"
    config.threads = 1
    config.shutdown_timeout = 0.1
    observers = []
    Gritz::Testing::Server.start(config, controllers: [controller]) do |server|
      client = Helloworld::Greeter::Stub.new(server.address, :this_channel_is_insecure)
      10.times do
        operation = client.say_hello(Helloworld::HelloRequest.new(name: "cancel"), return_op: true, deadline: Time.now + 3)
        caller = Thread.new do
          operation.execute
        rescue GRPC::BadStatus => e
          e
        end
        context = entered.pop(timeout: 1)
        expect(context).not_to be_nil
        raw = context.call.instance_variable_get(:@view).instance_variable_get(:@wrapped).instance_variable_get(:@call)
        observers << raw.instance_variable_get(:@gritz_close_observer)
        operation.cancel
        expect(caller.join(1)).not_to be_nil
        expect(caller.value).to be_a(GRPC::Cancelled)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        until server.transport.stats[:busy].zero?
          raise "cancelled request retained the serving slot" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.005
        end
        expect(context.cancelled?).to be true
      ensure
        operation&.cancel
        caller&.join(1)
      end
      expect(observers).to all(be_a(Thread))
      expect(observers.none?(&:alive?)).to be true
      expect(client.say_hello(Helloworld::HelloRequest.new, deadline: Time.now + 1).message).to eq("available")
      expect(entered.pop(timeout: 1).cancelled?).to be false
    end
  ensure
    release&.push(true)
  end
end
