# frozen_string_literal: true

require "gritz/native"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "socket"
require "time"
require "yaml"
require_relative "../spec/fixtures/hello/hello_pb"
$LOAD_PATH.unshift(File.expand_path("../spec/fixtures/hello", __dir__))
require "hello_services_pb"

options = { transport: "native", output: "tmp/chaos.json", tc: "tc" }
OptionParser.new do |parser|
  %i[transport output tc].each { |key| parser.on("--#{key} VALUE") { |value| options[key] = value } }
end.parse!
abort "Linux with CAP_NET_ADMIN is required" unless RUBY_PLATFORM.include?("linux")
abort "transport must be native or async" unless %w[native async].include?(options[:transport])
settings = YAML.safe_load_file(File.join(__dir__, "scenarios/chaos.yml"))
report = { started_at: Time.now.utc.iso8601, ruby: RUBY_DESCRIPTION, transport: options[:transport], settings:, events: [], passed: false }
FileUtils.mkdir_p(File.dirname(options[:output]))
listener = TCPServer.new("127.0.0.1", 0)
address = "127.0.0.1:#{listener.addr[1]}"
listener.close
cluster = Gritz::Testing::Cluster.new(config_path: File.join(__dir__, "server.rb"),
                                      env: { "BENCH_BIND" => address, "BENCH_TRANSPORT" => options[:transport],
                                             "BENCH_WORKERS" => settings.fetch("workers").to_s, "BENCH_THREADS" => settings.fetch("threads").to_s,
                                             "BENCH_MAX_MEMORY" => settings.fetch("memory_limit_mb").to_s, "GRITZ_ADMIN_BIND" => "127.0.0.1:0" })
clients = []
running = true
mutex = Mutex.new
totals = { requests: 0, errors: 0, corrupt_responses: 0, recovered_requests: 0, error_examples: [] }
request = lambda do |name|
  client = Helloworld::Greeter::Stub.new(address, :this_channel_is_insecure,
                                         channel_args: { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 })
  client.say_hello(Helloworld::HelloRequest.new(name:), deadline: Time.now + 3)
end
tc = lambda do |*args|
  output, status = Open3.capture2e(options[:tc], *args)
  raise "tc failed: #{output}" unless status.success?

  output
end
begin
  cluster.start.wait_until(workers: settings.fetch("workers"))
  report[:master_pid] = cluster.pid
  initial = cluster.workers.map { |worker| worker[:pid] }
  report[:initial_worker_pids] = initial
  settings.fetch("workers").times do
    clients << Thread.new do
      while running
        begin
          reply = request.call("light")
          mutex.synchronize do
            totals[:requests] += 1
            totals[:corrupt_responses] += 1 unless reply.message == "Hello, light"
          end
        rescue GRPC::BadStatus => e
          mutex.synchronize do
            totals[:errors] += 1
            totals[:error_examples] << "#{e.class}: #{e.details}" if totals[:error_examples].size < 10
          end
        end
        sleep 0.02
      end
    end
  end
  random = Random.new(settings.fetch("random_seed"))
  retired = []
  settings.fetch("random_kills").times do
    victim = cluster.workers.reject { |worker| worker[:retiring] }.sample(random:)[:pid]
    retired << victim
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.kill("KILL", victim)
    cluster.wait_until(workers: settings.fetch("workers"), timeout: settings.fetch("recovery_timeout_seconds")) do |snapshot|
      snapshot[:workers].none? { |worker| worker[:pid] == victim }
    end
    raise "post-kill RPC failed" unless request.call("light").message == "Hello, light"

    totals[:recovered_requests] += 1
    report[:events] << { type: "random_kill", pid: victim, recovery_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
  end
  # Refuse to overwrite a pre-existing network experiment. Run only in an owned network namespace.
  qdisc = tc.call("qdisc", "show", "dev", "lo")
  raise "loopback already has a configured qdisc" unless qdisc.include?("noqueue")

  tc.call("qdisc", "add", "dev", "lo", "root", "netem", "delay", "#{settings.fetch('network_delay_ms')}ms")
  injected = true
  delay_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  settings.fetch("network_requests").times do
    raise "network-delay response corruption" unless request.call("light").message == "Hello, light"
  end
  report[:events] << { type: "network_delay", qdisc: tc.call("-s", "qdisc", "show", "dev", "lo"),
                       successful_requests: settings.fetch("network_requests"), seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - delay_started }
  tc.call("qdisc", "del", "dev", "lo", "root")
  injected = false
  before = cluster.workers.map { |worker| worker[:pid] }
  report[:memory_before] = cluster.workers.map { |worker| worker.slice(:pid, :rss_bytes, :pss_bytes) }
  raise "memory-pressure RPC failed" unless request.call("pressure").message == "Hello, pressure"

  cluster.wait_until(workers: settings.fetch("workers"), timeout: settings.fetch("recovery_timeout_seconds")) do |snapshot|
    (before - snapshot[:workers].map { |worker| worker[:pid] }).any? && !snapshot[:phased_restart]
  end
  retired.concat(before - cluster.workers.map { |worker| worker[:pid] })
  raise "post-memory RPC failed" unless request.call("light").message == "Hello, light"

  report[:events] << { type: "memory_pressure", allocated_mb: 96, replaced_pids: before - cluster.workers.map { |worker| worker[:pid] } }
  retired.uniq.each do |pid|
    Process.kill(0, pid)
    raise "retired worker #{pid} was not reaped"
  rescue Errno::ESRCH
    next
  end
  report[:retired_worker_pids] = retired.uniq
  report[:final_worker_pids] = cluster.workers.map { |worker| worker[:pid] }
  raise "corrupt responses" if totals[:corrupt_responses].positive?

  report[:passed] = true
rescue StandardError => e
  report[:error] = "#{e.class}: #{e.message}"
  warn report[:error]
ensure
  running = false
  cleanup = [
    -> { tc.call("qdisc", "del", "dev", "lo", "root") if injected },
    -> { clients.each(&:value) },
    lambda {
      cluster.stop
      raise "cluster shutdown failed" unless cluster.wait.success?
    },
    -> { report[:network_restored] = tc.call("qdisc", "show", "dev", "lo").include?("noqueue") }
  ]
  cleanup.each do |action|
    action.call
  rescue StandardError => e
    report[:passed] = false
    (report[:cleanup_errors] ||= []) << "#{e.class}: #{e.message}"
  end
  report[:passed] = false unless report[:network_restored]
  report[:load] = totals
  report[:finished_at] = Time.now.utc.iso8601
  File.write("#{options[:output]}.cluster.log", cluster.logs) unless report[:passed]
  File.write(options[:output], "#{JSON.pretty_generate(report)}\n")
end
puts options[:output]
exit(report[:passed] ? 0 : 1)
