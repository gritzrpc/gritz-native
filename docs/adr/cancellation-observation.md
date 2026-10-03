# Observe cancellation while application handlers run

- Status: Accepted
- Date: 2026-10-04

## Problem and decision

The official grpc gem's server-side `ActiveCall#cancelled?` reads a status field that is populated on clients, not during server handlers. A cancelled client could leave a cooperative controller holding the only serving thread indefinitely. The old contract checked only the client's cancellation and manually released the controller, so it did not detect this failure.

Observe C-core's `RECV_CLOSE_ON_SERVER` operation for each application call that checks cancellation. The observer owns that operation; remove it from the ordinary status batch while preserving all sends. grpc 1.83 and 1.84 do not expose C-core's cancelled flag in `BatchResult`, so a close while the handler is running latches cancellation. Failed status sends also latch it; successful status completion stays false. Serialize observer creation, status ownership and final close, and join the observer before releasing the native completion queue.

This remains internal to the Native adapter. Health/Reflection retain their existing lifecycle handling. Observers start after worker fork and are limited by admitted application calls. Dispatcher checks mean each ordinary application RPC normally uses one additional short-lived thread. No runtime dependency or new configuration is added.

## Validation and performance limit

Real-wire tests cover cooperative cancellation for unary, client-streaming, server-streaming and bidi RPCs, pool recovery, ten repeated cancellations without live observers, successful retained contexts, and forced shutdown. Scheduling regressions cover concurrent observer creation, status/close races and failed-status latching.

The [short diagnostic](../../bench/results/2026-10-04_cancellation-diagnostic.json) retains the executable probe source, all samples and source hashes. Each variant completed 6,000 sequential unary calls with eight serving threads on Linux ARM64, Ruby 3.4.11 and grpc 1.84. The baseline allocated about 138 objects per RPC; the final fix allocated about 193. Timing varied between samples on the shared VM and showed additional latency. This is evidence of cost, not a fixed-runner performance pass.

The earlier +3.70% Native p50 result predates this fix. Native 0.9.1's 5% overhead target and fixed-runner regression comparison remain unverified. Rerun the existing `bin/bench unary-overhead` procedure against the raw server on an isolated runner before approving 1.0; preserve any failure and investigate it instead of replacing the baseline. The [CPU deadline investigation](cpu-deadline-investigation.md) also remains open. Unrelated owner workloads must remain running.

## Alternatives

Keeping the stock status query would retain the confirmed pool exhaustion bug. Reading native object memory or adding another C extension would tie cancellation to undocumented layouts and broaden the supported build surface. A reusable observer pool may reduce thread creation cost, but requires measured justification and equivalent cancellation/shutdown checks on the isolated runner.
