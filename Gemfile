# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Develop against source before the first release; releases use published gems.
unless ENV["GRITZ_RELEASE"] == "1"
  gem "gritz-core", git: "https://github.com/gritzrpc/gritz-core.git", branch: "main"
end

gem "grpc", ENV["GRPC_VERSION"] if ENV["GRPC_VERSION"]

group :development, :test do
  gem "activerecord", ">= 8.0", "< 9"
  gem "bundler-audit", "~> 0.9"
  gem "grpc-tools", "~> 1.83"
  gem "gruf", "= 2.22.0"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.75"
  gem "simplecov", "~> 0.22.0"
  gem "sqlite3", ">= 2.9.6", "< 3"
  gem "yard", "~> 0.9"
end
