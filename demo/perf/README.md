# Performance analysis — extended kubelet config + CEL

Lives under `demo/`, so it's covered by the existing `demo/` line in
`.git/info/exclude` and never lands in the `extended_kubelet_config` PR. Verified:
`go build ./...`, `go vet ./demo/...`, `golangci-lint run ./demo/...` (0 issues),
and `go mod tidy` leaves `go.mod`/`go.sum` unchanged.

Cluster: `karpenter-cel-demo` (us-west-2, account 000000000000)

---

## The headline, up front

The benchmarks already ran. **On an M4 Pro, one full re-resolve of an
unconstrained NodePool — ~800 instance types × 6 expressions — costs 2.36 ms of
CPU and 1.82 MB of transient garbage.**

At `churn.sh`'s default of one cache-busting change every 5 s, that is **0.047% of
one core.** A Prometheus panel on a 30-second scrape cannot see that, and neither
can a 180-second CPU profile of a controller that is otherwise idle.

That is the single most important thing to know before you start, because it
determines the order of the workflow below: **the benchmarks are the measurement,
and Grafana/pprof are the confirmation that nothing pathological happens in situ.**
Doing it the other way around produces a flat graph and no conclusion.

Baseline, `-count=6`, saved in `captures/baseline-bench.txt`:

| benchmark | ns/op | B/op | allocs/op | what it is |
|---|---|---|---|---|
| `EvaluateWarm` | 448 | 364 | 4 | one eval, compile cache hot — the steady state |
| `EvaluateCold` | 66,200 | 54,216 | 693 | one eval incl. compile — **148× warm** |
| `ResolveFleet` | 2,360,000 | 1,823,450 | 30,646 | 800 types × 6 exprs = one re-resolve |
| `ResolveResourceMap` | 1,547,000 | 1,210,800 | 20,430 | 800 × 3 keys through the real entry point |
| `ResolveResourceMapStatic` | 257,000 | 268,800 | 1,600 | same shape, static quantities — **the control** |
| `NewEnvironment` | 6,760 | 8,128 | 122 | process startup, once per controller |

Variance across the 6 runs was under 2% on every line except
`ResolveResourceMap`, which produced one 13% outlier — worth a `-count=10` and
`benchstat` before quoting that row as a regression threshold.

**Three readings worth having ready for a reviewer:**

1. **Marginal cost of expressions over static values** is the question you'll
   actually be asked. `ResolveResourceMap − ResolveResourceMapStatic` =
   **1.29 ms and ~920 KB per fleet re-resolve** for three resource keys. Everything
   else in the feature — the open-map strict decode,
   `validateKubeletFieldsSupported`, `validateKubeletSemantics` — is in both
   numbers and cancels out.
2. **The compile cache is carrying the feature.** 445 ns warm vs 65.7 µs cold. It's
   a TTL cache (`compiledExpressionTTL` in `pkg/cel/environment.go`), and
   `compileCached` refreshes the TTL on read, so an actively-reconciled NodeClass
   stays warm. A NodeClass reconciled *less often than the TTL* pays 65.7 µs per
   expression instead of 445 ns. That's still not much, but it is the one cliff in
   the design and it's worth being able to say so out loud.
3. **Allocation rate is the visible signal, not CPU and not RSS.** 1.82 MB per
   re-resolve at one re-resolve per 5 s is ~365 KB/s of garbage — that *does* show
   up on the dashboard's *Go allocation rate* panel while CPU and working-set stay
   flat, because the garbage is collected promptly. If you want one on-cluster graph
   that demonstrates the code is doing work, that's the one.

`EvaluateExpression` allocating 4 times per call is the activation map — it rebuilds
a 6-entry `map[string]any` on every evaluation. At 800 × 6 that's the bulk of the
30,646 allocs. Not a problem at this scale; it is the obvious thing to point at if
anyone asks where the allocations go.

---

## Run order

```bash
# 0. Credentials. These have expired mid-session before -- see demo/README.md.
aws sts get-caller-identity

# 1. Benchmarks. No cluster needed. This is the actual measurement.
go test ./demo/perf/ -run '^$' -bench . -benchmem -count=6 | tee demo/perf/captures/bench-$(date +%Y%m%d).txt

# 2. Monitoring stack + ServiceMonitor. ~5-10 min, mostly Prometheus starting.
./demo/perf/setup-monitoring.sh --dry-run
./demo/perf/setup-monitoring.sh

# 3. Turn on pprof. Restarts both replicas.
./demo/perf/enable-profiling.sh

# 4. Load fixture. Applying it launches nothing (deployment is replicas: 0).
kubectl apply -f demo/perf/load.yaml

# 5. Watch. Terminal A drives load, terminal B collects.
./demo/perf/churn.sh 5                    # A: one full re-resolve every 5s
./demo/perf/profile.sh cpu 180            # B: 180s CPU profile of the LEADER
./demo/perf/profile.sh heap
./demo/perf/profile.sh top allocs         # text output instead of the browser

# 6. Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# then import demo/perf/dashboard.json  (Dashboards > New > Import)

# Teardown
kubectl delete -f demo/perf/load.yaml
./demo/perf/enable-profiling.sh --off
helm uninstall kube-prometheus-stack -n monitoring
```

---

## Where the guide will mislead you on this chart

Four of these cost real time to discover, which is why they're scripted rather than
written down as warnings.

