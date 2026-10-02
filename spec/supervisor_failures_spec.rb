# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

RSpec.describe "Linux supervisor failure exits", skip: RUBY_PLATFORM.include?("linux") ? false : "multiprocess reuseport requires Linux" do
  around do |example|
    Dir.mktmpdir("gritz-supervisor-failures") do |dir|
      @events_path = File.join(dir, "events.jsonl")
      @marker_path = File.join(dir, "first-worker")
      example.run
    ensure
      @cluster&.stop(timeout: 2)
    end
  end

  def start_cluster(mode, **env)
    listener = TCPServer.new("127.0.0.1", 0)
    address = "127.0.0.1:#{listener.addr[1]}"
    listener.close
    @cluster = Gritz::Testing::Cluster.new(
      config_path: File.expand_path("fixtures/supervisor_failures/config.rb", __dir__),
      env: { "FAILURE_BIND" => address, "FAILURE_EVENTS" => @events_path, "FAILURE_MARKER" => @marker_path, "FAILURE_MODE" => mode }
        .merge(env.transform_keys(&:to_s))
    ).start
  end

  def events = File.exist?(@events_path) ? File.readlines(@events_path).map { |line| JSON.parse(line, symbolize_names: true) } : []

  def expect_reaped(pid)
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
  end

  %w[hard_exit hard_exit_success].each do |mode|
    it "fails startup without a respawn loop when the boot hook calls #{mode}" do
      start_cluster(mode)
      expect(@cluster.wait(timeout: 2).exitstatus).to eq(1)
      boots = events.select { |event| event[:event] == "boot" }
      expect(boots.size).to eq(1)
      expect_reaped(boots.first.fetch(:pid))
    end
  end

  it "fails graceful shutdown when the ready worker's cleanup hook fails" do
    start_cluster("shutdown_error").wait_until(workers: 1)
    worker = @cluster.workers.first.fetch(:pid)
    @cluster.signal("TERM")
    expect(@cluster.wait(timeout: 2).exitstatus).to eq(1)
    expect(events.count { |event| event[:event] == "shutdown" }).to eq(1)
    expect(@cluster.logs).to include("requested shutdown hook failure")
    expect_reaped(worker)
  end

  it "allows failed worker startup cleanup to finish before its shutdown deadline" do
    start_cluster("boot_cleanup")
    expect(@cluster.wait(timeout: 2).exitstatus).to eq(1)
    expect(events.count { |event| event[:event] == "boot" }).to eq(1)
    expect(events.count { |event| event[:event] == "shutdown" }).to eq(1)
    expect(events.count { |event| event[:event] == "shutdown_done" }).to eq(1)
    expect_reaped(events.first.fetch(:pid))
  end

  it "replaces a timed-out booting worker without treating the intentional kill as startup failure" do
    start_cluster("hang_once", GRITZ_WORKER_BOOT_TIMEOUT: "0.2").wait_until(workers: 1)
    booted = events.select { |event| event[:event] == "boot" }.map { |event| event.fetch(:pid) }
    expect(booted.size).to eq(2)
    expect_reaped(booted.first)
    @cluster.signal("TERM")
    expect(@cluster.wait(timeout: 2)).to be_success
    expect_reaped(booted.last)
  end

  it "replaces an externally SIGKILLed booting worker before readiness" do
    start_cluster("hang_once").wait_until(state: nil, workers: 1) { File.exist?(@marker_path) }
    first = Integer(File.read(@marker_path))
    @cluster.signal("KILL", pid: first).wait_until(workers: 1)
    expect(@cluster.workers.first.fetch(:pid)).not_to eq(first)
    expect_reaped(first)
    @cluster.signal("TERM")
    expect(@cluster.wait(timeout: 2)).to be_success
  end

  it "keeps successful master shutdown when the deadline requires SIGKILL" do
    start_cluster("healthy").wait_until(workers: 1)
    worker = @cluster.workers.first.fetch(:pid)
    @cluster.signal("STOP", pid: worker).signal("TERM")
    expect(@cluster.wait(timeout: 2)).to be_success
    expect(events.none? { |event| event[:event] == "shutdown" }).to be(true)
    expect_reaped(worker)
  end
end
