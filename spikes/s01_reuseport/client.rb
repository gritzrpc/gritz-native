# frozen_string_literal: true

require "grpc"
require "json"
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require_relative "lib/echo_services_pb"

address = ENV.fetch("ADDRESS", "127.0.0.1:50051")
connections = Integer(ENV.fetch("CONNECTIONS", "64"))
duration = Float(ENV.fetch("DURATION", "5"))
cpu_ms = Integer(ENV.fetch("CPU_MS", "0"))
raise "CONNECTIONS and DURATION must be positive" unless connections.positive? && duration.positive?

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
finished = started + duration
threads = Array.new(connections) do
  Thread.new do
    stub = Echo::EchoService::Stub.new(
      address, :this_channel_is_insecure,
      channel_args: { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }
    )
    tally = Hash.new(0)
    first_seen = {}
    errors = Hash.new(0)
    latencies = []
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < finished
      begin
        before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reply = if cpu_ms.positive?
                  stub.burn(Echo::BurnRequest.new(ms: cpu_ms), deadline: Time.now + 3)
                else
                  stub.echo(Echo::EchoRequest.new(message: "probe"), deadline: Time.now + 3)
                end
        tally[reply.pid] += 1
        first_seen[reply.pid] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        latencies << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - before) * 1000)
      rescue GRPC::BadStatus => e
        errors[e.class.name] += 1
      end
    end
    { tally: tally, errors: errors, latencies: latencies, first_seen: first_seen }
  end
end
samples = threads.map(&:value)
tally = samples.flat_map { |sample| sample[:tally].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) }
errors = samples.flat_map { |sample| sample[:errors].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) }
latencies = samples.flat_map { |sample| sample[:latencies] }.sort
first_seen = samples.flat_map { |sample| sample[:first_seen].to_a }.group_by(&:first).transform_values { |pairs| pairs.map(&:last).min }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts JSON.generate(
  grpc: GRPC::VERSION, ruby: RUBY_DESCRIPTION, connections: connections, duration: elapsed,
  cpu_ms: cpu_ms, requests: tally.values.sum, rps: tally.values.sum / elapsed,
  errors: errors, distribution: tally,
  first_seen_seconds: first_seen,
  p50_ms: latencies[latencies.length / 2], p99_ms: latencies[(latencies.length * 0.99).floor]
)
