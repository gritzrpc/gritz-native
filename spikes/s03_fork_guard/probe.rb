# frozen_string_literal: true

# rubocop:disable Style/OneClassPerFile -- Keep the throwaway probe self-contained.

require "grpc"
require "openssl"
require "json"

class MasterConstructorError < StandardError; end

module InitializerProbe
  MASTER_PID = Process.pid
  def initialize(*args, **kwargs, &)
    if Process.pid == MASTER_PID
      raise MasterConstructorError, "#{self.class}: #{caller_locations(1, 3).join(', ')}"
    end

    super
  end
end

module ConstructorProbe
  MASTER_PID = Process.pid
  def new(*args, **kwargs, &)
    if Process.pid == MASTER_PID
      raise MasterConstructorError, "#{self}: #{caller_locations(1, 3).join(', ')}"
    end

    super
  end
end

classes = [GRPC::Core::Channel, GRPC::Core::Server, GRPC::Core::ChannelCredentials,
           GRPC::Core::ServerCredentials, GRPC::Core::CallCredentials, GRPC::ClientStub, GRPC::RpcServer]
hook = ENV.fetch("HOOK", "new")
raise "HOOK must be new or initialize" unless %w[new initialize].include?(hook)

classes.each do |klass|
  hook == "new" ? klass.singleton_class.prepend(ConstructorProbe) : klass.prepend(InitializerProbe)
end

key = OpenSSL::PKey::RSA.new(2048)
cert = OpenSSL::X509::Certificate.new
cert.version = 2
cert.serial = 1
cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=localhost")
cert.public_key = key.public_key
cert.not_before = Time.now
cert.not_after = Time.now + 3600
cert.sign(key, OpenSSL::Digest.new("SHA256"))
constructors = {
  GRPC::Core::Channel => -> { GRPC::Core::Channel.new("localhost:50051", {}, :this_channel_is_insecure) },
  GRPC::Core::Server => -> { GRPC::Core::Server.new({}) },
  GRPC::Core::ChannelCredentials => -> { GRPC::Core::ChannelCredentials.new },
  GRPC::Core::ServerCredentials => lambda {
    GRPC::Core::ServerCredentials.new(nil, [{ private_key: key.to_pem, cert_chain: cert.to_pem }], false)
  },
  GRPC::Core::CallCredentials => -> { GRPC::Core::CallCredentials.new(proc { {} }) },
  GRPC::ClientStub => -> { GRPC::ClientStub.new("localhost:50051", :this_channel_is_insecure) },
  GRPC::RpcServer => -> { GRPC::RpcServer.new(pool_size: 2) }
}

results = constructors.map do |klass, construct|
  location = begin
    construct.call
    raise "Master constructor was not blocked: #{klass}"
  rescue MasterConstructorError => e
    raise "Caller location missing" unless e.message.include?("probe.rb:")

    e.message
  end
  pid = fork do
    construct.call
    exit! 0
  rescue StandardError => e
    warn e.full_message
    exit! 1
  end
  _, status = Process.waitpid2(pid)
  raise "Child constructor failed: #{klass}" if hook == "new" && !status.success?

  { class: klass.name, master_blocked: true, child_forwarded: status.success?, location: location }
end
puts JSON.pretty_generate(grpc: GRPC::VERSION, ruby: RUBY_DESCRIPTION, hook: hook, constructors: results)
# rubocop:enable Style/OneClassPerFile
