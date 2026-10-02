# frozen_string_literal: true

require "gritz/native"
require "google/protobuf/wrappers_pb"
require "json"

$LOAD_PATH.unshift(File.expand_path("../../../fixtures/hello", __dir__))
require "hello_services_pb"

module ClientChain
  ROLE = ENV.fetch("CLIENT_E2E_ROLE")

  def self.record(event, **fields)
    File.open(ENV.fetch("CLIENT_E2E_EVENTS"), "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts(JSON.generate(event:, role: ROLE, pid: Process.pid, **fields))
    end
  end

  module ChannelProbe
    def new(target, *arguments, **options, &)
      channel = super
      args = arguments.first
      ClientChain.record("channel", target:, channel_id: channel.object_id,
                                    service_config: args.is_a?(Hash) ? args["grpc.service_config"] : nil)
      channel
    end
  end
  GRPC::Core::Channel.singleton_class.prepend(ChannelProbe)

  if ENV["CLIENT_E2E_TARGET"]
    Downstream = Gritz::Client.define(
      Helloworld::Greeter::Stub,
      target: ENV.fetch("CLIENT_E2E_TARGET"),
      deadline: Float(ENV.fetch("CLIENT_E2E_DEADLINE")), safety_margin: 0.03,
      service_config: { loadBalancingConfig: [{ pick_first: {} }] }
    )
    record("defined", target: ENV.fetch("CLIENT_E2E_TARGET"))
  end

  class Controller < Gritz::Controller
    bind Helloworld::Greeter::Service

    def say_hello
      hop = { role: ROLE, pid: Process.pid, deadline: context.deadline.to_f, received_at: Time.now.to_f,
              request_id: context.request_id, traceparent: context.metadata["traceparent"],
              authorization: context.metadata["authorization"] }
      ClientChain.record("request", **hop.except(:pid))
      mode = request.message.name
      if ROLE == "c"
        if mode.start_with?("error:")
          fail!(:not_found, "downstream confidential message", metadata: { "downstream-marker" => "origin-c" },
                                                               details: [Google::Protobuf::StringValue.new(value: "origin-c detail")])
        end
        return Helloworld::HelloReply.new(message: JSON.generate(hops: [hop]))
      end

      result = JSON.parse(Downstream.say_hello(request.message).message)
      result.fetch("hops").unshift(hop)
      Helloworld::HelloReply.new(message: JSON.generate(result))
    rescue Gritz::Errors::NotFound => e
      raise unless ROLE == "b" && mode == "error:handled"

      handled = { class: e.class.name, code: e.grpc_code, remote: e.remote?, message: e.message,
                  details: e.details.map(&:value), marker: e.metadata["downstream-marker"] }
      Helloworld::HelloReply.new(message: JSON.generate(hops: [hop], handled:))
    end
  end
end
