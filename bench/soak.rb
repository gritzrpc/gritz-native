# frozen_string_literal: true

require "gritz/native"
require "yaml"
require "json"
require "socket"
require "fileutils"
require "optparse"
require "time"

abort "This multiprocess soak scenario requires Linux" unless RUBY_PLATFORM.include?("linux")

options = { scenario: File.join(__dir__, "scenarios/soak.yml"), output: File.expand_path("../tmp/soak-result.json", __dir__) }
OptionParser.new do |parser|
  parser.on("--duration SECONDS", Float) { |value| options[:duration] = value }
  parser.on("--scenario PATH") { |value| options[:scenario] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
end.parse!
settings = YAML.safe_load_file(options[:scenario])
settings["duration_seconds"] = options[:duration] if options[:duration]
settings.each do |name, value|
  abort "#{name} must be a positive finite number" unless value.is_a?(Numeric) && value.finite? && value.positive?
end
%w[workers clients].each do |name|
  abort "#{name} must be an integer" unless settings.fetch(name).is_a?(Integer)
end
FileUtils.mkdir_p(File.dirname(options[:output]))
$LOAD_PATH.unshift(File.expand_path("../spec/fixtures/hello", __dir__))
require "hello_services_pb"

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def memory(pid)
  status = File.read("/proc/#{pid}/status")
  rollup = File.read("/proc/#{pid}/smaps_rollup")
  { pid: pid, rss_kb: status[/^VmRSS:\s+(\d+)/, 1].to_i, pss_kb: rollup[/^Pss:\s+(\d+)/, 1].to_i,
    threads: status[/^Threads:\s+(\d+)/, 1].to_i }
rescue Errno::ENOENT, Errno::ESRCH
  { pid: pid, missing: true }
end

running = true
previous_signals = {}
lock = Mutex.new
totals = { requests: 0, errors: 0, latency_seconds_sum: 0.0, latency_seconds_max: 0.0, error_examples: [],
           requests_by_worker: {} }
samples = []
threads = []
initial_pids = []
started_at = Time.now.utc.iso8601
started = nil
failure = nil
begin
  %w[TERM INT].each { |signal| previous_signals[signal] = Signal.trap(signal) { running = false } }
  listener = TCPServer.new("127.0.0.1", 0)
  address = "127.0.0.1:#{listener.addr[1]}"
  listener.close
  cluster = Gritz::Testing::Cluster.new(
    config_path: File.expand_path("../spec/integration/cluster/config.rb", __dir__),
    env: { "CLUSTER_BIND" => address, "CLUSTER_WORKERS" => settings.fetch("workers").to_s,
           "GRITZ_WORKER_TIMEOUT" => "30", "GRITZ_STATUS_INTERVAL" => "1" }
  )
  cluster.start
  cluster.wait_until(workers: settings.fetch("workers"), timeout: 30)
  initial_pids = cluster.workers.map { |worker| worker.fetch(:pid) }.sort
  totals[:requests_by_worker] = initial_pids.to_h { |pid| [pid, 0] }
  started_at = Time.now.utc.iso8601
  started = monotonic
  deadline = started + settings.fetch("duration_seconds")
  settings.fetch("clients").times do
    threads << Thread.new do
      # Independent subchannel pools keep C-core from merging every client onto one worker's connection.
      client = Helloworld::Greeter::Stub.new(address, :this_channel_is_insecure,
                                             channel_args: { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 })
      interval = settings.fetch("clients").fdiv(settings.fetch("requests_per_second"))
      next_request = monotonic
      while running && monotonic < deadline
        call_started = monotonic
        error = nil
        worker_pid = nil
        begin
          reply = client.say_hello(Helloworld::HelloRequest.new(name: "pid"), deadline: Time.now + settings.fetch("request_timeout_seconds"))
          worker_pid = Integer(reply.message, 10)
          raise "unexpected worker #{worker_pid}" unless initial_pids.include?(worker_pid)
        rescue StandardError => e
          error = "#{e.class}: #{e.message}"
        end
        latency = monotonic - call_started
        lock.synchronize do
          totals[:requests] += 1
          totals[:latency_seconds_sum] += latency
          totals[:latency_seconds_max] = [totals[:latency_seconds_max], latency].max
          if error
            totals[:errors] += 1
            totals[:error_examples] << error if totals[:error_examples].size < 20
          else
            totals[:requests_by_worker][worker_pid] += 1
          end
        end
        next_request = [next_request + interval, monotonic].max
        sleep [next_request - monotonic, 0].max
      end
    rescue StandardError => e
      lock.synchronize do
        totals[:errors] += 1
        totals[:error_examples] << "#{e.class}: #{e.message}" if totals[:error_examples].size < 20
      end
      running = false
    end
  end
  loop do
    snapshot = cluster.status
    pids = snapshot.fetch(:workers, []).map { |worker| worker.fetch(:pid) }.sort
    if pids != initial_pids || snapshot[:state] != "running"
      failure = "cluster changed during soak: #{snapshot.inspect}"
      running = false
    end
    sample = { elapsed_seconds: monotonic - started, master: memory(cluster.pid), workers: pids.map { |pid| memory(pid) } }
    samples << sample
    progress = lock.synchronize { totals.slice(:requests, :errors).merge(requests_by_worker: totals[:requests_by_worker].dup) }
    puts JSON.generate(sample.slice(:elapsed_seconds).merge(progress, workers: sample[:workers]))
    $stdout.flush
    break if !running || monotonic >= deadline

    sleep [settings.fetch("sample_interval_seconds"), deadline - monotonic].min
  end
rescue StandardError => e
  failure = "#{e.class}: #{e.message}"
ensure
  running = false
  begin
    threads.each(&:join)
  ensure
    elapsed = started ? monotonic - started : 0
    begin
      cluster&.stop(timeout: 35)
    ensure
      previous_signals.each { |signal, handler| Signal.trap(signal, handler) }
      listener&.close unless listener&.closed?
    end
  end
  unloaded = totals[:requests_by_worker].select { |_pid, count| count.zero? }.keys
  failure ||= "Workers received no RPCs: #{unloaded.join(', ')}" unless unloaded.empty?
  result = { started_at: started_at, settings: settings, elapsed_seconds: elapsed, master_pid: cluster&.pid, initial_worker_pids: initial_pids,
             totals: totals, failure: failure, interrupted: elapsed < settings.fetch("duration_seconds"), samples: samples,
             shutdown_success: (cluster&.pid && cluster.wait.success?) || false }
  File.write(options[:output], "#{JSON.pretty_generate(result)}\n")
end
abort "Soak failed; see #{options[:output]}" if failure || result[:interrupted] || totals[:errors].positive? || !result[:shutdown_success]
puts "Soak completed: #{options[:output]}"
