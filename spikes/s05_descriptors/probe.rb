# frozen_string_literal: true

require "google/protobuf"
require "google/protobuf/descriptor_pb"
require "json"

module DescriptorCapture
  FILES = {}
  def add_serialized_file(bytes)
    file = Google::Protobuf::FileDescriptorProto.decode(bytes)
    FILES[file.name] = bytes.dup.freeze
    super
  end
end
Google::Protobuf::DescriptorPool.prepend(DescriptorCapture)
require_relative "../s01_reuseport/lib/echo_pb"

bytes = DescriptorCapture::FILES.fetch("echo.proto")
file = Google::Protobuf::FileDescriptorProto.decode(bytes)
raise "Wrong service descriptor" unless file.service.first.name == "EchoService"

descriptor = Echo::EchoRequest.descriptor.file_descriptor
direct = descriptor.respond_to?(:to_proto) ? descriptor.to_proto : nil
raise "Descriptor differs from captured bytes" if direct && direct != file

encoded = Google::Protobuf::FileDescriptorProto.encode(file)
raise "Descriptor round trip changed its content" unless Google::Protobuf::FileDescriptorProto.decode(encoded) == file

puts JSON.pretty_generate(
  protobuf: Gem.loaded_specs.fetch("google-protobuf").version.to_s,
  captured: DescriptorCapture::FILES.keys, package: file.package,
  services: file.service.map(&:name), direct_to_proto: !direct.nil?,
  hook_round_trip: true, identical_encoding: encoded == bytes
)
