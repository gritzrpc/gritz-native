# Performance and reliability validation

Date: 2026-10-03. Performance collection is incomplete; Phase 6 is not complete.

## Fixed runner and regression gate

The repository runner `gritz-benchmark-arm64` is registered and online, with label `colima-arm64-2cpu-1g`. Docker fixes its CPU quota to 200000/100000 and RAM to 1GiB. Ruby 3.4.11, ghz 0.121.0 and the runner image are pinned. The virtual CPU governor is unavailable, as recorded in the [environment ADR](../adr/benchmark-environment.md).

The [initial Performance workflow](https://github.com/gritzrpc/gritz-native/actions/runs/37098266246) failed. Native unary light completed 30-second warmup and three 60-second samples: median 8,462.81 RPC/s, p50 2.959815ms, p95 9.022528ms, with no RPC errors. Its [JSON](../../bench/results/2026-10-03_9d3d720_native_unary-light.json) is retained. Native CPU completed two samples, then returned two deadline errors in its final sample. macOS power-management records show idle sleep at 14:05:03 JST during that sample. The [failed JSON](../../bench/results/2026-10-03-native-cpu-host-sleep.json) remains failed; the other eight cases did not run. Artifact upload was unavailable after the suspension, so results were recovered directly from the runner container.

The [second collection](https://github.com/gritzrpc/gritz-native/actions/runs/37106846530) ran with host sleep inhibited and the three competing containers stopped with owner permission. Native unary light passed its existing baseline comparison. CPU traffic still produced one five-second client deadline in its third sample: 70,447 OK and one DeadlineExceeded. Retain the [failed report](../../bench/results/2026-10-03-native-cpu-idle-deadline.json) and [failed-sample summary](../../bench/results/2026-10-03-native-cpu-idle-deadline-sample.json). No OOM kill or host suspension was observed in this run. Host sleep cannot explain this second failure.

Review also found integer division in the latency comparator, which could accept a 10% increase in integer nanoseconds. Floating-point division fixes it; regression tests cover both integer and floating-point metrics. Rechecking the successful light result gives throughput -2.30%, p50 +2.48%, p95 +4.37%, below the rejection boundary. The workflow now collects every case after a measurement or comparison failure and fails the job at the end. It never installs a failed result as a baseline. Full collection and a later normal comparison dispatch remain pending. Do not overwrite an existing baseline to conceal a regression.

## Design targets

| Target | Evidence | Status |
| --- | --- | --- |
| Unary p50 overhead at most 5% versus bare RpcServer | Matched fixed-rate raw/framework measurements remain pending | Unverified |
| Worker scaling within 15% of linear through core count | Matched one/two-worker CPU measurements remain pending | Unverified |
| Additional Rails worker PSS at most 40% of single-process RSS | Phase 5 results: 37.910%, 35.820%, 38.053% | Passed |
| Phased-restart RPC errors 0% | Native: 3,002 calls, zero errors; Async: one UNAVAILABLE in 3,001 calls | Native passed; Async failed |
| Idle TERM exit at most drain_delay + 1 second | Native unary-light result: 0.243589 seconds with drain_delay 0.2 | Passed for this run; remaining cases pending |

Native's [restart JSON](../../bench/results/2026-10-03-native-phased-restart.json) verifies load on all four old and replacement workers and retirement reaping. Async's [failed JSON](../../bench/results/2026-10-03-async-phased-restart.json) is retained with its [cause, remedy and experimental-status decision](https://github.com/gritzrpc/gritz-async/blob/main/docs/adr/phased-restart-limit.md). A passing single-inflight shutdown contract does not replace the failed concurrent restart result.

## Completed chaos and profiling checks

Both adapters passed five seeded random worker kills under traffic, bounded replacement, 25ms loopback delay with 50 successful delayed RPCs, and recycling after retaining 96MiB with a 120MiB RSS threshold. Every retired process was reaped and network configuration was restored. Native recorded one UNAVAILABLE during abrupt SIGKILL; Async recorded none. Abrupt-fault recovery does not have the zero-error graceful-restart criterion. See the [Native](../../bench/results/2026-10-03-native-chaos.json) and [Async](../../bench/results/2026-10-03-async-chaos.json) evidence.

Core's suppressed-log optimization reduced the measured dispatch median by 36.82% and allocations by 44.58%. Its [profile ADR](https://github.com/gritzrpc/gritz-core/blob/main/docs/adr/lazy-completion-logging.md) records the workload and limits: this is an in-memory dispatch improvement, not measured wire overhead or an enabled-logging result. All six local suites passed 424 tests, lint and strict builds; both adapters passed the 14 shared transport contracts. External beta operation was canceled by the owner and has been removed from the roadmap.
