# frozen_string_literal: true

require "spec_helper"
require "gritz/testing/transport_contract"
$LOAD_PATH.unshift File.expand_path("fixtures/hello", __dir__)
require "hello_services_pb"

RSpec.describe "Native transport contract" do
  include_examples Gritz::Testing::TransportContract,
                   adapter: :native, service: Helloworld::Greeter::Service, stub: Helloworld::Greeter::Stub,
                   request: Helloworld::HelloRequest, reply: Helloworld::HelloReply
end
