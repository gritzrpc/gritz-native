# Fixed benchmark execution environment

- Status: Accepted
- Date: 2026-10-03

## Decision

Register a repository-scoped Linux ARM64 runner for performance checks. Use a Ruby image pinned by digest, ghz 0.121.0 and Actions Runner 2.337.0, verified against GitHub's published SHA256. Docker fixes CPU quota at 200000/100000 and memory at 1073741824 bytes. Run one benchmark job at a time, with no competing workloads in the two-core Colima VM. Ordinary Ruby test CI continues on GitHub-hosted runners.

The virtual CPU provides no `cpufreq` governor. Physical clock speed is controlled by the macOS host, so a constant clock frequency cannot be claimed. Record the unavailable governor, kernel, CPU identity, quotas, Ruby and ghz in every result and reject comparisons when that environment or workload changes. Three 60-second samples after 30-second warmup reduce short-term variation. They do not eliminate host contention or thermal variation; unexpected regressions require investigation, not automatic baseline replacement. A physical dedicated Linux machine with a performance governor is the upgrade path when host variation prevents stable measurements.

## Baselines and CI

The first dispatch explicitly initializes missing baselines in the persistent baseline volume. Later runs fail for missing or incomparable baselines, failed RPCs, or at least a 10% throughput decrease or p50/p95 increase. Initialization never replaces an existing baseline. Retain JSON results in Git and upload workflow artifacts on failure as well as success. A short smoke run is not a full performance measurement.

Use the runner only for the main-branch performance workflow, which requests read-only repository permissions. Keep runner credentials in its Docker volume, registration tokens in memory/stdin, and the host Docker socket and workspace out of the container. The container exposes no host ports. The repository registration does not require extra organization administration privileges.

The current Colima VM is shared with other projects, whose containers are stopped only for this owner-authorized measurement session and restored afterward. Scheduled jobs require `BENCH_RUNNER_ISOLATED=true`; keep it unset while this VM is shared. Manual comparisons remain available after arranging an idle VM. Move the runner to a dedicated VM or machine before enabling nightly measurements. The workflow has neither permission nor a mounted socket to stop unrelated containers itself.

## Performance targets

This environment supplies reproducible resource limits and an actual CI execution path. Full measurements establish Native p50 overhead +3.70% and two-worker CPU scaling of 1.970x Native / 1.815x Async. The [validation report](../reports/performance-validation.md) retains the full matrix, matched settings, comparison workflow and Async's unmet restart target. Registration and smoke tests alone do not establish those results. The [sporadic CPU deadline ADR](cpu-deadline-investigation.md) preserves the failed saturated sample and unresolved cause.
