# frozen_string_literal: true

require "grpc"
require "json"
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "echo_services_pb"

stubs = Array.new(Integer(ENV.fetch("CONNECTIONS", "64"))) do
  Echo::EchoService::Stub.new(
    ENV.fetch("ADDRESS", "127.0.0.1:50051"), :this_channel_is_insecure,
    channel_args: { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }
  )
end
tally = stubs.map { |stub| stub.echo(Echo::EchoRequest.new(message: "probe"), deadline: Time.now + 3).pid }.tally
puts JSON.generate(connections: stubs.length, distribution: tally, max_min: tally.values.max.to_f / tally.values.min)
