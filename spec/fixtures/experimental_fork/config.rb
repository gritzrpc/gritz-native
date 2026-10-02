# frozen_string_literal: true

require "gritz/native"
require "json"
$LOAD_PATH.unshift(File.expand_path("../hello", __dir__))
require "hello_services_pb"

class ExperimentalForkController < Gritz::Controller
  bind Helloworld::Greeter::Service

  def say_hello
    Helloworld::HelloReply.new(message: "#{Process.pid}:#{request.message.name}")
  end
end

workers 1
bind ENV.fetch("EXPERIMENTAL_BIND")
fork_mode :grpc_fork_support
status_interval 0.05
worker_timeout 2.0
worker_boot_timeout 5.0
drain_delay 0.05
shutdown_timeout 1.0
register_controller ExperimentalForkController

preload_app! do
  client = Helloworld::Greeter::Stub.new(ENV.fetch("EXPERIMENTAL_UPSTREAM"), :this_channel_is_insecure)
  ExperimentalForkController.const_set(:MASTER_CLIENT, client)
end

before_fork do |index|
  reply = ExperimentalForkController::MASTER_CLIENT.say_hello(
    Helloworld::HelloRequest.new(name: "master:#{index}"), deadline: Time.now + 3
  )
  File.open(ENV.fetch("EXPERIMENTAL_EVENTS"), "a") do |file|
    file.puts(JSON.generate(pid: Process.pid, index:, message: reply.message))
  end
end
