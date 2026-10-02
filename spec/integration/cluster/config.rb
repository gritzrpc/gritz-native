# frozen_string_literal: true

require "gritz/native"
$LOAD_PATH.unshift(File.expand_path("../../fixtures/hello", __dir__))
require "hello_services_pb"

class ClusterGreeterController < Gritz::Controller
  bind Helloworld::Greeter::Service

  def say_hello
    name = request.message.name
    sleep(Float(name.delete_prefix("slow:"))) if name.start_with?("slow:")
    sleep 60 if name == "hang"
    Helloworld::HelloReply.new(message: name == "pid" ? Process.pid.to_s : "Hello, #{name}")
  end

  def record_names = Helloworld::HelloReply.new(count: request.each_message.count)

  def list_greetings
    3.times { |index| stream.write(Helloworld::HelloReply.new(message: "#{request.message.name}:#{index}")) }
  end

  def chat
    request.each_message { |message| stream.write(Helloworld::HelloReply.new(message: message.name.upcase)) }
  end
end

workers Integer(ENV.fetch("CLUSTER_WORKERS", "2"))
bind ENV.fetch("CLUSTER_BIND", "127.0.0.1:50051")
status_interval 0.05
worker_timeout 1.0
worker_boot_timeout 5.0
drain_delay 0.05
shutdown_timeout 2.0
register_controller ClusterGreeterController
health_check(:dependency) { File.read(ENV.fetch("CLUSTER_HEALTH_FILE")) == "ready" } if ENV["CLUSTER_HEALTH_FILE"]

record = lambda do |event, index|
  path = ENV.fetch("CLUSTER_EVENTS", nil)
  next unless path

  File.open(path, "a") do |file|
    file.flock(File::LOCK_EX)
    file.puts(JSON.generate(event: event, pid: Process.pid, index: index))
  end
end
preload_app! { record.call("preload", nil) }
before_fork { |index| record.call("before_fork", index) }
on_worker_boot do |index|
  record.call("boot", index)
  raise "requested boot failure" if ENV["CLUSTER_BOOT_MODE"] == "fail"

  exit 7 if ENV["CLUSTER_BOOT_MODE"] == "exit"
  sleep 60 if ENV["CLUSTER_BOOT_MODE"] == "hang"
end
on_worker_shutdown { |index| record.call("shutdown", index) }
