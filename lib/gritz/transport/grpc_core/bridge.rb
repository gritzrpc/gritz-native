# frozen_string_literal: true

module Gritz
  module Transport
    class GrpcCore
      # Installs handlers with the arities checked by GRPC::RpcDesc.
      # @api private
      module Bridge
        def self.build(service_class, descriptors, adapter)
          Class.new(service_class) do
            self.service_name = service_class.service_name
            descriptors.each do |descriptor|
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
