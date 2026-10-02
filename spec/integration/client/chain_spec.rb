# frozen_string_literal: true

require "spec_helper"
require "json"
require "socket"
require "tmpdir"
require "google/protobuf/wrappers_pb"

$LOAD_PATH.unshift(File.expand_path("../../fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Forked native client chain", skip: RUBY_PLATFORM.include?("linux") ? false : "forked client E2E requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-client-chain") do |directory|
      @directory = directory
      @events_path = File.join(directory, "events.jsonl")
      @clusters = {}
      @addresses = {}
      example.run
    ensure
      @clusters.values.reverse_each do |cluster|
        owned = [cluster.pid, cluster.master_pid, *cluster.workers.map { |worker| worker[:pid] }].compact.uniq
        cluster.stop(timeout: 3)
        expect(cluster.wait).to be_success if @chain_ready
        owned.each { |pid| expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH) }
      end
    end
  end

  def free_address
    listener = TCPServer.new("127.0.0.1", 0)
    "127.0.0.1:#{listener.addr[1]}"
  ensure
    listener&.close
  end

  def start_chain(passthrough: false)
    @chain_ready = false
    %w[c b a].each do |role|
      @addresses[role] = free_address
      env = { "CLIENT_E2E_ROLE" => role, "CLIENT_E2E_EVENTS" => @events_path,
              "CLIENT_E2E_BIND" => @addresses.fetch(role), "CLIENT_E2E_ADMIN" => free_address,
              "CLIENT_E2E_WORKERS" => role == "a" ? "2" : "1",
              "CLIENT_E2E_PASSTHROUGH" => passthrough.to_s }
      if role != "c"
        env["CLIENT_E2E_TARGET"] = @addresses.fetch(role == "a" ? "b" : "c")
        env["CLIENT_E2E_DEADLINE"] = role == "a" ? "0.4" : "0.25"
      end
      @clusters[role] = Gritz::Testing::Cluster.new(config_path: File.expand_path("fixtures/config.rb", __dir__), env:)
      @clusters.fetch(role).start.wait_until(workers: Integer(env.fetch("CLIENT_E2E_WORKERS")))
    end
    @chain_ready = true
  end

  def rpc(name = "ok", deadline: Time.now + 2, metadata: {})
    address = @addresses.fetch("a")
    channel = GRPC::Core::Channel.new(address, { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }, :this_channel_is_insecure)
    stub = Helloworld::Greeter::Stub.new(address, :this_channel_is_insecure, channel_override: channel)
    stub.say_hello(Helloworld::HelloRequest.new(name:), deadline:, metadata:)
  ensure
    channel&.close
  end

  def events = File.readlines(@events_path).map { |line| JSON.parse(line) }

  it "shortens default budgets across three servers and propagates only request ID and traceparent" do
    start_chain
    traceparent = "00-11111111111111111111111111111111-2222222222222222-01"
    result = JSON.parse(rpc(metadata: { "x-request-id" => "chain-id", "traceparent" => traceparent,
                                        "authorization" => "fixture-auth-do-not-forward" }).message)
    hops = result.fetch("hops")
    expect(hops.map { |hop| hop.fetch("role") }).to eq(%w[a b c])
    expect(hops.map { |hop| hop.fetch("request_id") }).to eq(["chain-id"] * 3)
    expect(hops.map { |hop| hop.fetch("traceparent") }).to eq([traceparent] * 3)
    expect(hops.drop(1).map { |hop| hop.fetch("authorization") }).to eq([nil, nil])
    hops.each_cons(2) { |upstream, downstream| expect(downstream.fetch("deadline")).to be < upstream.fetch("deadline") }
    expect(hops[1].fetch("deadline") - hops[1].fetch("received_at")).to be <= 0.41
    expect(hops[2].fetch("deadline") - hops[2].fetch("received_at")).to be <= 0.26
  end

  it "bounds both downstream deadlines by a shorter caller budget and a safety margin" do
    start_chain
    deadline = Time.now + 0.2
    hops = JSON.parse(rpc(deadline:).message).fetch("hops")
    expect(hops.first.fetch("deadline")).to be <= deadline.to_f + 0.005
    hops.each_cons(2) do |upstream, downstream|
      expect(downstream.fetch("deadline")).to be <= upstream.fetch("deadline") - 0.015
      expect(downstream.fetch("deadline")).to be > downstream.fetch("received_at")
    end
  end

  it "defines clients safely in parents and lazily creates one channel in each calling worker" do
    start_chain
    expect(events.select { |event| event["event"] == "channel" }).to be_empty
    caller_pids = @clusters.fetch("a").workers.map { |worker| worker.fetch(:pid) }
    seen = []
    @clusters.fetch("a").wait_until(timeout: 5) do
      8.times { seen << JSON.parse(rpc.message).fetch("hops").first.fetch("pid") }
      (caller_pids - seen).empty?
    end
    requests = events.select { |event| event["event"] == "request" }
    expect(requests.map { |event| event["role"] }.uniq.sort).to eq(%w[a b c])
    channels = events.select { |event| event["event"] == "channel" }
    all_workers = @clusters.values.flat_map { |cluster| cluster.workers.map { |worker| worker.fetch(:pid) } }
    definitions = events.select { |event| event["event"] == "defined" }
    expect(definitions.map { |event| event["pid"] } & all_workers).to be_empty
    %w[a b].each do |role|
      expect(definitions).to include(include("role" => role, "pid" => @clusters.fetch(role).master_pid))
      actual = channels.select { |event| event["role"] == role }
      expected = @clusters.fetch(role).workers.map { |worker| worker.fetch(:pid) }.sort
      expect(actual.map { |event| event["pid"] }.sort).to eq(expected)
      actual.each do |event|
        expect(event["target"]).to eq(@addresses.fetch(role == "a" ? "b" : "c"))
        expect(JSON.parse(event.fetch("service_config"))).to eq("loadBalancingConfig" => [{ "pick_first" => {} }])
      end
    end
    expect(channels.map { |event| event["pid"] } - all_workers).to be_empty
  end

  it "turns an unhandled rich downstream error into a safe INTERNAL response" do
    start_chain
    expect { rpc("error:unhandled") }.to raise_error(GRPC::Internal) do |error|
      expect(error.details).to match(/internal error \([0-9a-f-]{36}\)/)
      expect(error.details).not_to include("downstream confidential")
      expect(error.metadata).to have_key("error-id")
      expect(error.metadata).not_to have_key("downstream-marker")
      expect(error.metadata).not_to have_key("grpc-status-details-bin")
    end
    expect(events.select { |event| event["event"] == "request" }.map { |event| event["role"] }.uniq.sort).to eq(%w[a b c])
  end

  it "allows a typed downstream rescue to inspect decoded rich details and metadata" do
    start_chain
    result = JSON.parse(rpc("error:handled").message)
    expect(result.fetch("handled")).to include("class" => "Gritz::Errors::NotFound", "code" => 5, "remote" => true,
                                               "message" => "downstream confidential message", "details" => ["origin-c detail"],
                                               "marker" => "origin-c")
    expect(result.fetch("hops").map { |hop| hop["role"] }).to eq(%w[a b])
    expect(events.select { |event| event["event"] == "request" }.map { |event| event["role"] }.uniq.sort).to eq(%w[a b c])
  end

  it "preserves original downstream code, details and trailers when passthrough is explicitly enabled" do
    start_chain(passthrough: true)
    expect { rpc("error:passthrough") }.to raise_error(GRPC::NotFound) do |error|
      expect(error.details).to eq("downstream confidential message")
      expect(error.metadata["downstream-marker"]).to eq("origin-c")
      status = Google::Rpc::Status.decode(error.metadata.fetch("grpc-status-details-bin"))
      expect(status.code).to eq(5)
      expect(status.message).to eq("downstream confidential message")
      expect(status.details.first.unpack(Google::Protobuf::StringValue).value).to eq("origin-c detail")
    end
    expect(events.select { |event| event["event"] == "request" }.map { |event| event["role"] }.uniq.sort).to eq(%w[a b c])
  end
end
