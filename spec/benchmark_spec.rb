# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

RSpec.describe "performance regression gate" do
  it "rejects ten percent degradation, invalid results and incomparable runs" do
    Dir.mktmpdir do |directory|
      baseline = { "scenario" => "unary-light", "transport" => "native", "settings" => { "workers" => 1 },
                   "environment" => { "runner" => "fixed", "ruby" => RUBY_DESCRIPTION }, "passed" => true,
                   "gems" => { "gritz-core" => "0.6.1", "grpc" => "1.83.0" },
                   "median" => { "rps" => 100.0, "p50_ns" => 100.0, "p95_ns" => 200.0 } }
      before = File.join(directory, "before.json")
      after = File.join(directory, "after.json")
      File.write(before, JSON.generate(baseline))
      check = lambda do |changes|
        File.write(after, JSON.generate(baseline.merge(changes)))
        Open3.capture3(RbConfig.ruby, File.expand_path("../bench/compare.rb", __dir__), before, after)
      end
      expect(check.call({}).last).to be_success
      expect(check.call("median" => { "rps" => 90.0, "p50_ns" => 100.0, "p95_ns" => 200.0 }).last).not_to be_success
      expect(check.call("median" => { "rps" => 100.0, "p50_ns" => 110.0, "p95_ns" => 200.0 }).last).not_to be_success
      expect(check.call("median" => { "rps" => 100.0, "p50_ns" => 100.0, "p95_ns" => 220.0 }).last).not_to be_success
      baseline["median"].transform_values!(&:to_i)
      File.write(before, JSON.generate(baseline))
      expect(check.call("median" => { "rps" => 100, "p50_ns" => 110, "p95_ns" => 200 }).last).not_to be_success
      expect(check.call("median" => { "rps" => 100, "p50_ns" => 100, "p95_ns" => 220 }).last).not_to be_success
      expect(check.call("passed" => false).last).not_to be_success
      expect(check.call("environment" => { "runner" => "different" }).last).not_to be_success
      expect(check.call("gems" => { "gritz-core" => "0.6.2", "grpc" => "1.83.0" }).last).to be_success
      expect(check.call("gems" => { "gritz-core" => "0.6.1", "grpc" => "1.84.0" }).last).not_to be_success
      expect(check.call("median" => { "rps" => 0 }).last).not_to be_success
    end
  end

  it "retains failed RPC counts and reaps benchmark workers", :linux do
    skip "multiprocess benchmarks require Linux" unless RUBY_PLATFORM.include?("linux")
    Dir.mktmpdir do |directory|
      ghz = File.join(directory, "ghz")
      File.write(ghz, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        if ARGV.include?("--version")
          puts "v0.121.0"
          exit
        end
        output = ARGV.find { |arg| arg.start_with?("--output=") }.delete_prefix("--output=")
        File.write(output, JSON.generate(count: 2, statusCodeDistribution: { "OK" => 1, "DeadlineExceeded" => 1 },
                                        errorDistribution: { "context deadline exceeded" => 1 }))
      RUBY
      File.chmod(0o755, ghz)
      output = File.join(directory, "benchmark.json")
      args = [RbConfig.ruby, File.expand_path("../bin/bench", __dir__), "unary-light", "--smoke", "--ghz", ghz, "--output", output]
      _stdout, _stderr, status = Open3.capture3(*args)
      expect(status).not_to be_success
      report = JSON.parse(File.read(output))
      expect(report.fetch("passed")).to be(false)
      expect(report.fetch("error")).to include("RPC errors")
      expect(report.fetch("warmup").fetch("statusCodeDistribution")).to include("DeadlineExceeded" => 1)
      report.fetch("worker_pids").each do |pid|
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      end
    end
  end

  it "retains chaos failure evidence and reaps the cluster when tc is unavailable", :linux do
    skip "multiprocess chaos requires Linux" unless RUBY_PLATFORM.include?("linux")
    Dir.mktmpdir do |directory|
      tc = File.join(directory, "tc")
      File.write(tc, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, tc)
      output = File.join(directory, "chaos.json")
      _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, File.expand_path("../bench/chaos.rb", __dir__), "--tc", tc, "--output", output)
      expect(status).not_to be_success
      expect(File).to exist(output)
      report = JSON.parse(File.read(output))
      expect(report.fetch("passed")).to be(false)
      expect(report.fetch("error")).to include("tc failed")
      [report.fetch("master_pid"), *report.fetch("initial_worker_pids")].each do |pid|
        expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
      end
    end
  end
end
