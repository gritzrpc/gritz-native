# Kubernetes operations

Run one Gritz launcher per Pod. The launcher owns the admin listener and supervises the serving generation; its workers own gRPC resources. Use Linux for multiple native workers.

The [example Deployment](../../examples/kubernetes/deployment.yml) uses two replicas with two workers each, one extra Pod during rolling updates, and no unavailable replicas. Bind the admin listener to `0.0.0.0:9090` so kubelet HTTP probes can reach it. The application Service exposes only gRPC port 50051.

Set `enableServiceLinks: false` and use Service DNS names. Otherwise a Service named `gritz` injects variables such as `GRITZ_SERVICE_HOST`, which the strict configuration parser rejects as unknown settings.

## Readiness and shutdown

Use `/livez` for liveness and `/readyz` for readiness. A failed application dependency should make readiness fail without restarting an otherwise healthy process. The startup probe allows boot time before liveness begins. These HTTP probes also work when the application's gRPC listener requires TLS or client certificates. See the [Kubernetes probe documentation](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/).

```ruby
admin_bind "0.0.0.0:9090"
workers 2
min_ready_workers 2
drain_delay 5.0
shutdown_timeout 25.0
health_check(:database) { database_connected? }
```

Health callbacks run at the configured `status_interval`. Keep them bounded and free of side effects. `/status` reports each worker's `healthy` value and named `checks`. The standard `grpc.health.v1.Health` service exposes both `Check` and `Watch`, for the global service `""` and each registered application service. Unknown `Check` requests return `NOT_FOUND`; unknown `Watch` requests report `SERVICE_UNKNOWN`. Draining reports `NOT_SERVING` and closes existing health watches. Each open Watch occupies one native pool thread, so account for health clients when setting `threads`. The protocol is defined in the [gRPC health specification](https://github.com/grpc/grpc-proto/blob/master/grpc/health/v1/health.proto).

Give `terminationGracePeriodSeconds` more time than `drain_delay + shutdown_timeout`. The example uses 40 seconds for a 30-second Gritz drain budget. On `TERM`, readiness fails immediately, workers allow the drain delay for endpoint removal, and then stop accepting RPCs while finishing in-flight work. Kubernetes updates terminating Service endpoints in parallel with Pod shutdown; see the [Pod termination flow](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination-flow). A preStop sleep is unnecessary with this configuration.

## Reuseport and replacement

For Linux reuseport listeners, enable `net.ipv4.tcp_migrate_req=1` in the Pod network namespace to preserve pending TCP requests when a worker's listener closes. This setting requires a supporting Linux kernel and the kubelet's `allowedUnsafeSysctls` allowlist. The [kind configuration](../../examples/kubernetes/kind.yml) includes the allowlist, and the Deployment sets the Pod sysctl. Do not use host networking for this example. See [Kubernetes sysctl configuration](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/).

The namespace's admission policy must also permit this sysctl. It is outside the allowlist in the Baseline and Restricted [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/); enabling it in kubelet alone does not grant permission to a Pod.

`USR1` replaces workers one at a time: boot a healthy replacement, mark the previous worker draining, then stop and reap it before proceeding. A fixed gRPC bind port is required. `USR2` starts a fresh Ruby interpreter with the startup command, reloading application code and configuration; the launcher keeps serving the previous generation if replacement startup fails. Signal the launcher PID. `/status` exposes replacement progress and retired worker rows while they are still owned.

Worker recycling uses the same replacement procedure:

```ruby
worker_recycle max_requests: 100_000, max_pss_mb: 512, max_lifetime: 3600, jitter: 0.1
```

The default connection age is 300 seconds with a 30-second grace period. These limits bound the lifetime of HTTP/2 connections and help distribute reconnects across workers.

## TLS and client certificates

Mount certificate files from a Secret and configure their paths:

```ruby
tls cert: "/run/gritz-tls/server.pem", key: "/run/gritz-tls/server.key"
# To require authenticated clients:
tls cert: "/run/gritz-tls/server.pem", key: "/run/gritz-tls/server.key", client_ca: "/run/gritz-tls/client-ca.pem"
```

Workers read credentials when binding their listener. After updating mounted certificates, replace workers with `USR1` or roll the Deployment. With mTLS, `context.peer_identity` contains the client's PEM certificate. Parse the certificate and apply application authorization rules to its validated identity.

## Reproduce the release gates

The tests build from local `gritz-core` and `gritz-native` sources, so check out matching revisions side by side. Install the native development bundle and a Linux `ghz` binary.

```sh
bundle exec ruby bench/phased_restart.rb --ghz /path/to/ghz --output tmp/phased-restart.json
ruby bench/kind_rollout.rb --ghz /path/to/linux/ghz --core ../gritz-core --output tmp/kind-rollout.json
```

The kind driver builds the [Dockerfile](../../examples/kubernetes/Dockerfile), creates a uniquely named cluster with a private kubeconfig, loads the image, and runs 90 seconds of ghz traffic from inside the cluster. It observes RPCs on all four original workers, changes the application revision to trigger a rolling update, samples ready endpoints, and verifies all original Pods were replaced. It removes its cluster on success or failure and records raw ghz JSON alongside the result. It does not change an existing Kubernetes context.

Both gates require completed RPCs and zero reported errors. They use ghz's `--duration-stop=wait` so reaching the load duration does not cancel outstanding calls; see [ghz options](https://ghz.sh/docs/options). The kind gate additionally requires at least one ready endpoint throughout sampled rollout progress. A failed result remains a failed gate; inspect the raw error distribution and Pod diagnostics before recording a release result.
