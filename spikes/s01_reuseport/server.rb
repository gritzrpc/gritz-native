# frozen_string_literal: true

# Throwaway probe: no Gritz production code is loaded.
require "grpc"
require "json"
require "io/wait"
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require_relative "lib/echo_services_pb"

class EchoProbe < Echo::EchoService::Service
  def echo(request, _call)
    Echo::EchoReply.new(message: request.message, pid: Process.pid)
  end

  def burn(request, _call)
    started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    nil while Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - started < request.ms / 1000.0
    Echo::EchoReply.new(pid: Process.pid)
  end

  def chat(requests, _call)
    requests.lazy.map { |request| Echo::EchoReply.new(message: request.message, pid: Process.pid) }
  end
end

address = ENV.fetch("ADDRESS", "127.0.0.1:50051")
workers = Integer(ENV.fetch("WORKERS", "4"))
raise "WORKERS must be positive" unless workers.positive?
raise "Use a fixed port for reuseport" if address.end_with?(":0")

signal_read, signal_write = IO.pipe
signals = []
pids = []
%w[TERM INT TTIN].each do |signal|
  trap(signal) do
    signals << signal
    signal_write.write_nonblock(".", exception: false)
  end
end
$stdout.sync = true

spawn_worker = lambda do
  fork do
    signal_read.close
    signal_write.close
    %w[TERM INT TTIN].each { |signal| trap(signal, "DEFAULT") }
    args = { "grpc.so_reuseport" => 1 }
    age = Integer(ENV.fetch("MAX_CONNECTION_AGE_MS", "0"))
    args["grpc.max_connection_age_ms"] = age if age.positive?
    server = GRPC::RpcServer.new(pool_size: 8, poll_period: 1, server_args: args)
    server.add_http2_port(address, :this_port_is_insecure)
    server.handle(EchoProbe)
    runner = Thread.new { server.run_till_terminated_or_interrupted(%w[TERM INT]) }
    raise "Server did not start" unless server.wait_till_running(10)

    puts JSON.generate(event: "ready", pid: Process.pid, address: address)
    runner.join
    exit! 0
  end
end

workers.times { pids << spawn_worker.call }
stopping = false
until stopping && pids.empty?
  signal_read.wait_readable(0.1)
  signal_read.read_nonblock(4096, exception: false)
  while (signal = signals.shift)
    if signal == "TTIN" && !stopping
      pids << spawn_worker.call
    elsif signal != "TTIN"
      stopping = true
      pids.each do |pid|
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
  pids.dup.each do |pid|
    status = Process.waitpid2(pid, Process::WNOHANG)
    next unless status

    pids.delete(pid)
    puts JSON.generate(event: "exited", pid: pid, success: status.last.success?)
  end
end
