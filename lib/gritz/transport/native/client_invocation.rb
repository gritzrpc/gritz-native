# frozen_string_literal: true

module Gritz
  module Transport
    class Native
      # Captures the generated stub's route and keeps middleware around native completion.
      # @api private
      module ClientInvocation
        { request_response: :unary, client_streamer: :client_streaming,
          server_streamer: :server_streaming, bidi_streamer: :bidi }.each do |native_method, kind|
          define_method(native_method) do |method, request, marshal, unmarshal, **options, &block|
            terminal = lambda do |context, &_reply|
              execute_gritz_client(context) do |response|
                input = context.method.client_streaming? ? context.each_request : context.request
                super(method, input, marshal, unmarshal, **context.options.merge(return_op: true), &response)
              end
            end
            @gritz_around.call(terminal, method:, kind:, request:, options:, &block)
          end
        end

        private

        def execute_gritz_client(context)
          context.check_deadline!
          context.check_cancelled!
          response = if context.method.server_streaming?
                       lambda do |message|
                         context.check_deadline!
                         context.check_cancelled!
                         context.response_block.call(message)
                       end
                     end
          operation = yield(response)
          context.operation = operation
          result = operation.execute
          completed = true
          result
        rescue GRPC::BadStatus => e
          raise decode_gritz_error(e)
        ensure
          if operation && !completed
            context.store[:gritz_cancelled] = true
            cancel_gritz_operation(operation)
          end
        end

        def cancel_gritz_operation(operation)
          operation.cancel
        rescue GRPC::Core::CallError
          # A received non-OK status may already have closed the native call.
          nil
        end

        def decode_gritz_error(error)
          status = begin
            error.to_rpc_status
          rescue Google::Protobuf::ParseError, TypeError, ArgumentError
            nil
          end
          details = if status && status.code == error.code
                      status.details.map { |any| decode_gritz_detail(any) }
                    else
                      []
                    end
          code = error.code.is_a?(Integer) && (1...Errors::CODES.length).cover?(error.code) ? error.code : 2
          klass = Errors.for_code(code)
          klass.new(error.details, details:, metadata: error.metadata.dup, remote: true)
        end

        def decode_gritz_detail(any)
          descriptor = Google::Protobuf::DescriptorPool.generated_pool.lookup(any.type_name)
          descriptor.respond_to?(:msgclass) ? any.unpack(descriptor.msgclass) : any
        rescue Google::Protobuf::ParseError, TypeError, ArgumentError
          any
        end
      end
    end
  end
end
