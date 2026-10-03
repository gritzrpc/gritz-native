# Gritz Native

The native gRPC transport adapter for Gritz, using the official `grpc` gem (C-core) and a thread pool. It supports unary, server streaming, client streaming and bidirectional streaming, and provides the real-socket testing helper.

Requires CRuby 3.3 or later and grpc 1.83 or later. Linux and macOS are tested.

```ruby
require "gritz/native"
```

The entry point loads `gritz-core` and registers `Gritz::Transport::Native`. The configuration value is `transport :native`. Use [gritz](https://github.com/gritzrpc/gritz) for the default combination and executable. The experimental [gritz-async](https://github.com/gritzrpc/gritz-async) adapter provides Fiber execution and inherited listeners separately.

The adapter also connects `Gritz::Client.define` to all four RPC forms, sharing channels within each worker and creating fresh connections after fork. It cancels unfinished streams, decodes rich downstream errors, and passes retry/load-balancing configuration to C-core. See the [client guide](https://github.com/gritzrpc/gritz-core/blob/main/docs/guides/clients.md).

The [three-service integration report](https://github.com/gritzrpc/gritz-otel/blob/main/docs/reports/T4-08-client-chain.md) records worker-local channels, propagated deadlines, connected server/client spans and real OTLP/HTTP metrics.

```ruby
Gritz::Testing::Server.start(controllers: [GreeterController]) do |server|
  stub = Helloworld::Greeter::Stub.new(server.address, :this_channel_is_insecure)
  stub.say_hello(Helloworld::HelloRequest.new(name: "Ruby"))
end
```

The helper opens an ephemeral port and stops the server when the block exits. The helper runs a single process. Supervised native servers support forked workers on Linux. TLS and required client certificate verification are configured with `tls cert:, key:, client_ca:`. Standard gRPC Health Check/Watch tracks application checks and draining. See the [Kubernetes guide](docs/guides/kubernetes.md) and [framework configuration](https://github.com/gritzrpc/gritz-core/blob/main/docs/guides/configuration.md).

Set `reflection true` to enable gRPC Reflection v1/v1alpha for registered services, message descriptors and protobuf imports. The default is disabled. See the [Reflection guide](docs/guides/reflection.md).

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
