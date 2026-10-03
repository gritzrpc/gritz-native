# frozen_string_literal: true

require "gritz/core"
require "grpc"
require "google/rpc/status_pb"
require "google/protobuf/any_pb"
require "google/protobuf/well_known_types"
require_relative "native/version"
require_relative "native/fork_guard"
require_relative "transport/native"
require_relative "transport/native/call"
require_relative "transport/native/bridge"
require_relative "transport/native/server"
require_relative "transport/native/health"
require_relative "transport/native/client"
require "gritz/testing/server"

Gritz::Client.adapter = Gritz::Transport::Native::Client
