# frozen_string_literal: true

module Gritz
  module Transport
    class GrpcCore
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

        def stop(deadline:)
          # grpc 1.83's stop takes no deadline and reads @poll_period instead.
          # Set its relative grace from the caller's absolute shutdown deadline.
          @poll_period = [deadline - Time.now, 0].max
          super()
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
