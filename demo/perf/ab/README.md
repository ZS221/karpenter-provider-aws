# Three-arm A/B: extended kubelet config + CEL

Cluster: **`blah`** (us-west-2, 000000000000) — deliberately not `karpenter-cel-demo`,
so nothing here touches the demo fixtures.

Git-excluded via the existing `demo/` line in `.git/info/exclude`.

---

## The arms

`pkg/cel/environment.go` landed at `6e13b3e0a` — *"feat: CEL expression support for
maxPodsExpression, kubeReserved, and systemReserved (#9326)"* — which is on `origin/main`
**and** is `extended_kubelet_config`'s merge-base. So `main` is *not* a
"before my changes" baseline; it already has CEL.

| arm | ref | CEL | extended open-map kubelet |
|---|---|---|---|
| **V0** | `6e13b3e0a^` | ✗ | ✗ |
| **V1** | `origin/main` | ✓ | ✗ |
| **V2** | `extended_kubelet_config` | ✓ | ✓ |

There are **zero commits touching `pkg/`, `cmd/` or `charts/` between `6e13b3e0a` and
current `origin/main`** — all the drift is website and dependency bumps. So V0→V1 is a
one-commit delta and V1→V2 is 31 commits, all yours. Two clean attributions instead of one
lumped number.

**The one confounder, neutralised.** `dda4e98d2` (*perf: precompute offering cache keys,
#9411*) is in V2 but **not** in `origin/main`. It is a performance change on the offering
path, which this load hammers — left alone it would make V2 look faster for reasons that
are not your feature. V0 and V1 each get it cherry-picked on top (verified clean on both).

All three are built from source with the same Go toolchain, same `ko`, same base image.
Pulling `public.ecr.aws/karpenter/controller:1.14.0` for the baseline would have introduced
a toolchain difference easily as large as the effect being measured.

## The cells

The arms do not accept the same manifests — V0's `spec.kubelet` is a closed struct with 12
fields and an int-only `maxPods`; V2's is an open map. So:

| cell | kubelet block | V0 | V1 | V2 |
|---|---|:-:|:-:|:-:|
| `static` | all 12 legacy fields, static values | ✓ | ✓ | ✓ |
| `cel` | same 12, CEL on maxPods/kubeReserved/systemReserved | — | ✓ | ✓ |
| `extended` | `cel` + 8 previously-inexpressible fields | — | — | ✓ |

Five measurable cells. `static` is the only true like-for-like across all three arms, and
it is the one that answers the question a maintainer will actually ask: **did you slow down
the path everyone already uses?** `inputs/render.sh` generates all three from one source so
the instance-type spread, NodePool shape, workload sizing and limits are provably identical
— `diff` of any two renders shows only the kubelet block and the cell name.

## The load

`run-cell.sh` runs two phases per cell, measuring different code:

- **Phase A — provisioning bursts.** 12 pinned NodePools → 12 real nodes across 12 distinct
  instance types (t3/c5/c6i/m5/m6i/r5/r6i, 2–8 vCPU, 4–32 GiB). Scale up, wait for Ready,
  hold, scale to 0, repeat ×3. Exercises instance-type resolution, launch-template
  rendering, UserData generation, CreateFleet — where the *extended config* costs something,
  since its output is bytes in UserData.
- **Phase B — reconcile churn.** Cache-busting kubelet edits every 5 s for 10 min, no
  launches. Each edit invalidates `DefaultResolver.CacheKey` and forces a full re-resolve
  across the fleet — where *CEL* costs something.

Each pinned NodePool has `limits.cpu` set to exactly its instance type's vCPU count, so
precisely one node can launch per pool. Node count per burst is deterministic (12), not
dependent on bin-packing, and a runaway is capped at 36 vCPU total.

A 13th **`fleetwide` NodePool with `limits.cpu: 0`** launches nothing and exists only to
widen resolution: `getPrioritizedInstanceTypes` unions instance types across every NodePool
pointing at the NodeClass, so without it CEL would be evaluated against 12 types per
reconcile instead of the full ~800. That is where the cost lives, and it costs nothing to
include.

Consolidation is **off** during measurement (`WhenEmpty`, `consolidateAfter: 1h`) so the
bursts are the only source of launch events.

---

## Run order

```bash
cd demo/perf/ab

./setup-monitoring.sh          # once. 10s scrape interval, 15d retention.
./build-arms.sh                # three ko builds -> arms.env

# V1 first, to shake out the harness on the arm that can run 2 of the 3 cells
./deploy-arm.sh v1
./run-cell.sh   v1 static
./run-cell.sh   v1 cel

./deploy-arm.sh v2
./run-cell.sh   v2 static
./run-cell.sh   v2 cel
./run-cell.sh   v2 extended

./deploy-arm.sh v0
./run-cell.sh   v0 static

./build-arms.sh --clean        # when done: removes the /tmp worktrees
```

`deploy-arm.sh` sleeps 180 s after rollout on purpose — Karpenter hydrates its
instance-type, offering, AMI and pricing caches at startup, and that hydration is
CPU-expensive and unrelated to the feature. Measuring through it would bury the signal.

Order matters within an arm but not across arms; each `run-cell.sh` isolates its own cell
by deleting the other two cells' objects first, because a CEL NodeClass sitting idle in the
background inflates exactly the metrics under test.

## Cluster gotchas found the hard way

**`gp2` is a dead StorageClass.** It is backed by the in-tree `kubernetes.io/aws-ebs`
provisioner, which Kubernetes removed in 1.27; `blah` is 1.36 and has no
`aws-ebs-csi-driver` addon (`coredns`, `eks-pod-identity-agent`, `kube-proxy`, `vpc-cni`
only). Any PVC here stays Pending forever — the first version of `setup-monitoring.sh`
asked for a 20Gi Prometheus volume and would have hung. Prometheus runs on `emptyDir`
instead, and `export-window.sh` dumps each cell to local disk right after it finishes so a
Prometheus restart costs one cell rather than the whole experiment.

**The CPU limit was going to hide the result.** The cluster's existing release pinned the
controller at `limits.cpu: 1`. A CPU limit is a ceiling, and a ceiling the load can reach
destroys the measurement: if V2 wants more CPU than the limit allows, CFS throttles it and
*both* arms read as exactly 1.0 cores. `deploy-arm.sh` uses `limits.cpu: 1500m` with
`requests.cpu: 1` (still schedulable on a 1930m-allocatable m5.large) and every export
records `container_cpu_cfs_throttled_seconds_total`, so "we were not throttled" is backed
by data. `export.py` prints a warning and marks the phase invalid if throttling exceeds 1s.

**`ko` cannot build from a git worktree unmodified.** `cmd/controller/kodata/HEAD` and
`kodata/refs` are symlinks to `../../../.git/HEAD` and `../../../.git/refs`. In a worktree
`.git` is a *file* holding a gitdir pointer, not a directory, so ko dies with
`EvalSymlinks(.../kodata/HEAD): not a directory`. `build-arms.sh` dereferences both — HEAD
from `git rev-parse --git-dir`, refs from `--git-common-dir` (a worktree has no `refs/` of
its own) — and commits the result so ko does not also warn about a dirty tree.

**PromQL in Python f-strings is a trap.** Every literal brace has to be doubled and the
doubling is not eyeballable; the first `export.py` had a stray `}` in four queries. Queries
now use `$POD`/`$JOB`/`$WINDOW` placeholders and one `expand()` pass, and there is a check
that renders all 27 and asserts balanced braces with no leftover placeholders.

## Credentials will expire mid-experiment

This is the single biggest practical risk. The session's credentials have already expired
twice in a few hours, and a cell is a ~25 minute uninterrupted window: `run-cell.sh` checks
credentials at the start but cannot survive an expiry at minute 12, and a half-recorded
window is not salvageable — you re-run the cell.

Every script fails fast with a clear message rather than producing a partial record.

`ada credentials update --once --account 000000000000 --role Admin --profile default`
refreshes non-interactively and takes about a second, so the practical fix is to run it
before every cell. `keep-creds-fresh.sh` wraps that in a 10-minute loop if you want it
unattended — **start it yourself**; it holds Admin credentials continuously live, which is
not something a tool should switch on for you, and it cuts against the least-privilege
default in your global CLAUDE.md. If `ada` starts failing, run `mwinit` (the RSA cert in
this session was already expired; the ECDSA one still worked) — that part is interactive.

## Cost

Phase A holds 12 on-demand nodes (~$1.74/hr for the whole spread) for roughly 4–5 minutes
per burst × 3 bursts per cell. Across all five cells that is well under an hour of node
time — call it **$2–4 plus EBS**. Phase B launches nothing.

`limits.cpu` on every pool means a bug cannot run away: the ceiling is 36 vCPU.

## Files

| | |
|---|---|
| `config.sh` | cluster, arms, per-arm cell eligibility; sourced by everything |
| `build-arms.sh` | worktree + cherry-pick + `ko build` per arm → `arms.env` |
| `deploy-arm.sh` | ordered teardown, CRD swap, chart+image deploy, settle |
| `inputs/render.sh` | generates all three cells from one definition |
| `run-cell.sh` | Phase A bursts + Phase B churn, writes `runs/*.json` |
| `setup-monitoring.sh` | kube-prometheus-stack at 10s scrape |
| `runs/` | one JSON record per (arm, cell) with phase timestamps |
| `captures/` | heap/allocs/goroutine profiles per cell |

## Not built yet

`collect.sh` / the report. Deliberately deferred: the exact metric names should be read off
a live `/metrics` scrape rather than guessed from karpenter-core source, and that needs one
arm actually running. The run records in `runs/` carry precise phase-boundary timestamps, so
collection is a pure post-processing step that can happen any time after the runs — nothing
is lost by writing it later.

Confirmed metric names so far (karpenter-core v1.14.0, `Namespace = "karpenter"`):
`karpenter_pods_provisioning_startup_duration_seconds`,
`karpenter_pods_provisioning_bound_duration_seconds`,
`karpenter_nodeclaims_{created,terminated,disrupted}_total`,
`karpenter_nodeclaims_termination_duration_seconds`,
`karpenter_cloudprovider_duration_seconds`, `karpenter_cloudprovider_errors_total`,
`karpenter_nodes_allocatable`, `karpenter_cluster_utilization_percent`, plus
`controller_runtime_reconcile_{total,time_seconds_bucket}` and `go_memstats_*`.

Plan is window integrals (`increase()` over each phase) rather than instantaneous rates —
total CPU-seconds and total bytes allocated per phase are single low-variance numbers per
cell, which compare far better across arms than a wobbly `rate()` line.
