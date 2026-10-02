# frozen_string_literal: true

require_relative "client_invocation"

module Gritz
  module Transport
    class Native
      # Builds official gRPC connections only on the first process-local client call.
      # @api private
      class Client
        Connection = Struct.new(:target, :credentials, :args, :channel, keyword_init: true)

        def self.connect(target:, credentials:, args:)
          resolved = credentials.respond_to?(:call) ? credentials.call : credentials
          resolved = :this_channel_is_insecure if resolved == :insecure
          channel_credentials = resolved.is_a?(GRPC::Core::CallCredentials) ? GRPC::Core::ChannelCredentials.new : resolved
          channel = GRPC::ClientStub.setup_channel(nil, target, channel_credentials, args.dup)
          Connection.new(target:, credentials: resolved, args:, channel:)
        end

        def self.invoke(stub_class:, connection:, method:, request:, options:, around:, &)
          stub = stub_class.new(connection.target, connection.credentials,
                                channel_override: connection.channel, channel_args: connection.args.dup)
          stub.extend(ClientInvocation)
          stub.instance_variable_set(:@gritz_around, around)
          stub.public_send(method, request, options, &)
        end
      end
    end
  end
end
