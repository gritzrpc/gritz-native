#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "socket"
require "time"
require "gritz/native"

options = { ghz: "ghz", duration: 30, output: "tmp/phased-restart.json", transport: "native" }
OptionParser.new do |parser|
  parser.banner = "Usage: bundle exec ruby bench/phased_restart.rb [options] (Linux)"
  parser.on("--ghz PATH") { |value| options[:ghz] = value }
  parser.on("--duration SECONDS", Float) { |value| options[:duration] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--transport NAME") { |value| options[:transport] = value }
end.parse!
abort "Linux is required for the reuseport restart gate" unless RUBY_PLATFORM.include?("linux")
abort "duration must be at least 10 seconds" unless options[:duration] >= 10
abort "transport must be native or async" unless %w[native async].include?(options[:transport])

def free_address
  listener = TCPServer.new("127.0.0.1", 0)
  "127.0.0.1:#{listener.addr[1]}"
ensure
  listener&.close
end

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

address = free_address
output = File.expand_path(options[:output])
FileUtils.mkdir_p(File.dirname(output))
raw_output = "#{output.sub(/\.json\z/, '')}-ghz.json"
ghz_log = "#{output.sub(/\.json\z/, '')}-ghz.log"
environment = { "CLUSTER_BIND" => address, "CLUSTER_WORKERS" => "4", "GRITZ_ADMIN_BIND" => free_address,
                "GRITZ_DRAIN_DELAY" => "0.2", "GRITZ_SHUTDOWN_TIMEOUT" => "5",
                "BENCH_BIND" => address, "BENCH_TRANSPORT" => options[:transport], "BENCH_WORKERS" => "4", "BENCH_THREADS" => "16" }
config = options[:transport] == "async" ? "server.rb" : "../spec/integration/cluster/config.rb"
cluster = Gritz::Testing::Cluster.new(config_path: File.expand_path(config, __dir__), env: environment)
report = { started_at: Time.now.utc.iso8601, duration_seconds: options[:duration], workers: 4, passed: false,
           ruby: RUBY_DESCRIPTION, grpc: GRPC::VERSION, transport: options[:transport] }

begin
  cluster.start.wait_until(workers: 4)
  old = cluster.workers.map { |worker| worker.fetch(:pid) }
  report[:old_worker_pids] = old
  ghz_pid = Process.spawn(
    options[:ghz], "--insecure", "--proto=#{File.expand_path('../spec/fixtures/hello/hello.proto', __dir__)}",
    "--call=helloworld.Greeter/SayHello", "--data=#{JSON.generate(name: options[:transport] == 'async' ? 'io' : 'slow:0.01')}",
    "--connections=64", "--concurrency=64",
    "--rps=100", "--duration=#{options[:duration]}s", "--duration-stop=wait", "--timeout=2s",
    "--format=json", "--output=#{raw_output}", address, out: ghz_log, err: ghz_log
  )
  cluster.wait_until(workers: 4, timeout: 5) do |status|
    rows = status.fetch(:workers)
    rows.all? { |worker| worker.fetch(:requests_total, 0).positive? } && rows.sum { |worker| worker[:requests_total] } >= 50
  end
  report[:requests_before_restart] = cluster.workers.to_h { |worker| [worker[:pid], worker[:requests_total]] }
  started = monotonic
  cluster.signal("USR1").wait_until(workers: 4, timeout: 10) do |status|
    !status[:phased_restart] && status[:workers].none? { |worker| old.include?(worker[:pid]) }
  end
  report[:restart_seconds] = monotonic - started
  report[:new_worker_pids] = cluster.workers.map { |worker| worker[:pid] }
  old.each do |pid|
    Process.kill(0, pid)
    raise "retired worker #{pid} was not reaped"
  rescue Errno::ESRCH
    next
  end
  deadline = monotonic + options[:duration] + 5
  until (pair = Process.waitpid2(ghz_pid, Process::WNOHANG))
    raise "ghz did not exit by its deadline" if monotonic >= deadline

    cluster.wait_until(timeout: 1)
    sleep 0.05
  end
  ghz_status = pair.last
  ghz_pid = nil
  result = JSON.parse(File.read(raw_output))
  report[:ghz] = result.slice("count", "total", "average", "statusCodeDistribution", "errorDistribution")
  raise "ghz failed: #{File.read(ghz_log)}" unless ghz_status.success?
  raise "ghz did not complete any RPCs" unless result.fetch("count").positive?
  raise "ghz reported errors: #{result['errorDistribution'].inspect}" unless result.fetch("errorDistribution").empty?
  raise "ghz reported non-OK responses" unless result.fetch("statusCodeDistribution").keys == ["OK"]

  cluster.wait_until(workers: 4) { |status| status[:workers].all? { |worker| worker.fetch(:requests_total, 0).positive? } }
  report[:requests_after_restart] = cluster.workers.to_h { |worker| [worker[:pid], worker[:requests_total]] }
  cluster.stop
  raise "cluster shutdown failed" unless cluster.wait.success?

  report[:passed] = true
rescue StandardError => e
  report[:error] = "#{e.class}: #{e.message}"
  File.write("#{output.sub(/\.json\z/, '')}-cluster.log", cluster.logs)
  warn report[:error]
ensure
  if ghz_pid
    begin
      Process.kill("KILL", ghz_pid)
      Process.waitpid(ghz_pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # The owned load generator may have exited just before cleanup.
    end
  end
  begin
    cluster.stop
  ensure
    report[:finished_at] = Time.now.utc.iso8601
    File.write(output, "#{JSON.pretty_generate(report)}\n")
  end
end

puts JSON.generate(report)
exit(report[:passed] ? 0 : 1)
