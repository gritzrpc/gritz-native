# frozen_string_literal: true

require "set" # rubocop:disable Lint/RedundantRequireStatement -- required by Ruby 3.3
require "securerandom"

module Gritz
  module Transport
    # Runs generated services through Gritz's transport-independent dispatcher.
    # @api public
    class Native
      def self.capabilities = Set[:unary, :client_streaming, :server_streaming, :bidi, :reuseport].freeze

      def initialize(config:, dispatcher:, logger:)
        @config = config
        @dispatcher = dispatcher
        @logger = logger
        @lock = Mutex.new
        @inflight = {}.compare_by_identity
        @requests_total = @rejected_total = 0
      end

      # Creates C-core resources only when binding, so construction is safe before fork.
      # @return [Integer] the port selected by C-core
      def bind(listener_spec = @config.bind)
        raise ArgumentError, "transport is already bound" if @server
        raise ArgumentError, "TLS is not available in this version" unless @config.tls.empty?
        raise ArgumentError, "at least one controller must be registered" if @dispatcher.router.routes.empty?

        created_server = @server = Server.new(
          pool_size: @config.threads,
          # grpc 1.83 accepts but ignores this value: busy pools reject immediately.
          max_waiting_requests: @config.max_waiting_requests,
          poll_period: @config.shutdown_timeout,
          pool_keep_alive: 0,
          server_args: @config.server_args,
          on_rejected: -> { @lock.synchronize { @rejected_total += 1 } }
        )
        @dispatcher.router.routes.values.group_by(&:service_class).each do |service_class, descriptors|
          @server.handle(Bridge.build(service_class, descriptors, self))
        end
        @port = @server.add_http2_port(listener_spec, :this_port_is_insecure)
        raise ArgumentError, "could not bind #{listener_spec}" unless @port.positive?

        @port
      rescue StandardError
        created_server&.close_unstarted
        @server = nil if created_server
        raise
      end

      def start
        raise ArgumentError, "bind must be called before start" unless @server
        raise ArgumentError, "transport is already started" if @thread

        @thread = Thread.new { @server.run }
        return self if @server.wait_till_running(5)

        @thread.value unless @thread.alive?
        kill
        raise "gRPC server did not start within 5 seconds"
      rescue StandardError
        @server&.close_unstarted
        raise
      end

      def wait = @thread&.value
      def running? = @thread&.alive? && @server.running?

      def stop(deadline:)
        unless @thread
          @server&.close_unstarted
          @server = nil
          return
        end

        @server.stop(deadline:)
        wait
      end

      def kill = stop(deadline: Time.now)

      def stats
        @lock.synchronize do
          oldest = @inflight.values.min
          {
            inflight: @inflight.size, busy: @inflight.size, capacity: @config.threads,
            rejected_total: @rejected_total, requests_total: @requests_total,
            oldest_inflight_age: oldest ? Process.clock_gettime(Process::CLOCK_MONOTONIC) - oldest : 0
          }
        end
      end

      # @api private
      def dispatch(call)
        @lock.synchronize do
          @inflight[call] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @requests_total += 1
        end
        @dispatcher.call(call)
      rescue Gritz::Error => e
        raise status_exception(call, e)
      ensure
        @lock.synchronize { @inflight.delete(call) }
      end

      private

      def status_exception(call, error)
        metadata = call.trailing_metadata.merge(error.metadata)
        unless error.details.empty?
          details = error.details.map do |detail|
            detail.is_a?(Google::Protobuf::Any) ? detail : Google::Protobuf::Any.pack(detail)
          end
          status = Google::Rpc::Status.new(code: error.grpc_code, message: error.message, details:)
          metadata["grpc-status-details-bin"] = Google::Rpc::Status.encode(status)
        end
        GRPC::BadStatus.new_status_exception(error.grpc_code, error.message, metadata)
      rescue StandardError => e
        error_id = SecureRandom.uuid
        @logger.error("#{error_id}: #{e.full_message}")
        GRPC::Internal.new("internal error (#{error_id})", { "error-id" => error_id })
      end
    end
  end
end
