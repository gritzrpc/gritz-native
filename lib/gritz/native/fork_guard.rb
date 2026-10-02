# frozen_string_literal: true

# Constructor instrumentation installed without activating a master guard.
# @api private
module Gritz::Native::ForkGuard
  [GRPC::Core::Channel, GRPC::Core::Server, GRPC::Core::ChannelCredentials,
   GRPC::Core::ServerCredentials, GRPC::Core::CallCredentials, GRPC::ClientStub, GRPC::RpcServer].each do |klass|
    Gritz::ForkGuard.install(klass)
  end
end
