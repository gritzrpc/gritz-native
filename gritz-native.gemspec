# frozen_string_literal: true

require_relative "lib/gritz/native/version"

Gem::Specification.new do |spec|
  spec.name = "gritz-native"
  spec.version = Gritz::Native::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.description = "The native gRPC adapter for Gritz, using the official grpc gem and a thread pool."
  spec.summary = "gRPC C-core transport for Gritz"
  spec.homepage = "https://github.com/gritzrpc/gritz-native"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "proto/**/*.proto", "proto/LICENSE.grpc-proto", "README.md", "LICENSE.txt", "CHANGELOG.md"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "googleapis-common-protos-types", ">= 1.20", "< 2"
  spec.add_dependency "gritz-core", "= 0.9.0"
  spec.add_dependency "grpc", ">= 1.83", "< 2"
end
