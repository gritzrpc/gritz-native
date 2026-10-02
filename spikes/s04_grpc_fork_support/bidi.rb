# frozen_string_literal: true

ENV["GRPC_ENABLE_FORK_SUPPORT"] = "1"
require "grpc"
require "json"
$LOAD_PATH.unshift(File.expand_path("../s01_reuseport/lib", __dir__))
require "echo_services_pb"

raise "Experimental fork probe requires Linux" unless RUBY_PLATFORM.include?("linux")

release = Queue.new
requests = Enumerator.new do |writer|
  writer << Echo::EchoRequest.new(message: "bidi")
  release.pop
end
stub = Echo::EchoService::Stub.new(ENV.fetch("ADDRESS", "127.0.0.1:50051"), :this_channel_is_insecure)
responses = stub.chat(requests, deadline: Time.now + 5)
raise "Bidi did not respond" unless responses.next.message == "bidi"

error = begin
  GRPC.prefork
  GRPC.postfork_parent
  raise "Active bidi was unexpectedly accepted"
rescue RuntimeError => e
  raise unless e.message.include?("bidirectional")

  e.message
end
release << true
responses.each { |_response| nil }
puts JSON.pretty_generate(grpc: GRPC::VERSION, ruby: RUBY_DESCRIPTION, active_bidi_rejected: true, error: error)
