#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# Exercise the real driver without creating a cluster: the external Job fails
# after rollout, and its raw output must survive diagnostics and owned cleanup.
Dir.mktmpdir("gritz-kind-failure") do |directory|
  kind = File.join(directory, "kind")
  kubectl = File.join(directory, "kubectl")
  ghz = File.join(directory, "ghz")
  File.write(kind, <<~RUBY)
    #!#{RbConfig.ruby}
    if ARGV.first == "create"
      File.write(ARGV.fetch(ARGV.index("--kubeconfig") + 1), "injected config")
    end
  RUBY
  raw = JSON.generate(count: 100, statusCodeDistribution: { "OK" => 99, "Canceled" => 1 },
                      errorDistribution: { "injected cancellation" => 1 })
  File.write(kubectl, <<~RUBY)
    #!#{RbConfig.ruby}
    require "json"
    args = ARGV.reject { |argument| argument.start_with?("--kubeconfig=", "--request-timeout=") }
    case args.first(2)
    when ["get", "pods"]
      puts JSON.generate(items: [{ metadata: { name: "old-a" } }, { metadata: { name: "old-b" } }])
    when ["get", "endpointslices"]
      puts JSON.generate(items: [{ endpoints: [{ conditions: { ready: true } }] }])
    when ["get", "deployment"]
      puts JSON.generate(metadata: { generation: 1 }, status: {
        observedGeneration: 1, updatedReplicas: 2, readyReplicas: 2, replicas: 2
      })
    else
      case args.first
      when "exec" then puts JSON.generate(workers: [{ requests_total: 1 }, { requests_total: 1 }])
      when "wait" then abort "injected load Job failure" if ENV.fetch("GRITZ_TEST_KIND_FAILURE") == "job_failure"
      when "logs"
        counter = ENV.fetch("GRITZ_TEST_KIND_LOG_COUNT_PATH")
        abort "injected log retrieval failure" if File.exist?(counter)
        File.write(counter, "1")
        puts #{raw.dump}
      when "describe" then puts "injected Pod diagnostics"
      end
    end
  RUBY
  File.write(ghz, "#!#{RbConfig.ruby}\n")
  [kind, kubectl, ghz].each { |path| FileUtils.chmod(0o755, path) }
  { "job_failure" => "injected load Job failure", "reported_error" => "ghz reported errors" }.each do |scenario, expected_error|
    output = File.join(directory, "#{scenario}.json")
    env = { "GRITZ_TEST_KIND_FAILURE" => scenario,
            "GRITZ_TEST_KIND_LOG_COUNT_PATH" => File.join(directory, "#{scenario}-log-requests") }
    _stdout, stderr, status = Open3.capture3(
      env, RbConfig.ruby, File.expand_path("kind_rollout.rb", __dir__), "--skip-build", "--kind", kind,
      "--kubectl", kubectl, "--ghz", ghz, "--duration", "60", "--output", output
    )
    raise "driver unexpectedly passed" if status.success?

    report = JSON.parse(File.read(output))
    raise "failure was not injected: #{stderr}" unless report.fetch("error").include?(expected_error)
    raise "driver did not retain its failed state" if report.fetch("passed")
    raise "driver did not delete its owned cluster" unless report.fetch("cluster_deleted")

    raw_path = output.sub(/\.json\z/, "-ghz.json")
    raise "failed Job raw logs were not retained" unless File.file?(raw_path)
    raise "failed Job raw result was overwritten" unless File.read(raw_path).strip == raw

    puts "#{scenario}: raw logs retained, gate failed, and owned cluster cleaned up"
  end
end
