# Multiprocess soak

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
It verifies load on every original and replacement worker, reaping, successful shutdown, and zero ghz errors.
The [recorded Phase 3 result](../docs/reports/T3-01-phased-restart.md) retains successful repetitions and the initial failed run.

`ruby bench/kind_rollout.rb --ghz /path/to/linux/ghz --core ../gritz-core` builds the local sources and runs a two-replica rollout in an isolated kind cluster.
See the [Kubernetes guide](../docs/guides/kubernetes.md) for resource budgets, probes, sysctl settings, and result files.
`ruby bench/check_kind_failure.rb` checks failed-Job log retention and owned-cluster cleanup without starting Kubernetes.
