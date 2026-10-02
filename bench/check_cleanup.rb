# frozen_string_literal: true

require "gritz/native"
require "open3"
require "tmpdir"
require "rbconfig"
require "json"

abort "This cleanup check requires Linux" unless RUBY_PLATFORM.include?("linux")

driver = File.expand_path("soak.rb", __dir__)
fixture_path = File.expand_path("../spec/fixtures/hello", __dir__)
Dir.mktmpdir("gritz-soak-cleanup") do |dir|
  %w[startup timeout client].each do |scenario|
    report = File.join(dir, "#{scenario}.json")
    events = File.join(dir, "#{scenario}-events.jsonl")
    source = <<~RUBY
      require "gritz/native"
      if ARGV.shift == "timeout"
        module ShortStartupWait
          def wait_until(**options)
            path = ENV.fetch("CLUSTER_EVENTS")
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
            until File.file?(path) && File.open(path) { |file|
              file.flock(File::LOCK_SH)
              file.any? { |line| JSON.parse(line).fetch("event") == "boot" }
            }
              raise "timed out waiting for a worker boot event" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              sleep 0.01
            end
            super(**options.merge(timeout: 0.1))
          end
        end
        Gritz::Testing::Cluster.prepend(ShortStartupWait)
      end
      $LOAD_PATH.unshift(ARGV.shift)
      require "hello_services_pb"
      if ENV["CHECK_CLIENT_FAILURE"] == "1"
        Helloworld::Greeter::Stub.define_singleton_method(:new) { |*| raise "requested client setup failure" }
      end
      load ARGV.shift
    RUBY
    env = { "CLUSTER_EVENTS" => events, "CLUSTER_BOOT_MODE" => { "startup" => "fail", "timeout" => "hang" }[scenario],
            "CHECK_CLIENT_FAILURE" => scenario == "client" ? "1" : nil }
    output, status = Open3.capture2e(env, RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-e", source,
                                     scenario, fixture_path, driver, "--duration", "1", "--output", report)
    raise "#{scenario} unexpectedly succeeded: #{output}" if status.success?
    raise "#{scenario} did not write a result: #{output}" unless File.file?(report)

    result = JSON.parse(File.read(report))
    expected = { "startup" => "requested boot failure", "timeout" => "Timeout::Error", "client" => "requested client setup failure" }.fetch(scenario)
    raise "#{scenario} did not report the injected failure: #{result.inspect}" unless JSON.generate(result).include?(expected)

    boot_pids = File.readlines(events).map { |line| JSON.parse(line) }.select { |event| event["event"] == "boot" }.map { |event| event.fetch("pid") }
    pids = ([result.fetch("master_pid")] + boot_pids).uniq
    pids.each do |pid|
      Process.kill(0, pid)
      raise "#{scenario} leaked process #{pid}"
    rescue Errno::ESRCH
      # The failed driver must reap its master and every booted worker.
    end
    puts "#{scenario}: failed as expected; reaped #{pids.join(', ')}"
  end
end
