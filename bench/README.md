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
