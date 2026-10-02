# Server Reflection

`gritz-native` supports the standard `grpc.reflection.v1` and `v1alpha` APIs.
Reflection is disabled by default. Enable it in the server configuration:

```ruby
reflection true
```

`GRITZ_REFLECTION=true` also enables it. The Rails integration enables it by
default only in development; configure `reflection false` to override that default.
Reflection runs on the same listener and thread pool as application RPCs, with the
same transport security. Each open reflection stream occupies one pool thread.

For an enabled local server, `grpcurl` can discover types without local `.proto` files:

```sh
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 describe helloworld.Greeter
grpcurl -plaintext -d '{"name":"Ruby"}' localhost:50051 helloworld.Greeter/SayHello
```

The service list includes registered application services, health, and both
reflection versions. File and symbol queries return the requested descriptor and
all transitive imports. Symbols include services, RPC methods, messages, fields,
nested messages, enums, and extensions. Extension queries return known declarations
in those files. Unknown files, symbols, extension numbers, or message types return
`NOT_FOUND` in the response; a request without a query returns `INVALID_ARGUMENT`.
These errors leave the reflection stream open for subsequent requests.

Only descriptor files for registered services and their imports are exposed.
Reflection therefore requires generated protobuf service descriptors; an enabled
server with a custom service missing its descriptor fails during binding.
Descriptors are read directly with `FileDescriptor#to_proto`; no generated-code
hook or global descriptor registry is installed.

The protocol definitions are from [grpc/grpc-proto](https://github.com/grpc/grpc-proto/tree/813330824839bfdd3abc52f41807095c0de2ec19/grpc/reflection),
commit `813330824839bfdd3abc52f41807095c0de2ec19`, under the
[Apache 2.0 license](../../proto/LICENSE.grpc-proto).
Regenerate the Ruby protocol files using the existing development dependency:

```sh
bundle exec grpc_tools_ruby_protoc -I proto --ruby_out=lib --grpc_out=lib \
  proto/grpc/reflection/v1/reflection.proto \
  proto/grpc/reflection/v1alpha/reflection.proto
```

Run the native protocol regression tests and the independent CLI check:

```sh
bundle exec rspec spec/reflection_spec.rb
GRPCURL=/path/to/grpcurl bundle exec ruby tools/check_reflection.rb
```

Reflection uses the transport TLS/mTLS configuration, but its standard service handlers do not run application middleware or Gruf interceptors. Enabling it makes descriptor discovery available to clients that can reach the listener; use transport/network access controls when enabling it outside development.
