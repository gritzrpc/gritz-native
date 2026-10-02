# frozen_string_literal: true

require "spec_helper"
require "google/rpc/error_details_pb"

RSpec.describe Gritz::Transport::Native::ClientInvocation do
  let(:operation_class) do
    Class.new do
      attr_reader :cancel_count

      def initialize(&execute)
        @execute = execute
        @cancel_count = 0
      end

      def execute = @execute.call
      def cancel = @cancel_count += 1
      def cancelled? = false
    end
  end
  let(:stub_class) do
    operation = operation_class
    Class.new do
      attr_accessor :error, :outputs, :before_create
      attr_reader :calls, :operation

      def initialize
        @calls = []
        @outputs = %w[first second]
      end
      %i[request_response client_streamer server_streamer bidi_streamer].each do |name|
        define_method(name) do |method, request, _marshal, _unmarshal, **options, &block|
          before_create&.call(options)
          @calls << [name, method, request, options]
          @operation = operation.new do
            if %i[client_streamer bidi_streamer].include?(name)
              @calls.last[2] = request.to_a
            end
            if %i[server_streamer bidi_streamer].include?(name)
              outputs.each(&block)
              raise error if error

              nil
            else
              raise error if error

              "reply"
            end
          end
        end
      end
    end
  end
  let(:stub) { stub_class.new.extend(described_class) }

  before do
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
    @invocation = Gritz::Client::Invocation.new
    stub.instance_variable_set(:@gritz_around, @invocation.method(:call))
  end
  after { Gritz::Client.middleware = @previous_middleware }

  def call(method = :request_response, request: "request", &block)
    stub.public_send(method, "/test.Service/Call", request, ->(message) { message }, ->(message) { message }, **@invocation.options, &block)
  end

  it "executes the public native Operation for all four forms without buffering the output" do
    expect(call).to eq("reply")
    expect(stub.operation.cancel_count).to eq(0)
    expect(call(:client_streamer, request: %w[a b])).to eq("reply")
    expect(stub.calls.last[2]).to eq(%w[a b])
    stream = call(:server_streamer)
    expect(stub.calls.size).to eq(2)
    expect(stream.to_a).to eq(%w[first second])
    expect(call(:bidi_streamer, request: ["a"]).to_a).to eq(%w[first second])
    expect(stub.calls.last[2]).to eq(["a"])
    expect(stub.calls.map { |row| row.last[:return_op] }).to eq([true] * 4)
    expect(stub.operation.cancel_count).to eq(0)
  end

  it "injects metadata before native call allocation and keeps streaming middleware open through status" do
    events = []
    middleware = Class.new do
      define_method(:initialize) { |app| @app = app }
      define_method(:call) do |context|
        events << :start
        context.metadata["traceparent"] = "child-span"
        @app.call(context)
      ensure
        events << :finish
      end
    end
    Gritz::Client.middleware.use(middleware)
    @invocation = Gritz::Client::Invocation.new
    stub.instance_variable_set(:@gritz_around, @invocation.method(:call))
    stub.before_create = ->(options) { expect(options[:metadata]["traceparent"]).to eq("child-span") }
    stream = call(:server_streamer)
    expect(events).to eq([])
    stream.each { |_reply| events << :reply }
    expect(events).to eq(%i[start reply reply finish])
  end

  it "cancels an operation when lazy stream consumption breaks early" do
    call(:server_streamer).each { |reply| break if reply == "first" }
    expect(stub.operation.cancel_count).to eq(1)
  end

  it "reports client cancellation to middleware even when native status has already been closed" do
    contexts = []
    observer = Class.new do
      define_method(:initialize) { |app| @app = app }
      define_method(:call) do |context|
        contexts << context
        @app.call(context)
      end
    end
    Gritz::Client.middleware.use(observer)
    @invocation = Gritz::Client::Invocation.new
    stub.instance_variable_set(:@gritz_around, @invocation.method(:call))
    call(:server_streamer).each { |reply| break if reply == "first" }
    expect(contexts.first.cancelled?).to be true
    expect(stub.operation.cancelled?).to be false
  end

  it "cancels an operation when a block consumer raises and preserves the consumer exception" do
    expect { call(:bidi_streamer, request: []) { raise "consumer failed" } }.to raise_error(RuntimeError, "consumer failed")
    expect(stub.operation.cancel_count).to eq(1)
  end

  it "maps a non-OK trailer received after streamed responses to its canonical remote error" do
    stub.error = GRPC::Unavailable.new("late private failure", { "retry" => "yes" }, "secret core diagnostic")
    replies = []
    expect { call(:server_streamer).each { |reply| replies << reply } }.to raise_error(Gritz::Errors::Unavailable) do |error|
      expect(error.remote?).to be true
      expect(error.message).to eq("late private failure")
      expect(error.metadata).to eq("retry" => "yes")
    end
    expect(replies).to eq(%w[first second])
  end

  it "decodes registered rich details and preserves unknown or malformed Any messages" do
    detail = Google::Rpc::ResourceInfo.new(resource_type: "user", resource_name: "users/404")
    packed = Google::Protobuf::Any.new.tap { |any| any.pack(detail) }
    unknown = Google::Protobuf::Any.new(type_url: "type.example.test/private.Unregistered", value: "opaque")
    malformed = Google::Protobuf::Any.new(type_url: packed.type_url, value: "\xff".b)
    status = Google::Rpc::Status.new(code: 5, message: "rich message", details: [packed, unknown, malformed])
    stub.error = GRPC::NotFound.new("wire message", { "grpc-status-details-bin" => Google::Rpc::Status.encode(status) })
    expect { call }.to raise_error(Gritz::Errors::NotFound) do |error|
      expect(error.message).to eq("wire message")
      expect(error.details[0]).to eq(detail)
      expect(error.details[1]).to eq(unknown)
      expect(error.details[2]).to eq(malformed)
      expect(error.remote?).to be true
    end
  end

  it "uses the wire status when a rich status disagrees or its trailer cannot be decoded" do
    mismatch = Google::Rpc::Status.new(code: 7, details: [Google::Protobuf::Any.new])
    invalid_values = [Google::Rpc::Status.encode(mismatch), "\xff".b, %w[one two], Object.new]
    invalid_values.each do |trailer|
      stub.error = GRPC::NotFound.new("missing", { "grpc-status-details-bin" => trailer })
      expect { call }.to raise_error(Gritz::Errors::NotFound) do |error|
        expect(error.details).to eq([])
        expect(error.remote?).to be true
      end
    end
  end

  it "maps an unrecognized wire status to UNKNOWN while keeping its safe remote boundary" do
    stub.error = GRPC::BadStatus.new(99, "unrecognized", {})
    expect { call }.to raise_error(Gritz::Errors::Unknown) do |error|
      expect(error.remote?).to be true
      expect(error.message).to eq("unrecognized")
    end
  end
end
