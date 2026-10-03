# frozen_string_literal: true

module Gritz
  module Transport
    class Native
      # grpc's server views read a client-status field which is never populated
      # during a server handler. Observe C-core's close notification instead.
      # @api private
      module Cancellation
        module ActiveCall
          def cancelled? = @call.gritz_cancelled?
        end

        module CoreCall
          def self.extended(call)
            call.instance_variable_set(:@gritz_cancellation_mutex, Mutex.new)
          end

          def gritz_cancelled?
            return @gritz_cancelled || false if @gritz_close_observer || @gritz_status_sent || @gritz_closed

            @gritz_cancellation_mutex.synchronize do
              return @gritz_cancelled || false if @gritz_close_observer || @gritz_status_sent || @gritz_closed

              @gritz_cancelled ||= false
              @gritz_close_observer = Thread.new do
                method(:run_batch).super_method.call(GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER => nil)
              rescue GRPC::Core::CallError
                nil
              ensure
                # grpc's BatchResult does not expose the C-core cancelled flag.
                # Preserve failed-status cancellation if the observer runs later.
                @gritz_cancelled ||= !@gritz_status_sent
              end
              @gritz_cancelled
            end
          end

          def run_batch(operations)
            # C-core accepts RECV_CLOSE only once. Its observer owns this op;
            # grpc's ordinary status batches retain all their send operations.
            sending_status = operations.key?(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER)
            receiving_close = operations.key?(GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER)
            if sending_status || receiving_close
              @gritz_cancellation_mutex.synchronize do
                operations = operations.except(GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER) if receiving_close && @gritz_close_observer
                @gritz_status_sent = true if sending_status
              end
            end
            super
          rescue GRPC::Core::CallError
            @gritz_cancelled = true if sending_status
            raise
          end

          def close
            @gritz_cancellation_mutex.synchronize do
              @gritz_close_observer&.join
              @gritz_closed = true
              super
            end
          end

          def finish_gritz_call
            @gritz_cancellation_mutex.synchronize do
              @gritz_closed = true
              cancel if @gritz_close_observer&.alive?
            end
            close
          end
        end

        class Descriptor < GRPC::RpcDesc
          def run_server_method(active_call, ...)
            raw = active_call.instance_variable_get(:@call)
            raw.extend(CoreCall)
            active_call.extend(ActiveCall)
            super
          ensure
            raw&.finish_gritz_call
          end
        end
      end
    end
  end
end
