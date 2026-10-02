# frozen_string_literal: true

require "gritz/native"
require "json"
require "open3"

$LOAD_PATH.unshift(File.expand_path("../spec/fixtures/reflection", __dir__))
require "reflection_service_services_pb"

controller = Class.new(Gritz::Controller) do
  bind ReflectionFixture::Inspector::Service
  def inspect = ReflectionFixture::Reply.new(message: "inspected")
end
config = Gritz::Configuration.new
config.bind = "127.0.0.1:0"
config.controllers = [controller]
grpcurl = ENV.fetch("GRPCURL", "grpcurl")

Gritz::Testing::Server.start(config) do |server|
  _output, error, status = Open3.capture3(grpcurl, "-plaintext", "-max-time", "3", server.address, "list")
  raise "Reflection was enabled by default: #{error}" if status.success?
  raise "Unexpected disabled reflection error: #{error}" unless error.include?("server does not support the reflection API")
end

config.reflection = true
Gritz::Testing::Server.start(config) do |server|
  run = lambda do |*arguments|
    output, error, status = Open3.capture3(grpcurl, "-plaintext", "-max-time", "3", *arguments)
    raise "grpcurl failed: #{error}" unless status.success?

    output
  end
  services = run.call(server.address, "list").lines.map(&:strip)
  expected = %w[grpc.health.v1.Health grpc.reflection.v1.ServerReflection grpc.reflection.v1alpha.ServerReflection reflection_fixture.Inspector]
  raise "Unexpected service list: #{services.inspect}" unless services.sort == expected.sort

  service = run.call(server.address, "describe", "reflection_fixture.Inspector")
  raise "Service method was not reflected" unless service.include?("rpc Inspect")

  message = run.call(server.address, "describe", "reflection_fixture.Request")
  raise "Imported timestamp type was not reflected" unless message.include?("google.protobuf.Timestamp at")

  response = run.call("-d", '{"at":"2026-10-02T00:00:00Z"}', server.address, "reflection_fixture.Inspector/Inspect")
  raise "Reflected RPC failed" unless JSON.parse(response).fetch("message") == "inspected"

  alpha = run.call("-import-path", File.expand_path("../proto", __dir__), "-proto", "grpc/reflection/v1alpha/reflection.proto",
                   "-d", '{"list_services":""}', server.address, "grpc.reflection.v1alpha.ServerReflection/ServerReflectionInfo")
  alpha_services = JSON.parse(alpha).fetch("listServicesResponse").fetch("service").map { |item| item.fetch("name") }
  raise "v1alpha reflection differs from v1" unless alpha_services.sort == expected.sort
end

puts "Reflection: default disabled, v1/v1alpha service lists, imported descriptors and reflected RPC passed (6 checks)."
