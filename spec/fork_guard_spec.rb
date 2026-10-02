# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Native fork guard" do
  after { Gritz::ForkGuard.deactivate }

  it "guards Ruby and C-defined constructors before native allocation" do
    guard = Gritz::ForkGuard.activate
    [GRPC::Core::Channel, GRPC::Core::Server, GRPC::Core::ChannelCredentials,
     GRPC::Core::ServerCredentials, GRPC::Core::CallCredentials, GRPC::ClientStub, GRPC::RpcServer].each do |klass|
      expect { klass.new }.to raise_error(Gritz::ForkGuard::Violation, /#{Regexp.escape(klass.name)}.new/)
    end
    expect(guard.violations.size).to eq(7)
  end

  it "loads native safely in a clean master and allows a channel in its forked worker" do
    source = <<~RUBY
      require "gritz/core"
      guard = Gritz::ForkGuard.activate
      require "gritz/native"
      abort "requiring native created a grpc object" unless guard.violations.empty?
      pid = fork do
        channel = GRPC::Core::Channel.new("localhost:50051", {}, :this_channel_is_insecure)
        channel.close
        exit! 0
      rescue StandardError => e
        warn e.full_message
        exit! 1
      end
      _, status = Process.waitpid2(pid)
      exit(status.success? ? 0 : 1)
    RUBY
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", source)
    expect(status.success?).to be(true), stderr
  end

  it "delegates experimental fork preparation and the parent and child callbacks" do
    expect(GRPC).to receive(:prefork).and_return(:prepared)
    expect(GRPC).to receive(:postfork_parent).and_return(:parent)
    expect(GRPC).to receive(:postfork_child).and_return(:child)
    expect(Gritz::Transport::Native.prefork).to eq(:prepared)
    expect(Gritz::Transport::Native.postfork_parent).to eq(:parent)
    expect(Gritz::Transport::Native.postfork_child).to eq(:child)
  end

  it "explains the required pre-require flag while retaining the grpc fork failure" do
    failure = RuntimeError.new("cannot fork while a bidi call is active")
    expect(GRPC).to receive(:prefork).and_raise(failure)
    expect { Gritz::Transport::Native.prefork }.to raise_error(RuntimeError, /bidi.*GRPC_ENABLE_FORK_SUPPORT=1.*before requiring grpc/m) do |error|
      expect(error.cause).to equal(failure)
    end
  end
end
