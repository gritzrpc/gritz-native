# frozen_string_literal: true

require "spec_helper"
require "grpc/health/v1/health_services_pb"
require "openssl"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("fixtures/hello", __dir__))
require "hello_services_pb"

RSpec.describe "Native health and transport security" do
  let(:logger) { Logger.new(File::NULL) }
  let(:controller) do
    Class.new(Gritz::Controller) do
      bind Helloworld::Greeter::Service
      def say_hello = Helloworld::HelloReply.new(message: context.peer_identity || "anonymous")
    end
  end
  let(:config) do
    Gritz::Configuration.new.tap do |settings|
      settings.bind = "127.0.0.1:0"
      settings.controllers = [controller]
      settings.status_interval = 0.02
    end
  end

  def with_adapter
    router = Gritz::Router.new(controllers: config.controllers)
    dispatcher = Gritz::Dispatcher.new(router:, middleware: config.middleware, logger:)
    adapter = Gritz::Transport::Native.new(config: config.validate!, dispatcher:, logger:)
    port = adapter.bind
    adapter.start
    yield adapter, "127.0.0.1:#{port}"
  ensure
    adapter&.stop(deadline: Time.now + 0.5)
  end

  def health_request(service = "") = Grpc::Health::V1::HealthCheckRequest.new(service:)

  def certificate(name, ca: nil, usage: nil) # rubocop:disable Naming/MethodParameterName -- conventional certificate authority abbreviation
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = Random.rand(1...(2**63))
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
    cert.issuer = ca ? ca.first.subject : cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = ca ? ca.first : cert
    cert.add_extension(factory.create_extension("basicConstraints", ca ? "CA:FALSE" : "CA:TRUE", true))
    cert.add_extension(factory.create_extension("keyUsage", ca ? "digitalSignature,keyEncipherment" : "keyCertSign,cRLSign", true))
    if usage
      cert.add_extension(factory.create_extension("extendedKeyUsage", usage))
      cert.add_extension(factory.create_extension("subjectAltName", usage == "serverAuth" ? "DNS:localhost,IP:127.0.0.1" : "DNS:client.example"))
    end
    cert.sign(ca ? ca.last : key, OpenSSL::Digest.new("SHA256"))
    [cert, key]
  end

  def with_certificates(mtls: false)
    Dir.mktmpdir("gritz-tls") do |dir|
      ca = certificate("test CA")
      server = certificate("localhost", ca:, usage: "serverAuth")
      config.tls = { cert: File.join(dir, "server.pem"), key: File.join(dir, "server.key") }
      File.write(config.tls[:cert], server.first.to_pem)
      File.write(config.tls[:key], server.last.to_pem)
      if mtls
        config.tls[:client_ca] = File.join(dir, "ca.pem")
        File.write(config.tls[:client_ca], ca.first.to_pem)
      end
      yield ca
    end
  end

  it "serves global and registered health checks and rejects unknown services" do
    with_adapter do |_adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      ["", "helloworld.Greeter"].each do |service|
        expect(stub.check(health_request(service), deadline: Time.now + 2).status).to eq(:SERVING)
      end
      expect { stub.check(health_request("unknown"), deadline: Time.now + 2) }.to raise_error(GRPC::NotFound)
    end
  end

  it "streams health changes, remains open for unknown services, and finishes watches while draining" do
    with_adapter do |adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      operation = stub.watch(health_request, deadline: Time.now + 3, return_op: true)
      replies = operation.execute
      expect(replies.next.status).to eq(:SERVING)
      expect(adapter.update_health(ready: true, checks: { database: false })).to be(false)
      expect(replies.next.status).to eq(:NOT_SERVING)
      expect(adapter.update_health(ready: true, checks: { database: true })).to be(true)
      expect(replies.next.status).to eq(:SERVING)
      unknown = stub.watch(health_request("unknown"), deadline: Time.now + 3, return_op: true)
      unknown_replies = unknown.execute
      expect(unknown_replies.next.status).to eq(:SERVICE_UNKNOWN)
      adapter.drain!
      expect(replies.next.status).to eq(:NOT_SERVING)
      expect { replies.next }.to raise_error(StopIteration)
      expect { unknown_replies.next }.to raise_error(StopIteration)
      expect(adapter.update_health(ready: true)).to be(false)
      expect(stub.check(health_request, deadline: Time.now + 2).status).to eq(:NOT_SERVING)
    ensure
      operation&.cancel
      unknown&.cancel
    end
  end

  it "releases cancelled watches so application calls can use the pool again" do
    config.threads = 1
    with_adapter do |_adapter, address|
      stub = Grpc::Health::V1::Health::Stub.new(address, :this_channel_is_insecure)
      operation = stub.watch(health_request, deadline: Time.now + 3, return_op: true)
      replies = operation.execute
      expect(replies.next.status).to eq(:SERVING)
      operation.cancel
      expect { replies.next }.to raise_error(GRPC::Cancelled)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        expect(stub.check(health_request, deadline: Time.now + 0.2).status).to eq(:SERVING)
        break
      rescue GRPC::ResourceExhausted
        raise "cancelled watch retained the only pool thread" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end

  it "keeps direct Testing::Server health synchronized with user checks, including exceptions" do
    state = false
    config.health_checks[:database] = lambda {
      raise "database offline" if state == :error

      state
    }
    Gritz::Testing::Server.start(config, logger:) do |server|
      stub = Grpc::Health::V1::Health::Stub.new(server.address, :this_channel_is_insecure)
      expect(stub.check(health_request, deadline: Time.now + 2).status).to eq(:NOT_SERVING)
      [true, :error, true].each do |value|
        state = value
        expected = value == true ? :SERVING : :NOT_SERVING
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        until stub.check(health_request, deadline: Time.now + 0.2).status == expected
          raise "health did not update" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.01
        end
      end
    end
  end

  it "serves TLS with a trusted certificate and rejects untrusted or plaintext clients" do
    with_certificates do |ca|
      with_adapter do |_adapter, address|
        creds = GRPC::Core::ChannelCredentials.new(ca.first.to_pem)
        stub = Helloworld::Greeter::Stub.new(address, creds)
        expect(stub.say_hello(Helloworld::HelloRequest.new, deadline: Time.now + 2).message).to eq("anonymous")
        [GRPC::Core::ChannelCredentials.new(certificate("foreign CA").first.to_pem), :this_channel_is_insecure].each do |bad_creds|
          rejected = Helloworld::Greeter::Stub.new(address, bad_creds)
          expect { rejected.say_hello(Helloworld::HelloRequest.new, deadline: Time.now + 1) }.to raise_error(GRPC::BadStatus)
        end
      end
    end
  end

  it "requires trusted client certificates for mTLS and exposes their PEM identity" do
    with_certificates(mtls: true) do |ca|
      client = certificate("client", ca:, usage: "clientAuth")
      with_adapter do |_adapter, address|
        creds = GRPC::Core::ChannelCredentials.new(ca.first.to_pem, client.last.to_pem, client.first.to_pem)
        stub = Helloworld::Greeter::Stub.new(address, creds)
        pem = stub.say_hello(Helloworld::HelloRequest.new, deadline: Time.now + 2).message
        expect(OpenSSL::X509::Certificate.new(pem).subject.to_s).to include("CN=client")
        foreign = certificate("foreign client", ca: certificate("foreign CA"), usage: "clientAuth")
        [GRPC::Core::ChannelCredentials.new(ca.first.to_pem),
         GRPC::Core::ChannelCredentials.new(ca.first.to_pem, foreign.last.to_pem, foreign.first.to_pem)].each do |bad_creds|
          rejected = Helloworld::Greeter::Stub.new(address, bad_creds)
          expect { rejected.say_hello(Helloworld::HelloRequest.new, deadline: Time.now + 1) }.to raise_error(GRPC::BadStatus)
        end
      end
    end
  end

  it "advertises security and health capabilities without allocating credentials during construction" do
    with_certificates(mtls: true) do
      expect(Gritz::Transport::Native.capabilities).to include(:tls, :mtls, :health)
      expect(GRPC::Core::ServerCredentials).not_to receive(:new)
      Gritz::Transport::Native.new(config:, dispatcher: nil, logger:)
    end
  end
end
