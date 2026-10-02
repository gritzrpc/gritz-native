# Gritz Native

The native gRPC transport adapter for Gritz, using the official `grpc` gem (C-core) and a thread pool. It supports unary, server streaming, client streaming and bidirectional streaming, and provides the real-socket testing helper.

Requires CRuby 3.3 or later and grpc 1.83 or later. Linux and macOS are tested.

```ruby
require "gritz/native"
```

The entry point loads `gritz-core` and registers `Gritz::Transport::Native`. The configuration value is `transport :native`. Use [gritz](https://github.com/gritzrpc/gritz) for the default combination and executable. The Fiber adapter `gritz-async` is planned separately.

```ruby
Gritz::Testing::Server.start(controllers: [GreeterController]) do |server|
  stub = Helloworld::Greeter::Stub.new(server.address, :this_channel_is_insecure)
  stub.say_hello(Helloworld::HelloRequest.new(name: "Ruby"))
end
```

The helper opens an ephemeral port and stops the server when the block exits. The server currently supports a single process and insecure sockets; use a trusted network or a TLS-terminating proxy. See the [framework documentation](https://github.com/gritzrpc/gritz) for configuration and limitations.

## Development

```sh
git clone https://github.com/gritzrpc/gritz-native.git
cd gritz-native
bundle install
COVERAGE=1 bundle exec rake
bundle exec rubocop
bundle exec rake build
```

Integration tests contain their own protobuf fixtures and exercise all four RPC forms over real sockets. The [Linux devcontainer](.devcontainer/devcontainer.json) includes grpcurl and ghz. For local core changes, use the Bundler override in [CONTRIBUTING.md](CONTRIBUTING.md). See [SECURITY.md](SECURITY.md) and the [release guide](docs/guides/releasing.md).

## License

[MIT](LICENSE.txt).
