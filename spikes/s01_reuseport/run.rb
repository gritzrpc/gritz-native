# frozen_string_literal: true

# Orchestrator deliberately never requires grpc, even though servers and clients do.
require "open3"
require "json"
require "rbconfig"
require "io/wait"

def ready(output, count, pids)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  until pids.length == count
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise "Worker readiness timeout" unless remaining.positive? && output.wait_readable(remaining)

    line = output.gets
    raise "Server exited during boot" unless line

    event = JSON.parse(line)
    pids << event.fetch("pid") if event["event"] == "ready"
  end
end

workers = Integer(ENV.fetch("WORKERS", "4"))
server_in, server_out, server_err, server = Open3.popen3(RbConfig.ruby, File.join(__dir__, "server.rb"))
pids = []
begin
  ready(server_out, workers, pids)
  tally, status = Open3.capture2(RbConfig.ruby, File.join(__dir__, "tally.rb"))
  raise "Tally failed" unless status.success?

  client_in, client_out, client_err, client = Open3.popen3(RbConfig.ruby, File.join(__dir__, "client.rb"))
  client_in.close
  if ENV["DRAIN"] == "1"
    sleep Float(ENV.fetch("DRAIN_AT", "2"))
    if ENV["REPLACE"] == "1"
      Process.kill("TTIN", server.pid)
      ready(server_out, workers + 1, pids)
    end
    Process.kill("TERM", pids.first)
  end
  result = client_out.read
  raise "Client failed: #{client_err.read}" unless client.value.success?

  puts JSON.pretty_generate(
    workers: workers, tcp_migrate_req: File.exist?("/proc/sys/net/ipv4/tcp_migrate_req") ? File.read("/proc/sys/net/ipv4/tcp_migrate_req").strip.to_i : nil,
    drain: ENV["DRAIN"] == "1", replacement: ENV["REPLACE"] == "1",
    drained_pid: ENV["DRAIN"] == "1" ? pids.first : nil,
    replacement_pid: ENV["REPLACE"] == "1" ? pids.last : nil,
    max_connection_age_ms: Integer(ENV.fetch("MAX_CONNECTION_AGE_MS", "0")),
    tally: JSON.parse(tally), load: JSON.parse(result)
  )
ensure
  Process.kill("TERM", server.pid) if server.alive?
  server.value
  server_in.close
  server_out.close
  errors = server_err.read
  warn errors unless errors.empty?
  server_err.close
end
