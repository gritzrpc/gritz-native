# frozen_string_literal: true

# Run against S-01's server in another process. Set the flag BEFORE requiring grpc.
ENV["GRPC_ENABLE_FORK_SUPPORT"] = "1"
require "grpc"
require "json"
require "io/wait"
$LOAD_PATH.unshift(File.expand_path("../s01_reuseport/lib", __dir__))
require "echo_services_pb"

raise "Experimental fork probe requires Linux" unless RUBY_PLATFORM.include?("linux")

pid = nil
begin
  stub = Echo::EchoService::Stub.new(ENV.fetch("ADDRESS", "127.0.0.1:50051"), :this_channel_is_insecure)
  response = stub.echo(Echo::EchoRequest.new(message: "master"), deadline: Time.now + 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GRPC.prefork
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  read_pipe, write_pipe = IO.pipe
  pid = fork do
    read_pipe.close
    GRPC.postfork_child
    server = GRPC::RpcServer.new(pool_size: 2)
    port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
    implementation = Class.new(Echo::EchoService::Service) do
      def echo(request, _call)
        Echo::EchoReply.new(message: request.message, pid: Process.pid)
      end
    end
    server.handle(implementation)
    runner = Thread.new { server.run_till_terminated_or_interrupted(["TERM"]) }
    raise "Child server did not start" unless server.wait_till_running(10)

    write_pipe.puts port
    write_pipe.close
    runner.join
    exit! 0
  rescue StandardError => e
    warn e.full_message
    exit! 1
  end
  GRPC.postfork_parent
  write_pipe.close
  raise "Child server readiness timeout" unless read_pipe.wait_readable(10)

  port = Integer(read_pipe.gets)
  child_stub = Echo::EchoService::Stub.new("127.0.0.1:#{port}", :this_channel_is_insecure)
  child_response = child_stub.echo(Echo::EchoRequest.new(message: "child"), deadline: Time.now + 3)
  raise "Wrong child PID" unless child_response.pid == pid

  puts JSON.pretty_generate(
    grpc: GRPC::VERSION, ruby: RUBY_DESCRIPTION, prefork_ms: elapsed * 1000,
    master_rpc: response.message, child_rpc: child_response.message, child_server: true
  )
ensure
  Process.kill("TERM", pid) if pid
  Process.waitpid(pid) if pid
end
