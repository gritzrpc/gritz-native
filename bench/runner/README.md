# Benchmark runner

The registered repository runner is `gritz-benchmark-arm64`, label `colima-arm64-2cpu-1g`. Its container is `gritz-benchmark-runner`. It has two CPUs, 1GiB RAM, an isolated Docker network and no mounted host socket or workspace. The Runner distribution and ghz are pinned; `Dockerfile` pins Ruby by image digest.

Docker volumes `gritz-benchmark-runner` and `gritz-benchmark-baselines` retain runner registration and reviewed baseline JSON respectively. Registration credentials stay inside the first volume. Do not publish that volume or commit its contents.

```sh
docker start gritz-benchmark-runner
docker stop gritz-benchmark-runner
docker logs --tail 20 gritz-benchmark-runner
gh api repos/gritzrpc/gritz-native/actions/runners
gh workflow run performance.yml --repo gritzrpc/gritz-native -f initialize_baseline=true
gh workflow run performance.yml --repo gritzrpc/gritz-native -f scenario=unary-light
```

Initialization creates missing baselines; it still compares any baseline that already exists. Normal runs and nightly runs require every selected baseline. Retain and review the uploaded artifacts before copying results into `bench/results`. Stop other Colima workloads while measuring, with the workload owner's permission, and restore their previous state afterward. When the host sleeps or Docker is stopped, the runner is offline; the `unless-stopped` policy resumes it when Docker restarts unless it was explicitly stopped.

This Colima VM also serves other projects. Scheduled measurements are therefore disabled unless repository variable `BENCH_RUNNER_ISOLATED` is `true`. Leave it unset for this runner. Enable it only after moving measurements to an otherwise idle, dedicated VM or machine; manual dispatches still work after competing workloads are stopped. The workflow cannot stop unrelated containers because it has no host Docker socket.

On macOS, keep the host awake for manual full runs with `caffeinate -i -t 3600` in another terminal. Host suspension invalidates an active measurement and may prevent artifact upload. The first collection failed after idle sleep with two deadline errors; its failed JSON is retained in `bench/results/2026-10-03-native-cpu-host-sleep.json`. Collect a complete run with no suspension before accepting a baseline.

To rebuild, create an ignored build directory containing `actions-runner-linux-arm64-2.337.0.tar.gz`, executable `ghz` and a trusted public certificate bundle `ca.pem`. Verify the Runner archive against SHA256 `9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393` and ghz using the manifest handled by `.devcontainer/install-tools.sh`. The build command used here is:

```sh
docker build -t gritz-benchmark-runner:local -f bench/runner/Dockerfile tmp/runner-build
```

For a fresh registration, start a setup container with the runner and baseline volumes mounted at `/opt/actions-runner` and `/opt/gritz-baselines`, using `--entrypoint sleep ... infinity`. `ruby bench/runner/register.rb SETUP_CONTAINER` obtains a short-lived token through the authenticated host `gh` and sends it over stdin to the container. It never writes the token to the workspace. Stop the setup container before starting the runtime container with the same volumes, `--restart unless-stopped --cpus 2 --memory 1g`. `CAP_NET_ADMIN` is needed only for executing the isolated chaos scenarios. Preserve the same image and resource limits for baseline comparisons.
