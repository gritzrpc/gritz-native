# Performance and reliability checks

## Repeatable performance scenarios

`bin/bench` runs the unary light, CPU, I/O-wait, server-streaming and bidi workloads from `scenarios/performance.yml`. Each full run warms up for 30 seconds, then measures three 60-second samples and retains the median throughput, p50 and p95 in `results/<date>_<commit>_<adapter>_<scenario>.json`. Warmup and measured summaries include RPC status and error counts. Failed or incomplete runs fail the command and retain their report. Every configured worker must handle requests.

Install the pinned ghz 0.121.0 using `.devcontainer/install-tools.sh`, which checks its published SHA256. Use the benchmark-only bundle to load both adapters without adding Async to the Native Gem:

```sh
BUNDLE_GEMFILE=bench/Gemfile bundle install
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bin/bench unary-light --runner dedicated-arm64
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bin/bench unary-io --transport async --runner dedicated-arm64
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bin/bench unary-cpu --workers 2 --runner dedicated-arm64
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bin/bench unary-overhead --workers 0 --runner dedicated-arm64
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bin/bench unary-overhead --raw --runner dedicated-arm64
ruby bench/compare.rb previous.json current.json
```

`unary-overhead` fixes offered load at 1,000 RPC/s; `--raw` uses the same handler on `GRPC::RpcServer` without the framework. Other workloads measure saturation throughput. Results include source fingerprints, runner identity, Ruby, kernel, CPU and cgroup limits, CPU governor and ghz version. Compare runs on the same idle runner with the same settings. A throughput decrease or p50/p95 increase of at least 10% fails comparison. Failed runs, invalid metrics or changed environments fail rather than silently passing.

`--smoke` uses one second of warmup and one two-second sample. It checks execution only and cannot be compared to the full-run baseline. Main CI exercises the comparison boundary and failed-run cleanup tests on all supported Rubies, and runs the five Native smoke scenarios on Ruby 3.4.

The `Performance` workflow runs on the registered `gritz-benchmark-arm64` runner, with label `colima-arm64-2cpu-1g`. It checks Ruby 3.4, ghz 0.121.0, two CPU shares and a 1GiB memory limit. Repository variables select that label and `/opt/gritz-baselines`. Baselines persist in a Docker volume. Initial collection explicitly uses the dispatch input `initialize_baseline=true`; later runs require the baseline and reject regressions. Initialization creates missing files and never overwrites an existing baseline. The workflow collects every case after failures, rejects the run at the end and uploads the results. The `scenario` input can select one workload. Scheduled runs measure all five on both adapters only when `BENCH_RUNNER_ISOLATED=true`; leave it unset while the VM serves other projects.

The virtual CPUs expose no CPU governor. This limitation and the conditions for comparisons are recorded in the [environment ADR](../docs/adr/benchmark-environment.md). Measurements require an otherwise idle Colima VM. The runner is online while Docker/Colima and this machine are running; its restart policy is `unless-stopped`. See [runner operation](runner/README.md) for registration, volumes and restart commands.

Comparisons also require unchanged third-party Gem versions; Gritz versions may change because the gate measures framework changes. The initial full-matrix workflow did not pass: unary light completed three samples, then CPU traffic encountered two deadline errors during macOS host suspension. An awake-host rerun still recorded one CPU deadline. Both failures remain retained. A subsequent complete matrix passed all ten scenarios with 6,466,737 measured RPCs and zero errors. Its idle-VM baselines and exact dependency lock are retained, and a normal comparison workflow passed for both adapters. Matched target measurements establish Native p50 overhead +3.70% and two-worker CPU scaling of 1.970x Native / 1.815x Async. See the [validation report](../docs/reports/performance-validation.md) for evidence and the documented Async restart limitation.

## Chaos

Run only in an isolated Linux container with its own network namespace and `CAP_NET_ADMIN`, with `tc` installed. Keep the container memory bounded (the retained run used two CPUs and 1GiB). The scenario kills five randomly chosen workers with a fixed seed under live RPC traffic, checks recovery after each kill, adds 25ms loopback delay with `tc netem`, verifies 50 delayed RPCs, removes the qdisc, and allocates 96MiB in one worker to exercise the 120MiB RSS recycling limit.

```sh
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bench/chaos.rb --output tmp/native-chaos.json
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bench/chaos.rb --transport async --output tmp/async-chaos.json
```

Pass criteria are successful post-fault responses, correct payloads, recovery within 15 seconds, retired-process reaping, successful cluster shutdown and restored networking. Abrupt `SIGKILL` may abort an in-flight RPC; those failures are counted and retained, and are not described as zero-error graceful restart results. Failure-path tests verify evidence retention and cluster cleanup when `tc` is unavailable.

## Multiprocess soak

Run on Linux with the development bundle installed:

```sh
bundle exec ruby bench/soak.rb
```

The default scenario runs four workers and 32 clients at 100 unary RPCs per second for one hour.
Each client uses an independent C-core subchannel pool, and each RPC returns its worker PID to verify load distribution.
It records master/worker RSS, PSS, thread counts, RPC failures and aggregate latency in `tmp/soak-result.json`.
Per-worker request counts appear in progress output and the final report.
Worker replacement, premature interruption, RPC failures, an unloaded worker or an unsuccessful shutdown fail the run.

Use `--duration 5` for a smoke check and `--output PATH` to retain a report.
A smoke check does not satisfy the one-hour release gate.
Review the complete memory history for growth before recording the gate as passed.

To render the recorded memory history, install matplotlib in a reporting environment and run:

```sh
python bench/plot_soak.py tmp/soak-result.json --output tmp/soak-memory.svg
```

Matplotlib is used only for reports and is not a Gem dependency.

## Production operation gates

`bundle exec ruby bench/phased_restart.rb --ghz /path/to/ghz` runs four Linux workers under ghz load and replaces all workers with `USR1`.
It verifies load on every original and replacement worker, reaping, successful shutdown, and zero ghz errors. Use the benchmark bundle and `--transport async` to run the same gate against the Async adapter.
The [recorded Phase 3 result](../docs/reports/T3-01-phased-restart.md) retains successful repetitions and the initial failed run.

`ruby bench/kind_rollout.rb --ghz /path/to/linux/ghz --core ../gritz-core` builds the local sources and runs a two-replica rollout in an isolated kind cluster.
See the [Kubernetes guide](../docs/guides/kubernetes.md) for resource budgets, probes, sysctl settings, and result files.
`ruby bench/check_kind_failure.rb` checks failed-Job log retention and owned-cluster cleanup without starting Kubernetes.
