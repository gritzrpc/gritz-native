# frozen_string_literal: true

require "gritz/native"
$LOAD_PATH.unshift(File.expand_path("../hello", __dir__))
require "hello_services_pb"

class SupervisorFailuresController < Gritz::Controller
  bind Helloworld::Greeter::Service

  def say_hello = Helloworld::HelloReply.new(message: "hello")
end

workers 1
bind ENV.fetch("FAILURE_BIND")
admin_bind "127.0.0.1:0"
status_interval 0.02
worker_timeout 1.0
worker_boot_timeout 2.0
drain_delay 0
shutdown_timeout 0.2
register_controller SupervisorFailuresController

record = lambda do |event|
  File.open(ENV.fetch("FAILURE_EVENTS"), "a") do |file|
    file.puts(JSON.generate(event: event, pid: Process.pid))
  end
end

on_worker_boot do
  record.call("boot")
  case ENV.fetch("FAILURE_MODE", nil)
  when "hard_exit" then Process.exit!(7)
  when "hard_exit_success" then Process.exit!(0)
  when "boot_cleanup" then raise "requested boot failure"
  when "hang_once"
    marker = ENV.fetch("FAILURE_MARKER")
    unless File.exist?(marker)
      File.write(marker, Process.pid.to_s)
      sleep 60
    end
  end
end

on_worker_shutdown do
  record.call("shutdown")
  if ENV["FAILURE_MODE"] == "boot_cleanup"
    sleep 0.08
    record.call("shutdown_done")
  end
  raise "requested shutdown hook failure" if ENV["FAILURE_MODE"] == "shutdown_error"
end
