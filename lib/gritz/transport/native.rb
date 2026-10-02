# frozen_string_literal: true

require "set" # rubocop:disable Lint/RedundantRequireStatement -- required by Ruby 3.3
require "securerandom"

module Gritz
  module Transport
    # Runs generated services through Gritz's transport-independent dispatcher.
    # @api public
    class Native
      def self.capabilities = Set[:unary, :client_streaming, :server_streaming, :bidi, :reuseport, :health, :tls, :mtls, :reflection].freeze

      def self.prefork
        GRPC.prefork
      rescue RuntimeError => e
        raise "#{e.message}. fork_mode :grpc_fork_support requires GRPC_ENABLE_FORK_SUPPORT=1 before requiring grpc."
      end

      def self.postfork_parent = GRPC.postfork_parent
      def self.postfork_child = GRPC.postfork_child

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
        raise ArgumentError, "at least one controller must be registered" if @dispatcher.router.routes.empty?

        credentials = server_credentials
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
        @health = Health.new(@dispatcher.router.routes.values.map(&:service).uniq)
        @server.handle(@health)
        if @config.reflection
          require_relative "native/reflection"
          services = @dispatcher.router.routes.values.map(&:service).uniq + [Health.service_name]
          Reflection.build(services).each { |service| @server.handle(service) }
        end
        @port = @server.add_http2_port(listener_spec, credentials)
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
        if @server.wait_till_running(5)
          refresh_health
          return self
        end

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
        drain!
        unless @thread
          @server&.close_unstarted
          @server = nil
          return
        end

        @server.stop(deadline:)
        wait
      end

      def kill = stop(deadline: Time.now)

      def update_health(ready:, checks: {})
        healthy = ready && checks.values.all? && !@draining
        @health&.update(healthy)
        healthy
      end

      def drain!
        @draining = true
        @health&.drain!
        self
      end

      # @api private
      def refresh_health
        checks = @config.health_checks.transform_values do |check|
          check.call ? true : false
        rescue StandardError => e
          @logger.warn("Health check failed (#{e.class})")
          false
        end
        update_health(ready: running?, checks:)
      end

      def stats
        busy = @server&.busy_threads || 0
        @lock.synchronize do
          oldest = @inflight.values.min
          {
            inflight: @inflight.size, busy: busy, capacity: @config.threads,
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

      def server_credentials
        return :this_port_is_insecure if @config.tls.empty?

        ca = @config.tls[:client_ca] && File.read(@config.tls[:client_ca])
        GRPC::Core::ServerCredentials.new(ca, [{ private_key: File.read(@config.tls.fetch(:key)),
                                                 cert_chain: File.read(@config.tls.fetch(:cert)) }], !ca.nil?)
      end

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
