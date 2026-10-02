# frozen_string_literal: true

require_relative "application"

workers Integer(ENV.fetch("CLIENT_E2E_WORKERS", "1"))
bind ENV.fetch("CLIENT_E2E_BIND")
admin_bind ENV.fetch("CLIENT_E2E_ADMIN")
status_interval 0.02
worker_timeout 2.0
worker_boot_timeout 5.0
drain_delay 0.02
shutdown_timeout 1.0
preload_app!
register_controller ClientChain::Controller

if ENV["CLIENT_E2E_PASSTHROUGH"] == "true"
  middleware do |stack|
    stack.swap(Gritz::Middleware::ExceptionMapper, Gritz::Middleware::ExceptionMapper, passthrough_remote_errors: true)
  end
end
