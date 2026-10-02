# frozen_string_literal: true

module Gritz
  module Transport
    class Native
      # Adapts RpcServer's lifecycle and rejection callbacks.
      # @api private
      class Server < GRPC::RpcServer
        def initialize(on_rejected:, **)
          @on_rejected = on_rejected
          super(**)
        end

        def available?(rpc)
          result = super
          @on_rejected.call unless result
          result
        end

        def busy_threads
          # grpc 1.83 has no public busy count; its idle queues cover decode and
          # response writes as well as handlers. Live threads also handle pre-start/stop.
          workers = @pool.instance_variable_get(:@workers)
          ready = @pool.instance_variable_get(:@ready_workers)
          [workers.count(&:alive?) - ready.size, 0].max
        end

        def stop(deadline:)
          # grpc 1.83's stop takes no deadline and reads @poll_period instead.
          # Set its relative grace from the caller's absolute shutdown deadline.
          @poll_period = [deadline - Time.now, 0].max
          super()
        end

        # RpcServer's loop checks running_state before every RequestCall. Its stop
        # holds that mutex during shutdown_and_notify, so an accepted RPC can leave
        # the loop blocked while C-core still has unmatched calls. Keep consuming
        # until C-core closes RequestCall instead of stopping on the Ruby state.
        def loop_handle_server_calls
          raise "not started" if running_state == :not_started

          loop do
            rpc = @server.request_call
            break if rpc && rpc.call.nil?

            active_call = new_active_server_call(rpc)
            next unless active_call

            @pool.schedule(active_call) do |pair|
              call, method = pair
              rpc_descs[method].run_server_method(call, rpc_handlers[method], @interceptors.build_context)
            rescue StandardError
              call.send_status(GRPC::Core::StatusCodes::INTERNAL, "Server handler failed")
            end
          rescue GRPC::Core::CallError, RuntimeError => e
            break unless running_state == :running

            GRPC.logger.warn("server call failed: #{e}")
          end
          @run_mutex.synchronize do
            transition_running_state(:stopped)
            @server.close
          end
        end

        def close_unstarted
          return unless running_state == :not_started

          @pool.stop
          # C-core requires shutdown even when a bound listener was never started.
          @server.shutdown_and_notify(Time.now)
          @server.close
        end
      end
    end
  end
end
