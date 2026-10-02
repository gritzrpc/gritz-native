#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "securerandom"
require "time"
require "tmpdir"

options = { kind: "kind", kubectl: "kubectl", core: "../gritz-core", image: "gritz-phase3-e2e:local",
            duration: 90, output: "tmp/kind-rollout.json" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby bench/kind_rollout.rb --ghz /path/to/linux/ghz [options]"
  parser.on("--skip-build", "Use the already built local --image") { options[:skip_build] = true }
  parser.on("--node-image IMAGE", "Use a verified cached kind node image") { |value| options[:node_image] = value }
  %i[kind kubectl core image ghz output].each { |key| parser.on("--#{key} VALUE") { |value| options[key] = value } }
  parser.on("--duration SECONDS", Integer) { |value| options[:duration] = value }
end.parse!
abort "--ghz must be an executable built for the Docker host's Linux architecture" unless options[:ghz] && File.executable?(options[:ghz])
abort "duration must be at least 60 seconds" unless options[:duration] >= 60

def command(*args)
  output, error, status = Open3.capture3(*args)
  raise "#{args.first} failed: #{error}\n#{output}" unless status.success?

  output
end

def poll(timeout:)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = yield
    return value if value
    raise "poll deadline exceeded after #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.25
  end
end

root = File.expand_path("..", __dir__)
report_path = File.expand_path(options[:output])
FileUtils.mkdir_p(File.dirname(report_path))
cluster_name = "gritz-phase3-#{SecureRandom.hex(4)}"
report = { started_at: Time.now.utc.iso8601, cluster: cluster_name, image: options[:image], passed: false,
           driver_ruby: RUBY_DESCRIPTION, node_image: options[:node_image] }

Dir.mktmpdir("gritz-kind") do |directory|
  kubeconfig = File.join(directory, "kubeconfig")
  kubectl = lambda do |*args|
    command(options[:kubectl], "--kubeconfig=#{kubeconfig}", "--request-timeout=10s", *args)
  end
  begin
    tools_context = File.join(directory, "tools")
    FileUtils.mkdir_p(tools_context)
    FileUtils.cp(options[:ghz], File.join(tools_context, "ghz"))
    puts "Building #{options[:image]} from local core/native sources"
    unless options[:skip_build]
      command("docker", "build", "--build-context", "core=#{File.expand_path(options[:core])}",
              "--build-context", "tools=#{tools_context}", "-f", File.join(root, "examples/kubernetes/Dockerfile"),
              "-t", options[:image], root)
    end
    puts "Creating isolated kind cluster #{cluster_name}"
    cluster_created = true # A failed create can still leave owned node containers behind.
    node_args = options[:node_image] ? ["--image", options[:node_image]] : []
    command(options[:kind], "create", "cluster", "--name", cluster_name, "--kubeconfig", kubeconfig, *node_args,
            "--config", File.join(root, "examples/kubernetes/kind.yml"), "--wait", "120s")
    command(options[:kind], "load", "docker-image", options[:image], "--name", cluster_name)
    manifest = File.read(File.join(root, "examples/kubernetes/deployment.yml")).sub("gritz-phase3-e2e:local", options[:image])
    path = File.join(directory, "deployment.yml")
    File.write(path, manifest)
    kubectl.call("apply", "-f", path)
    kubectl.call("rollout", "status", "deployment/gritz", "--timeout=120s")
    old_pods = JSON.parse(kubectl.call("get", "pods", "-l", "app=gritz", "-o", "json")).fetch("items")
                   .map { |pod| pod.fetch("metadata").fetch("name") }
    report[:old_pods] = old_pods

    job = {
      apiVersion: "batch/v1", kind: "Job", metadata: { name: "gritz-load" },
      spec: { backoffLimit: 0, activeDeadlineSeconds: options[:duration] + 30,
              template: { spec: { restartPolicy: "Never", containers: [{
                name: "ghz", image: options[:image], imagePullPolicy: "Never", command: ["/usr/local/bin/ghz"],
                args: ["--insecure", "--proto=/app/gritz-native/spec/fixtures/hello/hello.proto",
                       "--call=helloworld.Greeter/SayHello", '--data={"name":"Ruby"}', "--connections=32", "--concurrency=32",
                       "--rps=100", "--duration=#{options[:duration]}s", "--duration-stop=wait", "--timeout=2s",
                       "--format=json", "gritz:50051"],
                resources: { requests: { cpu: "50m", memory: "64Mi" }, limits: { cpu: "250m", memory: "128Mi" } }
              }] } } }
    }
    job_path = File.join(directory, "load.json")
    File.write(job_path, JSON.generate(job))
    load_created = true # Keep logs even if the create response is lost after the Job starts.
    kubectl.call("apply", "-f", job_path)
    # Observe real RPCs on every original worker before triggering the rollout.
    report[:loaded_workers] = poll(timeout: 20) do
      snapshots = old_pods.map do |pod|
        source = 'require "net/http"; print Net::HTTP.get(URI("http://127.0.0.1:9090/status"))'
        JSON.parse(kubectl.call("exec", pod, "--", "ruby", "-e", source))
      end
      workers = snapshots.flat_map { |snapshot| snapshot.fetch("workers") }
      workers if workers.size == 4 && workers.all? { |worker| worker.fetch("requests_total", 0).positive? }
    end
    puts "Rolling two replicas under ghz load (four workers verified)"
    kubectl.call("set", "env", "deployment/gritz", "REVISION=b")
    samples = []
    poll(timeout: 120) do
      endpoints = JSON.parse(kubectl.call("get", "endpointslices", "-l", "kubernetes.io/service-name=gritz", "-o", "json"))
                      .fetch("items").flat_map { |slice| slice.fetch("endpoints") }
      ready = endpoints.count { |endpoint| endpoint.fetch("conditions")["ready"] }
      samples << { at: Time.now.utc.iso8601, ready_endpoints: ready }
      raise "rollout lost all ready endpoints" if ready.zero?

      deployment = JSON.parse(kubectl.call("get", "deployment", "gritz", "-o", "json"))
      status = deployment.fetch("status")
      status.fetch("observedGeneration", 0) >= deployment.fetch("metadata").fetch("generation") &&
        status.fetch("updatedReplicas", 0) == 2 && status.fetch("readyReplicas", 0) == 2 && status.fetch("replicas", 0) == 2
    end
    report[:endpoint_samples] = samples
    kubectl.call("rollout", "status", "deployment/gritz", "--timeout=10s")
    kubectl.call("wait", "--for=condition=complete", "job/gritz-load", "--timeout=#{options[:duration] + 30}s")
    raw = kubectl.call("logs", "job/gritz-load")
    File.write("#{report_path.sub(/\.json\z/, '')}-ghz.json", raw)
    result = JSON.parse(raw)
    report[:ghz] = result.slice("count", "total", "average", "statusCodeDistribution", "errorDistribution")
    raise "ghz completed no RPCs" unless result.fetch("count").positive?
    raise "ghz reported errors: #{result['errorDistribution']}" unless result.fetch("errorDistribution").empty?
    raise "ghz reported non-OK responses" unless result.fetch("statusCodeDistribution").keys == ["OK"]

    pods = JSON.parse(kubectl.call("get", "pods", "-l", "app=gritz", "-o", "json")).fetch("items")
    report[:new_pods] = pods.map { |pod| pod.fetch("metadata").fetch("name") }
    raise "old pods survived the rollout" if old_pods.intersect?(report[:new_pods])

    report[:passed] = true
  rescue StandardError => e
    report[:error] = "#{e.class}: #{e.message}"
    warn report[:error]
    if File.exist?(kubeconfig)
      if load_created && !File.exist?("#{report_path.sub(/\.json\z/, '')}-ghz.json")
        raw, error, = Open3.capture3(options[:kubectl], "--kubeconfig=#{kubeconfig}", "--request-timeout=5s", "logs", "job/gritz-load")
        File.write("#{report_path.sub(/\.json\z/, '')}-ghz.json", raw)
        File.write("#{report_path.sub(/\.json\z/, '')}-ghz.log", error) unless error.empty?
      end
      diagnostics, = Open3.capture2e(options[:kubectl], "--kubeconfig=#{kubeconfig}", "--request-timeout=5s", "describe", "pods")
      File.write("#{report_path.sub(/\.json\z/, '')}-pods.txt", diagnostics)
    end
  ensure
    if cluster_created
      _output, error, status = Open3.capture3(options[:kind], "delete", "cluster", "--name", cluster_name, "--kubeconfig", kubeconfig)
      report[:cluster_deleted] = status.success?
      report[:cleanup_error] = error unless status.success?
      report[:passed] = false unless status.success?
    end
    report[:finished_at] = Time.now.utc.iso8601
    File.write(report_path, "#{JSON.pretty_generate(report)}\n")
  end
end

puts JSON.generate(report)
exit(report[:passed] ? 0 : 1)
