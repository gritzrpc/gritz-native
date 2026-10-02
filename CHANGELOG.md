# Changelog

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
