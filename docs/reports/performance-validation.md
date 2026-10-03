# Performance and reliability validation

Date: 2026-10-03. Full matrix collection, matched design-target measurements and an actual baseline comparison workflow completed. Native meets all five design targets. Async meets the measured scaling and idle-exit targets, with its failed zero-error restart target and remedy recorded in an ADR. Phase 6 is complete under the roadmap's allowance for documented unmet targets; Async remains experimental.

## Fixed runner and regression gate

The repository runner `gritz-benchmark-arm64` is registered and online, with label `colima-arm64-2cpu-1g`. Docker fixes its CPU quota to 200000/100000 and RAM to 1GiB. Ruby 3.4.11, ghz 0.121.0 and the runner image are pinned. The virtual CPU governor is unavailable, as recorded in the [environment ADR](../adr/benchmark-environment.md).

The [initial Performance workflow](https://github.com/gritzrpc/gritz-native/actions/runs/37098266246) failed. Native unary light completed 30-second warmup and three 60-second samples: median 8,462.81 RPC/s, p50 2.959815ms, p95 9.022528ms, with no RPC errors. Its [JSON](../../bench/results/2026-10-03_9d3d720_native_unary-light.json) is retained. Native CPU completed two samples, then returned two deadline errors in its final sample. macOS power-management records show idle sleep at 14:05:03 JST during that sample. The [failed JSON](../../bench/results/2026-10-03-native-cpu-host-sleep.json) remains failed; the other eight cases did not run. Artifact upload was unavailable after the suspension, so results were recovered directly from the runner container.

The [second collection](https://github.com/gritzrpc/gritz-native/actions/runs/37106846530) ran with host sleep inhibited and the three competing containers stopped with owner permission. Native unary light passed its existing baseline comparison. CPU traffic still produced one five-second client deadline in its third sample: 70,447 OK and one DeadlineExceeded. Retain the [failed report](../../bench/results/2026-10-03-native-cpu-idle-deadline.json) and [failed-sample summary](../../bench/results/2026-10-03-native-cpu-idle-deadline-sample.json). No OOM kill or host suspension was observed in this run. Host sleep cannot explain this second failure.

Review also found integer division in the latency comparator, which could accept a 10% increase in integer nanoseconds. Floating-point division fixes it; regression tests cover both integer and floating-point metrics. Rechecking the successful light result gives throughput -2.30%, p50 +2.48%, p95 +4.37%, below the rejection boundary. The workflow now collects every case after a measurement or comparison failure and fails the job at the end. It never installs a failed result as a baseline. Do not overwrite an existing baseline to conceal a regression.

The [complete collection](https://github.com/gritzrpc/gritz-native/actions/runs/37107474027) passed all ten scenarios with the VM otherwise idle and host sleep inhibited. It measured 6,466,737 successful RPCs, plus 1,101,098 successful warmup calls, with zero RPC errors. All reports, their settings and the [bundle lock](../../bench/results/2026-10-03_75e44e7_bundle.lock) are retained under `bench/results/2026-10-03_75e44e7_*`. The lock records the exact Core and Async Git revisions, as well as third-party versions.

The first light reference had been collected while unrelated containers were running, so its idle-VM condition was not established. The complete collection's Native light result passed comparison against it: throughput +3.03%, p50 -4.03%, p95 -0.88%. After this review, the idle result replaced that reference in the baseline volume. The old reference remains archived both there and in Git. The other nine missing baselines were initialized only from successful reports. A [normal comparison dispatch](https://github.com/gritzrpc/gritz-native/actions/runs/37108257802) passed against the idle baselines for both adapters: Native throughput -0.51%, p50 +0.17%, p95 +3.22%; Async throughput +3.33%, p50 -3.41%, p95 -4.70%. Its 2,246,806 measured calls had no RPC errors. The `2026-10-03_98beb93_*_unary-light.json` reports and [exact lock](../../bench/results/2026-10-03_98beb93_bundle.lock) are retained. Scheduled runs remain disabled while this Colima VM is shared; manual measurements require an idle VM.

| Scenario | Native RPC/s | Native p50 / p95 ms | Async RPC/s | Async p50 / p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Unary light | 8,719.43 | 2.841 / 8.943 | 3,715.26 | 7.982 / 12.588 |
| Unary CPU | 1,159.21 | 4.791 / 54.607 | 1,081.93 | 28.950 / 32.686 |
| Unary I/O wait | 2,916.73 | 10.696 / 12.266 | 2,394.86 | 12.911 / 16.760 |
| Server streaming | 4,943.81 | 4.911 / 19.753 | 3,445.71 | 8.608 / 12.748 |
| Bidirectional streaming | 4,171.96 | 6.116 / 23.147 | 3,261.11 | 8.966 / 13.663 |

These are saturation measurements at one worker and 32 concurrent calls, with enabled completion logging. They are not the fixed-rate bare-RpcServer overhead comparison. The successful CPU rerun does not establish a remedy for the earlier sporadic deadline error. The matched raw CPU run passed at 1,415.63 RPC/s; the [investigation ADR](../adr/cpu-deadline-investigation.md) retains the unresolved cause and corrective work.

## Design targets

| Target | Evidence | Status |
| --- | --- | --- |
| Unary p50 overhead at most 5% versus bare RpcServer | At 1,000 RPC/s, Native single-process p50 297,459ns / raw 286,834ns = +3.70% | Passed for Native; bare RpcServer is the Native comparison |
| Worker scaling within 15% of linear through core count | Two/one-worker CPU throughput: Native 1.970x, Async 1.815x; required 1.7–2.3x | Passed for both adapters |
| Additional Rails worker PSS at most 40% of single-process RSS | Phase 5 results: 37.910%, 35.820%, 38.053% | Passed |
| Phased-restart RPC errors 0% | Native: 3,002 calls, zero errors; Async: one UNAVAILABLE in 3,001 calls | Native passed; Async failed |
| Idle TERM exit at most drain_delay + 1 second | Full matrix and target reports: 0.230464–0.280342 seconds with drain_delay 0.2 | Passed |

The five additional target/diagnostic reports are `2026-10-03_98beb93_{native-cpu-raw,native-cpu-two-workers,async-cpu-two-workers,native-overhead,native-overhead-raw}.json`. Each uses 30 seconds of warmup and three 60-second samples, with no RPC errors across 1,379,733 measured calls. The overhead pair uses the same handler, 64-thread pool, 32 clients and offered rate; framework completion logging and metrics remain enabled. The scaling pair uses the identical CPU workload and runner as the one-worker matrix, but the Core revision includes only a TLS-file validation change outside this plaintext workload; both dependency locks are retained. Client and server share the quota, so this demonstrates scaling in the recorded environment rather than an isolated server CPU efficiency claim. Raw reports have no framework idle-shutdown measurement. Worker status counters establish load on every worker; they are asynchronously sampled and are not a substitute for ghz's completed-call counts.

All measurements ended before the competing containers restarted at 08:47:37 UTC. Subsequent measurements require arranging another idle session or a dedicated VM.

Native's [restart JSON](../../bench/results/2026-10-03-native-phased-restart.json) verifies load on all four old and replacement workers and retirement reaping. Async's [failed JSON](../../bench/results/2026-10-03-async-phased-restart.json) is retained with its [cause, remedy and experimental-status decision](https://github.com/gritzrpc/gritz-async/blob/main/docs/adr/phased-restart-limit.md). A passing single-inflight shutdown contract does not replace the failed concurrent restart result.

## Completed chaos and profiling checks

Both adapters passed five seeded random worker kills under traffic, bounded replacement, 25ms loopback delay with 50 successful delayed RPCs, and recycling after retaining 96MiB with a 120MiB RSS threshold. Every retired process was reaped and network configuration was restored. Native recorded one UNAVAILABLE during abrupt SIGKILL; Async recorded none. Abrupt-fault recovery does not have the zero-error graceful-restart criterion. See the [Native](../../bench/results/2026-10-03-native-chaos.json) and [Async](../../bench/results/2026-10-03-async-chaos.json) evidence.

Core's suppressed-log optimization reduced the measured dispatch median by 36.82% and allocations by 44.58%. Its [profile ADR](https://github.com/gritzrpc/gritz-core/blob/main/docs/adr/lazy-completion-logging.md) records the workload and limits: this is an in-memory dispatch improvement, not measured wire overhead or an enabled-logging result. The current main suites contain 427 tests (Core 203, Native 127, meta 12, Otel 33, Rails 18, Async 34) and pass on Ruby 3.3, 3.4 and 4.0, including lint, dependency audit and strict builds. Both adapters pass the 14 shared transport contracts. External beta operation was canceled by the owner and has been removed from the roadmap.
