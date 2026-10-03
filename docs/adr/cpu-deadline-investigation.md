# Sporadic deadline under saturated CPU traffic

- Status: Accepted
- Date: 2026-10-03

## Evidence

An awake-host, otherwise idle two-CPU/1GiB run returned one five-second deadline in 70,448 calls during the third Native CPU sample. The other 70,447 calls succeeded. No host suspension or OOM kill was observed. The [failed report](../../bench/results/2026-10-03-native-cpu-idle-deadline.json) and [individual failed-call summary](../../bench/results/2026-10-03-native-cpu-idle-deadline-sample.json) remain failed.

The subsequent full matrix completed all three Native CPU samples without errors. A matched bare `GRPC::RpcServer` run also completed three samples without errors, at a median 1,415.63 RPC/s. These later successes do not identify the earlier failure's cause or establish a fix.

## Decision and corrective work

Keep the five-second client deadline and reject every run with an RPC error. Do not suppress errors with retries, extend the deadline to obtain a passing measurement, or promote a failed result as a baseline. The current hypothesis is an intermittent scheduling or queueing tail under saturation; the report alone cannot distinguish Ruby thread scheduling, framework dispatch and C-core transport behavior.

The next investigation must retain per-call timing and worker queue/inflight observations for matched framework and raw runs, then capture a sampling profile around a reproduced tail. Isolate client CPU from the server quota if shared client/server scheduling prevents attribution. Add a regression for the established cause before describing it as fixed. Until then, the successful matrix is reproducible evidence for that collection, not a guarantee that saturated CPU traffic never exceeds five seconds.
