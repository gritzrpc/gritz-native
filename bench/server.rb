# frozen_string_literal: true

require "gritz/#{ENV.fetch('BENCH_TRANSPORT', 'native')}"
$LOAD_PATH.unshift(File.expand_path("../spec/fixtures/hello", __dir__))
require_relative "../spec/fixtures/hello/hello_pb"

if ENV["BENCH_TRANSPORT"] == "async"
  class BenchGreeter < Gritz::Async::Service
    self.service_name = "helloworld.Greeter"
    rpc :SayHello, Helloworld::HelloRequest, Helloworld::HelloReply
    rpc :ListGreetings, Helloworld::HelloRequest, stream(Helloworld::HelloReply)
    rpc :Chat, stream(Helloworld::HelloRequest), stream(Helloworld::HelloReply)
  end
else
  require_relative "../spec/fixtures/hello/hello_services_pb"
  BenchGreeter = Helloworld::Greeter::Service
end

module BenchWorkload
  def self.reply(message)
    case message.name
    when "io" then sleep 0.01
    when "cpu"
      value = 0
      20_000.times { |index| value = (value + (index * index)) % 65_521 }
    when "pressure"
      # Allocated in the worker, with a configured RSS recycle threshold.
      @pressure = "x" * (96 * 1024 * 1024)
    end
    Helloworld::HelloReply.new(message: message.name == "pid" ? Process.pid.to_s : "Hello, #{message.name}")
  end
end

if ENV["BENCH_RAW"] == "1"
  class RawBenchGreeter < BenchGreeter
    def say_hello(message, _call) = BenchWorkload.reply(message)

    def list_greetings(message, _call)
      3.times.map { Helloworld::HelloReply.new(message: message.name) }.each
    end

    def chat(messages, _call)
      Enumerator.new { |stream| messages.each { |message| stream << Helloworld::HelloReply.new(message: message.name) } }
    end
  end
  server = GRPC::RpcServer.new(pool_size: Integer(ENV.fetch("BENCH_THREADS", "64")), pool_keep_alive: 0)
  server.add_http2_port(ENV.fetch("BENCH_BIND"), :this_port_is_insecure)
  server.handle(RawBenchGreeter)
  server.run_till_terminated_or_interrupted(%w[TERM INT])
else
  class BenchController < Gritz::Controller
    bind BenchGreeter

    def say_hello = BenchWorkload.reply(request.message)

    def list_greetings
      3.times { stream.write(Helloworld::HelloReply.new(message: request.message.name)) }
    end

    def chat
      request.each_message { |message| stream.write(Helloworld::HelloReply.new(message: message.name)) }
    end
  end
  transport ENV.fetch("BENCH_TRANSPORT", "native").to_sym
  listener_strategy :inherited_fd if ENV["BENCH_TRANSPORT"] == "async"
  bind ENV.fetch("BENCH_BIND")
  workers Integer(ENV.fetch("BENCH_WORKERS", "1"))
  threads Integer(ENV.fetch("BENCH_THREADS", "64"))
  drain_delay 0.2
  shutdown_timeout 3
  status_interval 0.5
  worker_timeout 30
  worker_recycle(max_rss_mb: Integer(ENV["BENCH_MAX_MEMORY"])) if ENV["BENCH_MAX_MEMORY"]
  register_controller BenchController
  preload_app!
end