**1. `port-forward deployment/karpenter` is a coin flip.**
`charts/karpenter/values.yaml` sets `replicas: 2` and leader election is on, so only
one pod reconciles anything. `port-forward deployment/...` picks an arbitrary ready
pod. Profile the standby and you get a flat, idle profile that reads exactly like
"my change is free" — the most expensive possible wrong answer.
`profile.sh` resolves the leader from the `karpenter-leader-election` lease
(`holderIdentity` is `<pod-name>_<uuid>`) and forwards to that pod by name.
Note that `enable-profiling.sh` restarts both replicas, so the leader after it runs
is probably not the leader before.

**2. `ENABLE_PROFILING` has no chart value.** `grep -rn PROFILING charts/` is empty.
It's a karpenter-core option (`pkg/operator/operator.go` gates the pprof handlers on
`options.FromContext(ctx).EnableProfiling`), reachable only through
`controller.env` — which is a *list*, so `--set controller.env[0].name=...`
overwrites whatever is at index 0. `enable-profiling.sh` reads the release's current
env first and refuses to clobber anything it didn't set.

**3. Port 8080 is right by luck.** pprof is registered as an `ExtraHandler` on the
*metrics* listener, so it lands on `controller.metrics.port` — 8080 in this chart,
which matches the guide. `profile.sh` reads `METRICS_PORT` off the deployment rather
than assuming.

**4. `rate(...[30s])` renders as gaps.** The scrape interval is 30 s; a `[30s]`
range holds one sample and `rate()` needs two. `dashboard.json` uses `[2m]`
throughout — four samples per point. This is the one place where following the guide
verbatim produces a chart that looks broken rather than a chart that lies.

One thing the guide implies that isn't true: the ServiceMonitor is **not** needed for
the CPU/memory panels. Those come from cAdvisor, which kube-prometheus-stack already
scrapes off every kubelet. The ServiceMonitor gets you `go_memstats_*`,
`go_goroutines`, and `controller_runtime_reconcile_time_seconds` — which, per the
allocation-rate point above, is where the actual signal is.

---

## Why `demo/02-cel-scaling.yaml` is the wrong load fixture

Its NodePools pin `node.kubernetes.io/instance-type` to exactly one value each
(`m5.large`, `m5.xlarge`). Correct for the demo — it makes per-instance-type
resolution legible — but it suppresses precisely the cost you're measuring. CEL runs
once per expression per instance type in
`instancetype.(*DefaultResolver).Resolve`, so a 1-instance-type NodePool does 3
evaluations where an unconstrained one does ~4,800.

`load.yaml` therefore has no instance-type requirement, six expressions, and a
`perf-static` twin with identical structure and zero expressions — the on-cluster
equivalent of the `ResolveResourceMapStatic` control.

**Annotation bumps don't work as churn.** `instancetype.(*Provider).cacheKey` folds
in `DefaultResolver.CacheKey(nodeClass)`, which hashes the kubelet block, so an
unchanged EC2NodeClass is a cache *hit* and `Resolve()` never re-runs. Only a change
to the kubelet config busts it. `churn.sh` alternates two semantically identical
strings:

```
max(60, vcpus * 30)   <->   max(60, vcpus * 30 + 0)
```

Different string → different `kcHash` → cache miss → full re-resolve, with the same
resolved value every time so nothing about the cluster's real configuration drifts.
Two strings alternating also bounds the compilation cache at two extra entries —
don't "improve" this with a counter in the expression unless growing that cache is
what you want to measure.

---

## Comparing before and after

The reason to keep `captures/`. Both directions work:

```bash
# Benchmarks: needs golang.org/x/perf/cmd/benchstat
go test ./demo/perf/ -run '^$' -bench . -benchmem -count=10 > new.txt
git stash && go test ./demo/perf/ -run '^$' -bench . -benchmem -count=10 > old.txt && git stash pop
benchstat old.txt new.txt

# Profiles: positive numbers mean the second one spends more
./demo/perf/profile.sh diff captures/heap-<older>.pb.gz captures/heap-<newer>.pb.gz
```

Profiling the *benchmark* is sharper than profiling the live controller, because
there's no watch traffic or scheduling loop in the way:

```bash
go test ./demo/perf/ -run '^$' -bench ResolveFleet -cpuprofile cpu.out -memprofile mem.out
go tool pprof -http 0.0.0.0:9000 cpu.out
```

Symbols to look for, in `cum` order:

- `pkg/cel.(*CELEnvironment).EvaluateExpression`
- `pkg/cel.(*CELEnvironment).compileCached` — should be near-zero warm; if it isn't,
  the TTL cache is missing and that's a finding
- `github.com/google/cel-go/interpreter.*`
- `pkg/providers/instancetype.(*DefaultResolver).Resolve`
- `k8s.io/apimachinery/pkg/api/resource.ParseQuantity` — called on every value
  before CEL as the static short-circuit, so it runs on expression strings too and
  fails; visible in the static control as well

---

## Files

| | |
|---|---|
| `cel_bench_test.go` | the actual measurement; part of the root module, no nested `go.mod` |
| `setup-monitoring.sh` | kube-prometheus-stack + ServiceMonitor; `--dry-run` supported |
| `servicemonitor.yaml` | scrapes Karpenter's own `/metrics` |
| `enable-profiling.sh` | `ENABLE_PROFILING` via `controller.env`; `--off` to revert |
| `profile.sh` | leader-aware pprof capture; `heap`/`cpu`/`allocs`/`top`/`diff` |
| `load.yaml` | unconstrained `perf-cel` + `perf-static` control |
| `churn.sh` | cache-busting expression flips |
| `dashboard.json` | importable Grafana dashboard, `[2m]` rate windows |
| `captures/` | benchmark baselines and saved profiles |
