# frozen_string_literal: true

require "gritz/native"
$LOAD_PATH.unshift(File.expand_path("../../spec/fixtures/hello", __dir__))
require "hello_services_pb"

class KubernetesGreeterController < Gritz::Controller
  bind Helloworld::Greeter::Service

  def say_hello
    Helloworld::HelloReply.new(message: "#{ENV.fetch('REVISION', 'a')}:#{Process.pid}:Hello, #{request.message.name}")
  end
end

bind "0.0.0.0:50051"
admin_bind "0.0.0.0:9090"
workers 2
threads 16
min_ready_workers 2
status_interval 0.1
drain_delay 5.0
shutdown_timeout 25.0
register_controller KubernetesGreeterController
preload_app!
