# frozen_string_literal: true

require "spec_helper"
require "google/protobuf/descriptor_pb"
require "grpc/reflection/v1/reflection_services_pb"
require "grpc/reflection/v1alpha/reflection_services_pb"

$LOAD_PATH.unshift(File.expand_path("fixtures/reflection", __dir__))
require "reflection_service_services_pb"

RSpec.describe "Native server reflection" do
  let(:logger) { Logger.new(File::NULL) }
  let(:controller) do
    Class.new(Gritz::Controller) do
      bind ReflectionFixture::Inspector::Service
      def inspect = ReflectionFixture::Reply.new(message: "inspected")
    end
  end
  let(:config) do
    Gritz::Configuration.new.tap do |settings|
      settings.bind = "127.0.0.1:0"
      settings.controllers = [controller]
    end
  end

  def with_server(&)
    Gritz::Testing::Server.start(config, logger:, &)
  end

  def query(server, protocol, requests)
    stub = protocol::ServerReflection::Stub.new(server.address, :this_channel_is_insecure)
    stub.server_reflection_info(requests, deadline: Time.now + 3).to_a
  end

  def files(response)
    response.file_descriptor_response.file_descriptor_proto.map { |bytes| Google::Protobuf::FileDescriptorProto.decode(bytes) }
  end

  it "keeps both reflection endpoints unavailable unless explicitly enabled" do
    with_server do |server|
      [Grpc::Reflection::V1, Grpc::Reflection::V1alpha].each do |protocol|
        request = protocol::ServerReflectionRequest.new(list_services: "")
        expect { query(server, protocol, [request]) }.to raise_error(GRPC::Unimplemented)
      end
      stub = ReflectionFixture::Inspector::Stub.new(server.address, :this_channel_is_insecure)
      expect(stub.inspect(ReflectionFixture::Request.new, deadline: Time.now + 2).message).to eq("inspected")
    end
  end

  [Grpc::Reflection::V1, Grpc::Reflection::V1alpha].each do |protocol|
    context protocol.name do
      before { config.reflection = true }

      it "lists exactly the served application, health and reflection services" do
        with_server do |server|
          request = protocol::ServerReflectionRequest.new(host: "example.test", list_services: "ignored")
          response = query(server, protocol, [request]).fetch(0)
          expect(response.valid_host).to eq(request.host)
          expect(response.original_request).to eq(request)
          expect(response.list_services_response.service.map(&:name)).to contain_exactly(
            "reflection_fixture.Inspector", "grpc.health.v1.Health",
            "grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection"
          )
        end
      end

      it "returns descriptor files with imports for files, services, methods and nested symbols" do
        with_server do |server|
          requests = [protocol::ServerReflectionRequest.new(file_by_filename: "reflection_service.proto")]
          %w[reflection_fixture.Inspector reflection_fixture.Inspector.Inspect reflection_fixture.Request
             reflection_fixture.Request.at reflection_fixture.Request.Nested reflection_fixture.Request.State
             reflection_fixture.Request.State.READY grpc.health.v1.Health grpc.reflection.v1.ServerReflection
             grpc.reflection.v1alpha.ServerReflection].each do |symbol|
            requests << protocol::ServerReflectionRequest.new(file_containing_symbol: symbol)
          end
          responses = query(server, protocol, requests)
          expect(files(responses.first).map(&:name)).to contain_exactly(
            "reflection_service.proto", "reflection_types.proto", "reflection_other.proto", "google/protobuf/timestamp.proto"
          )
          responses.zip(requests).each do |response, request|
            expect(response.original_request).to eq(request)
            pool = Google::Protobuf::DescriptorPool.new
            files(response).reverse_each { |file| pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file)) }
            expect(pool.lookup(files(response).first.name)).to be_a(Google::Protobuf::FileDescriptor)
          end
        end
      end

      it "finds extension files and numbers, reports errors and keeps the stream usable" do
        with_server do |server|
          requests = [
            protocol::ServerReflectionRequest.new(file_containing_extension: protocol::ExtensionRequest.new(
              containing_type: "reflection_fixture.Request", extension_number: 100
            )),
            protocol::ServerReflectionRequest.new(all_extension_numbers_of_type: "reflection_fixture.Request"),
            protocol::ServerReflectionRequest.new(all_extension_numbers_of_type: "reflection_fixture.Reply"),
            protocol::ServerReflectionRequest.new(file_by_filename: "missing.proto"),
            protocol::ServerReflectionRequest.new(file_containing_symbol: "reflection_fixture.Inspector.Missing"),
            protocol::ServerReflectionRequest.new(all_extension_numbers_of_type: "reflection_fixture.Missing"),
            protocol::ServerReflectionRequest.new(file_containing_extension: protocol::ExtensionRequest.new(
              containing_type: "reflection_fixture.Request", extension_number: 101
            )),
            protocol::ServerReflectionRequest.new,
            protocol::ServerReflectionRequest.new(list_services: "")
          ]
          responses = query(server, protocol, requests)
          expect(files(responses[0]).first.name).to eq("reflection_service.proto")
          expect(responses[1].all_extension_numbers_response.base_type_name).to eq("reflection_fixture.Request")
          expect(responses[1].all_extension_numbers_response.extension_number).to eq([100])
          expect(responses[2].all_extension_numbers_response.extension_number).to be_empty
          expect(responses[3..7].map { |reply| reply.error_response.error_code }).to eq([5, 5, 5, 5, 3])
          expect(responses.last.list_services_response.service).not_to be_empty
        end
      end
    end
  end

  it "advertises optional reflection support" do
    expect(Gritz::Transport::Native.capabilities).to include(:reflection)
  end

  it "fails binding clearly when an enabled service has no protobuf descriptor" do
    %w[reflection_fixture.Undescribed reflection_fixture.Request].each do |name|
      service = Class.new do
        include GRPC::GenericService

        self.service_name = name
        self.marshal_class_method = :encode
        self.unmarshal_class_method = :decode
        rpc :Inspect, ReflectionFixture::Request, ReflectionFixture::Reply
      end
      config.controllers = [Class.new(Gritz::Controller) { bind service }]
      config.reflection = true
      expect { with_server { raise "server must not start" } }.to raise_error(
        Gritz::ConfigurationError, "Reflection requires a protobuf service descriptor for #{name}"
      )
    end
  end
end
