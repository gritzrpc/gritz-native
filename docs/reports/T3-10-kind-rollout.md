# T3-10: Kubernetes rolling update under load

Date: 2026-10-02. The Phase 3 kind gate passed on the final v0.3.0 runtime sources.

The 90-second run completed 9,004 unary RPCs, all `OK`, while replacing both application Pods. Each of the four original workers received application traffic before the update. The driver sampled at least two ready Service endpoints throughout the observed rollout, confirmed that neither old Pod remained, and deleted its dedicated cluster successfully.

## Environment and workload

| Item | Value |
| --- | --- |
| Kubernetes / kind / ghz | 1.37.0 / 0.33.0 / 0.121.0 |
| Docker host | Linux 6.8.0-117-generic, aarch64, 2 CPUs, approximately 2 GiB memory |
| Application Ruby / grpc | 3.4.11 / 1.83.0 |
| Host driver Ruby | 4.0.6 on macOS |
| Replicas / workers per Pod / native threads | 2 / 2 / 16 |
| Rollout policy | maxUnavailable 0, maxSurge 1 |
| Connections / concurrency / rate / deadline | 32 / 32 / 100 RPCs per second / 2 seconds |
| Load duration / mean latency | 90.056 seconds / 0.611 ms |
| Driver execution | 2026-10-02 07:55:43–07:58:04 UTC |
| Pod drain / shutdown / termination grace | 5 / 25 / 40 seconds |
| tcp_migrate_req | 1 in each application Pod |

The verified official node's arm64 manifest was `sha256:5dccdf63c6078c3edc2a044974ca5a25f574988b6bdeb9ace9a695655bc8b6e1`, selected from the multiarch digest pinned in [kind.yml](../../examples/kubernetes/kind.yml). The application image was `sha256:d6d51f2088643db04a9cfbbb9989b7bc5e97cfa6c043fb1120d1820f604192c9`, built from the final local core/native v0.3.0 sources. Core runtime matches commit `5b24c823412e0fcae87f1ab70340456f6873f6d6`; Native runtime matches this report's commit.

This machine had a legacy Docker builder and could not fetch Docker Hub through the daemon's certificate store. The run used verified cached node layers and an offline build from the same runtime dependency gems and local source files. The temporary build copied core/native sources into one context rather than using the example Dockerfile's BuildKit named contexts. This verifies the Deployment and application runtime; it does not claim that the normal networked BuildKit build was exercised here.

## Results and first failure

| Run | Completed RPCs | Errors | Minimum sampled ready endpoints | Owned cluster removed |
| --- | ---: | ---: | ---: | --- |
| Before disabling Service links | 0; application boot failed | Gate failed before load | — | Yes |
| Development smoke, 60 seconds | 5,999 | 0 | 2 | Yes |
| Final runtime, 90 seconds | 9,004 | 0 | 2 | Yes |

The first application Pods failed configuration parsing: a Service named `gritz` automatically injected `GRITZ_SERVICE_HOST` and related variables, while Gritz rejects unknown `GRITZ_*` settings. The manifest now sets `enableServiceLinks: false` and uses Service DNS. The [failed summary](../../bench/results/2026-10-02-phase3-kind-before-service-links.json) remains failed; its result was not converted into a successful gate.

The [final summary](../../bench/results/2026-10-02-phase3-kind-rollout.json) contains initial worker counters, old/new Pod names, endpoint samples, ghz totals and cleanup status. The [complete ghz output](../../bench/results/2026-10-02-phase3-kind-rollout-ghz.json) retains per-call results. The earlier [smoke summary](../../bench/results/2026-10-02-phase3-kind-smoke.json) and [raw ghz output](../../bench/results/2026-10-02-phase3-kind-smoke-ghz.json) are also retained.

The load job used `--duration-stop=wait` and no configured retries. Success required completed calls, an empty error distribution, `OK`-only responses, traffic on all four initial workers, replacement of both original Pods, nonzero ready endpoints in every sample, and successful removal of the owned cluster. Failed jobs preserve available logs and Pod diagnostics; [check_kind_failure.rb](../../bench/check_kind_failure.rb) checks failed-Job capture and preservation of already saved raw evidence.

These observations cover this unary workload and sampled endpoint state. They do not establish every streaming workload, production network, or admission policy. See the [Kubernetes guide](../guides/kubernetes.md) for probe, shutdown and unsafe-sysctl requirements; [T3-01](T3-01-phased-restart.md) separately records process-level phased replacement and its native shutdown compatibility limit.

## Reproduce

Check out matching core/native revisions side by side, install Docker with BuildKit, kind, kubectl and a Linux ghz executable, then run:

```sh
ruby bench/kind_rollout.rb --ghz /path/to/linux/ghz --core ../gritz-core --output tmp/kind-rollout.json
```

The driver builds local sources, creates a unique cluster and private kubeconfig, runs the load job and rollout, and removes only its own cluster on success or failure. A verified prebuilt image can be used with `--skip-build --image IMAGE`; `--node-image IMAGE` permits a verified cached node image.
