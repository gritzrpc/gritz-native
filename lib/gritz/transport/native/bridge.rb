# frozen_string_literal: true

require_relative "cancellation"

module Gritz
  module Transport
    class Native
      # Installs handlers with the arities checked by GRPC::RpcDesc.
      # @api private
      module Bridge
        def self.build(service_class, descriptors, adapter)
          Class.new(service_class) do
            self.service_name = service_class.service_name
            descriptors.each do |descriptor|
              rpc_name = descriptor.name.to_sym
              rpc_descs[rpc_name] = Cancellation::Descriptor.new(*rpc_descs.fetch(rpc_name).to_a)
              case descriptor.kind
              when :client_streaming
                define_method(descriptor.action) do |view|
                  adapter.dispatch(Call.new(method_descriptor: descriptor, view:, messages: view.each_remote_read))
                end
              when :unary
                define_method(descriptor.action) do |request, view|
                  adapter.dispatch(Call.new(method_descriptor: descriptor, view:, messages: [request]))
                end
              else
                define_method(descriptor.action) do |request, view|
                  messages = descriptor.client_streaming? ? request : [request]
                  Enumerator.new do |writer|
                    adapter.dispatch(Call.new(method_descriptor: descriptor, view:, messages:, writer:))
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
