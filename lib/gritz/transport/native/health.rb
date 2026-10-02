# frozen_string_literal: true

require "grpc/health/v1/health_services_pb"

module Gritz
  module Transport
    class Native
      # Standard health RPCs share the server pool; each open Watch uses one pool thread.
      # @api private
      class Health < Grpc::Health::V1::Health::Service
        # Ruby's server call view cannot observe cancellation until the call ends.
        # Watch needs a dedicated close observer, with at most one per occupied pool thread.
        class WatchDescriptor < GRPC::RpcDesc
          def handle_server_streamer(active_call, method, interception)
            request = active_call.read_unary_request
            call = active_call.single_req_view
            raw = active_call.instance_variable_get(:@call)
            closed = false
            observer = Thread.new do
              raw.run_batch(GRPC::Core::CallOps::RECV_CLOSE_ON_SERVER => nil)
            rescue GRPC::Core::CallError
              nil
            ensure
              closed = true
              method.receiver.wake
            end
            call.define_singleton_method(:cancelled?) { closed }
            status = begin
              interception.intercept!(:server_streamer, method:, call:, request:) do
                method.call(request, call).each { |reply| active_call.remote_send(reply) }
              end
              ::Struct::Status.new(GRPC::Core::StatusCodes::OK, "OK", active_call.output_metadata)
            rescue GRPC::BadStatus => e
              ::Struct::Status.new(e.code, e.details, e.metadata)
            rescue GRPC::Core::OutOfTime
              ::Struct::Status.new(GRPC::Core::StatusCodes::DEADLINE_EXCEEDED, "late", {})
            rescue StandardError, NotImplementedError
              ::Struct::Status.new(GRPC::Core::StatusCodes::UNKNOWN, "Health handler failed", {})
            end
            active_call.send_initial_metadata
            raw.run_batch(GRPC::Core::CallOps::SEND_STATUS_FROM_SERVER => status)
            observer.join
          rescue GRPC::Core::CallError
            nil
          ensure
            if observer
              raw.cancel if observer.alive?
              observer.join
              # Finish only after the native close operation has released its call resources.
              active_call.__send__(:set_output_stream_done)
            end
          end
        end

        rpc_descs[:Watch] = WatchDescriptor.new(*rpc_descs.fetch(:Watch).to_a)

        def initialize(services)
          super()
          @services = ["", *services].to_set
          @mutex = Mutex.new
          @changed = ConditionVariable.new
          @serving = @closed = false
        end

        def update(ready)
          @mutex.synchronize do
            serving = ready && !@closed
            @changed.broadcast if serving != @serving
            @serving = serving
          end
        end

        def drain!
          @mutex.synchronize do
            @serving = false
            @closed = true
            @changed.broadcast
          end
        end

        def wake = @mutex.synchronize { @changed.broadcast }

        def check(request, _call)
          raise GRPC::NotFound, "unknown service" unless @services.include?(request.service)

          @mutex.synchronize { Grpc::Health::V1::HealthCheckResponse.new(status: status_for(request.service)) }
        end

        def watch(request, call)
          Enumerator.new do |replies|
            previous = nil
            loop do
              status, closed = @mutex.synchronize do
                @changed.wait(@mutex, 0.05) while !@closed && !call.cancelled? && status_for(request.service) == previous
                [status_for(request.service), @closed]
              end
              break if call.cancelled?

              if status != previous
                replies << Grpc::Health::V1::HealthCheckResponse.new(status:)
                previous = status
              end
              break if closed
            end
          end
        end

        private

        def status_for(service)
          return :SERVICE_UNKNOWN unless @services.include?(service)

          @serving ? :SERVING : :NOT_SERVING
        end
      end
    end
  end
end
