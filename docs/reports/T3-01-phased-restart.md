# T3-01: Native phased restart under load

Date: 2026-10-02. The Phase 3 phased-restart gate passed for the recorded workload.

The final 30-second run completed 2,998 unary RPCs with zero reported errors while all four workers were replaced. Every original and replacement worker received application traffic. Replacement completed in 0.912 seconds, all original worker PIDs were confirmed gone, and final supervisor shutdown returned success. Three preceding 10-second repetitions completed another 2,995 RPCs with zero reported errors.

## Environment and workload

| Item | Value |
| --- | --- |
| Linux | 6.8.0-117-generic, aarch64 |
| Docker VM | 2 CPUs, approximately 2 GiB memory |
| Ruby / grpc / ghz | 3.4.11 / 1.83.0 / 0.121.0 |
| Final run | 2026-10-02 07:03:29–07:03:59 UTC |
| Workers / client connections / concurrency | 4 / 64 / 64 |
| Request rate / deadline | 100 RPCs per second / 2 seconds |
| Handler | Hello unary RPC with a 10 ms sleep |
| Drain delay / shutdown timeout | 0.2 seconds / 5 seconds |
| tcp_migrate_req | 1 |
| Mean final-run latency | 11.635 ms |

The driver waited until every original worker had served requests and the combined count reached at least 50 before sending `USR1`. It then required four healthy replacement workers, completed replacement status, and removal of every original PID. The load generator ran through the remaining duration; the driver checked all replacement workers had received traffic before stopping the cluster.

ghz used `--duration-stop=wait`, which avoids cancelling outstanding calls when the load duration ends. The driver did not add client retries or discard errors. Each run required a positive completed count, an empty error distribution, and an `OK`-only status distribution.

## Recorded results

| Run | Completed RPCs | Errors | Replacement time (seconds) | Mean latency (ms) |
| --- | ---: | ---: | ---: | ---: |
| Before the acceptance-loop fix, 10 seconds | 998 | 1 `Canceled` | 0.882 | 11.568 |
| Repetition 1, 10 seconds | 999 | 0 | 0.880 | 11.378 |
| Repetition 2, 10 seconds | 998 | 0 | 0.874 | 11.495 |
| Repetition 3, 10 seconds | 998 | 0 | 0.877 | 11.561 |
| Final gate, 30 seconds | 2,998 | 0 | 0.912 | 11.635 |

The final run's worker snapshots establish distribution, rather than attributing every RPC across retirement:

| Generation | Worker PID | Recorded application RPCs |
| --- | ---: | ---: |
| Original, before `USR1` | 25070 | 12 |
| Original, before `USR1` | 25073 | 12 |
| Original, before `USR1` | 25076 | 9 |
| Original, before `USR1` | 25079 | 18 |
| Replacement, after load | 25186 | 1,032 |
| Replacement, after load | 25213 | 678 |
| Replacement, after load | 25241 | 676 |
| Replacement, after load | 25269 | 490 |

## Initial failure and correction

The first run returned one `Canceled` response at 06:21:39.908704099 UTC, during replacement rather than at the end of its ten-second duration. Its gate remained failed. The [failed summary](../../bench/results/2026-10-02-phase3-phased-before-fix.json) and [complete ghz output](../../bench/results/2026-10-02-phase3-phased-before-fix-ghz.json) are retained.

In grpc 1.83, Ruby's `RpcServer#stop` changes the running state to `stopping` and holds the running-state mutex while C-core shutdown completes. The Ruby acceptance loop checks that state before posting another `request_call`. An RPC already accepted at shutdown entry can finish, then leave the loop waiting on this mutex while further incoming calls remain unmatched. The Gritz server now continues calling C-core `request_call` until C-core closes acceptance, then performs the final state transition. See the [upstream Ruby implementation](https://github.com/grpc/grpc/blob/v1.83.0/src/ruby/lib/grpc/generic/rpc_server.rb) and the [Native server change](../../lib/gritz/transport/native/server.rb).

The [real-socket regression](../../spec/native_shutdown_spec.rb) holds entry to `shutdown_and_notify` with a queue barrier. With the original loop, the first call succeeded but the second reached its deadline. With the corrected loop, both complete before releasing the barrier and allowing shutdown. This checks the acceptance gap directly, without depending on the timing of a load run.

## Scope and compatibility

Zero errors were observed in these four successful runs. This does not establish zero-loss replacement for every request rate, network, streaming workload, deadline, or future grpc version. The adapter overrides Ruby `RpcServer` internals from grpc 1.83; grpc upgrades must retain the real-socket shutdown and load gates.

C-core can still terminate calls that have arrived but have not been matched to an application request. Its shutdown path clears pending work before broadcasting transport shutdown; see the [v1.83 server source](https://github.com/grpc/grpc/blob/v1.83.0/src/core/server/server.cc#L1456). The upstream [pending-call cancellation issue](https://github.com/grpc/grpc/issues/41785) records this separate behavior. Continuing Ruby acceptance removes the measured mutex gap, but does not replace that C-core behavior or introduce a new public drain API.

The runs used local Phase 3 sources before the release version bump. The final run included the acceptance-loop correction and Health Watch status mapping. Subsequent busy-gauge and launcher diagnostic changes leave the native acceptance and shutdown path unchanged. Kubernetes rolling replacement has a separate gate and report.

## Full runtime validation

The final Phase 3 runtime passed all 68 Native examples in the Linux container after the load gate. Line coverage was 96.86% (308/318), above the 90% requirement; branch coverage was 76.58% (85/111). RuboCop inspected 37 files with no offenses.

This suite includes real Health Check/Watch status changes, cancellation and deadlines, handler-error mapping, TLS trust and plaintext rejection, mTLS client verification and PEM identity, the occupied Watch pool-thread gauge, multi-worker metrics totals and retirement retention, worker recycling, three fresh-code reexec generations with rollback, and startup/shutdown failure exits. Single-process CLI tests also verify that direct `USR1` leaves service readiness intact, and that `TERM` keeps probes, metrics and RPCs available during the drain delay while Health reports `NOT_SERVING`; an in-flight response then completes within the shutdown grace. The TLS rejection cases intentionally emit C-core handshake diagnostics.

The full macOS run on Ruby 4.0.6 also passed: 43 executed examples, zero failures, and 25 Linux-only examples skipped. Health/TLS, shutdown acceptance, and both single-process CLI lifecycle tests ran successfully. Native line and branch coverage matched the Linux measurements.

```sh
COVERAGE=1 bundle exec rake
bundle exec rubocop
```

## Reproduce and inspect

On Linux with the development bundle and ghz installed:

```sh
bundle exec rspec spec/native_shutdown_spec.rb
bundle exec ruby bench/phased_restart.rb --ghz /path/to/ghz --output tmp/phased-restart.json
```

The [final summary](../../bench/results/2026-10-02-phase3-phased-restart.json) and [complete final ghz output](../../bench/results/2026-10-02-phase3-phased-restart-ghz.json) retain per-call timestamps and statuses. The repeated-run evidence is also preserved: [run 1 summary](../../bench/results/2026-10-02-phase3-phased-repeat-1.json) / [raw ghz](../../bench/results/2026-10-02-phase3-phased-repeat-1-ghz.json), [run 2 summary](../../bench/results/2026-10-02-phase3-phased-repeat-2.json) / [raw ghz](../../bench/results/2026-10-02-phase3-phased-repeat-2-ghz.json), and [run 3 summary](../../bench/results/2026-10-02-phase3-phased-repeat-3.json) / [raw ghz](../../bench/results/2026-10-02-phase3-phased-repeat-3-ghz.json).
