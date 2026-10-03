# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

RSpec.describe "performance regression gate" do
  it "rejects ten percent degradation, invalid results and incomparable runs" do
    Dir.mktmpdir do |directory|
      baseline = { "scenario" => "unary-light", "transport" => "native", "settings" => { "workers" => 1 },
                   "environment" => { "runner" => "fixed", "ruby" => RUBY_DESCRIPTION }, "passed" => true,
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
      expect(check.call("passed" => false).last).not_to be_success
      expect(check.call("environment" => { "runner" => "different" }).last).not_to be_success
      expect(check.call("median" => { "rps" => 0 }).last).not_to be_success
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
