# frozen_string_literal: true

require_relative "lib/gritz/grpc/version"

Gem::Specification.new do |spec|
  spec.name = "gritz-grpc"
  spec.version = Gritz::Grpc::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "gRPC C-core transport for Gritz"
  spec.homepage = "https://github.com/ydah/gritz"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "README.md", "LICENSE.txt"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "googleapis-common-protos-types", ">= 1.20", "< 2"
  spec.add_dependency "gritz-core", Gritz::Grpc::VERSION
  spec.add_dependency "grpc", ">= 1.83", "< 2"
end
