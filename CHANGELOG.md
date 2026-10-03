# Changelog

## 0.6.0

- Support gritz-core 0.6.0 and its shared real-server helper, preserving `Gritz::Testing::Server` and Native RPC behavior.

## 0.5.0

- Discover registered RPCs and protobuf types through gRPC Reflection v1 and v1alpha when `reflection` is enabled.
- Support gritz-core 0.5.0.

## 0.4.0

- Connect `Gritz::Client` to all four native RPC forms with shared worker-local channels and deferred credentials.
- Cancel unfinished response streams and decode downstream status, trailers and protobuf rich error details into typed Gritz errors.
- Pass retry and load-balancing service configuration to the native channel.
- Run installed worker telemetry with real-server test helpers and close it after the final RPC observations.

## 0.3.0

- Serve TLS and mTLS connections and expose authenticated client certificates to handlers.
- Provide standard gRPC Health Check and Watch methods linked to application health and draining.
- Finish accepted RPCs during graceful shutdown and phased worker replacement.
- Report actual native thread-pool usage, including active Health watches.

## 0.2.0

- Detect native gRPC constructors in the master before fork.
- Support experimental Linux grpc fork callbacks for parent-side clients.

## 0.1.0

Initial release.
