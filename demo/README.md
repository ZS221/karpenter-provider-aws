# Extended Kubelet Configuration + CEL — demo kit

Lives in the repo at `demo/`. It is committed **only** on the `final_demo`
branch, which exists purely to archive this kit — it is never merged, so nothing
here lands in the `extended_kubelet_config` or CEL PRs.

It deliberately has **no `go.mod`**. `make verify` derives `MOD_DIRS` by finding
every nested `go.mod` and running `golangci-lint` + `go mod tidy` inside each one,
so a nested module here would interfere with the repo's own checks. As a plain
package `demo/preflight` only has to compile and lint cleanly — verified:
`go build ./...`, `go vet ./demo/...`, `golangci-lint run ./demo/...` all pass, and
`go mod tidy` leaves `go.mod`/`go.sum` unchanged.

Cluster: `karpenter-cel-demo` (us-west-2, account 000000000000)

**Account and cluster identifiers are placeholders.** This branch is pushed to a
public fork, so the real values were scrubbed. The scripts read them from the
environment, so point them at a real cluster without editing any file:

```bash
export ACCOUNT=<your-account-id>
export CLUSTER=<your-cluster-name>     # churn.sh uses NS_CONTEXT_CLUSTER
export REGION=us-west-2
```

The YAML manifests can't be templated the same way — `spec.role`
(`KarpenterNodeRole-karpenter-cel-demo`) and the `karpenter.sh/discovery` subnet
and security-group selectors still carry the placeholder cluster name, so
`sed -i '' 's/karpenter-cel-demo/<your-cluster>/g' demo/*.yaml demo/perf/load.yaml`
before applying them. `demo/perf/ab/kubeconfig` is not committed; `ensure_kubeconfig()`
in `demo/perf/ab/config.sh` regenerates it from `~/.kube/config` on first use.

---

## Run order

The scripts `cd` to their own directory, so they work from anywhere. The preflight
is a Go package, so run that one from the repo root.

```bash
# 0. Confirm credentials
aws sts get-caller-identity

# 1. Sanity-check the manifests with no cluster at all   (from repo root)
go run ./demo/preflight demo/01-extended.yaml demo/02-cel-scaling.yaml \
                        demo/03-invalid.yaml demo/04-unsupported.yaml

# 2. See what redeploy would do, without doing it
./demo/redeploy.sh --dry-run

# 3. Build HEAD, patch the cel-* NodeClasses, deploy the controller
./demo/redeploy.sh

# 4. REHEARSE -- tonight. This is a full real run: it applies every manifest and
#    launches the nodes. NO_PAUSE skips the "press Enter" prompts so it runs
#    unattended; tee writes down what scrolls past.
NO_PAUSE=1 ./demo/demo.sh 2>&1 | tee demo/capture/full-run.txt

# 5. PRESENT -- same script, interactive. Everything from step 4 already exists,
#    so beat 2's node wait returns instantly instead of taking 2-4 minutes.
./demo/demo.sh          # all four beats
./demo/demo.sh 2        # just the headline beat
./demo/demo.sh 3 4      # just the validation beats (fast, launches nothing)

# Rehearse WITH the speaker notes on screen. Never use this while presenting.
SPEAKER_NOTES=1 ./demo/demo.sh 1
```

**Speaker notes are suppressed by default.** Beat 1 carries presenter-facing prose — a
"Say this part out loud" script plus caveats about not overstating the evictionHard
effect — and it is gated behind `SPEAKER_NOTES=1` so it cannot reach the projector.
Everything else the script prints is written for the audience to read, including the
`note` lines, so nothing else needed hiding. The `> Talking point:` lines further down
this README are prep material and never render on screen.

Steps 4 and 5 are **the same command**. The only differences are `NO_PAUSE=1`
(unattended vs. paused for narration) and `tee` (recorded vs. not).

Step 4 is not optional-because-cosmetic — it is the first time any of this touches
a real cluster. It exists to answer three questions tonight rather than on stage:

1. **Does it work at all?** Every number in the beat-2 table below was derived from
   reading the code, not observed. Notably, whether `m5.xlarge` launches in this
   cluster is unverified — every pre-existing NodeClaim here is `m5.large`.
2. **Are the nodes warm?** Beat 2's 2-4 minute node wait is the biggest chunk of
   dead air in the demo. Running step 4 removes it from the live run.
3. **Do you have a fallback?** These credentials already expired once, mid-session,
   unprompted. `demo.sh` fails fast with a clear message if that happens again, but
   a clear error message is not a demo. `capture/full-run.txt` is.

Skipping straight from 3 to 5 works fine — step 5 applies everything itself. You
just do the applying and the waiting live, with no rehearsal and no fallback.

Trade-off worth knowing: pre-warming means step 5 shows already-provisioned state
rather than provisioning happening live. If you want the audience to watch nodes
appear, skip step 4 and accept the wait.

Teardown: `./demo/cleanup.sh demo` (or `stale` / `all`). Both modes print what
they'd delete and require typing `yes`.

---

## Read this before you present

**The deployed controller is stale.** The running image is from ~Aug 11 and
predates commit `64651f57f` (Aug 12), which added `validateKubeletFieldsSupported`.
Three of your existing fixtures — `cel-al2`, `cel-bottlerocket`, `cel-windows` —
carry `registryBurst` and `serializeImagePulls`, unmanaged fields that only AL2023
passes through. They show `Ready=True` right now **only because the controller
can't yet see the problem.** Redeploy HEAD and all three go
`ValidationSucceeded=False`.

That's the feature working. But mid-demo it reads as a regression, so
`fix-fixtures.sh` patches those three surgically (removing only the offending
keys) and `redeploy.sh` runs it before the Helm upgrade. The deliberate
"this-would-be-silently-dropped" demo lives on its own `demo-4*` NodeClasses.

**`cel-bad` should stay red.** It holds `maxPods: "min(110,"` and is your existing
negative fixture. If someone asks why one NodeClass is False in
`kubectl get ec2nodeclasses`, that's the answer.

---

## The four beats

### 1 — Extended kubelet configuration (`01-extended.yaml`)

`spec.kubelet` was a closed struct with ~11 hardcoded fields; it's now an open map
strict-decoded against `k8s.io/kubelet` v0.36.3. The manifest sets 15 fields, 8 of
which were previously inexpressible: `containerLogMaxSize`, `containerLogMaxFiles`,
`podPidsLimit`, `registryBurst`, `registryPullQPS`, `serializeImagePulls`,
`maxParallelImagePulls`, `topologyManagerPolicy`.

The strongest evidence is the UserData step — it greps the rendered launch
template for those field names, proving pass-through rather than silent drop. It
needs a launch template to exist, so run it after beat 2 if it comes up empty.

> Talking point: adding a newly-released kubelet field is now a `go.mod` bump, not
> an API change.

### 2 — CEL resolved per instance type (`02-cel-scaling.yaml`) ← the headline

One NodeClass, one expression, two NodePools pinned to different sizes:

| | m5.large (2 vCPU) | m5.xlarge (4 vCPU) |
|---|---|---|
| `maxPods: "vcpus * 8"` | 16 | 32 |
| `kubeReserved.cpu: "max(60, vcpus * 30)"` | 60m | 120m |
| `kubeReserved.memory: "memory_mib / 100"` | 96Mi | 176Mi |
| `systemReserved.cpu: "max(20, vcpus * 10)"` | 20m | 40m |
| `systemReserved.memory: "memory_mib / 200"` | 48Mi | 96Mi |

Every value above was resolved by the branch's own CEL code, not worked out by hand, and
the `kubeReserved` row matches `capture/full-run.txt`. Memory rounds **up** to the next
16Mi and cpu up to the next 10m, which is why `8192/100 = 81.92` lands on 96Mi rather
than 80Mi — and why the `/100` and `/200` results are not a tidy 2:1 on m5.xlarge
(163 → 176Mi, 81 → 96Mi, rounded independently).

Variables: `vcpus`, `memory_mib`, `default_enis`, `ips_per_eni`, `max_pods`,
`instance_type`. Functions: `min()`, `max()`.

This is the slow beat (~2–4 min for both nodes). Pre-warm it or lean on
`capture/full-run.txt`.

> Talking point: `max_pods` as an *input* variable is the interesting one — you can
> write `min(110, max_pods)` to cap Karpenter's own ENI-derived calculation.

### 3 — Invalid config never reaches a node (`03-invalid.yaml`)

Four failure classes, four distinct condition reasons, zero NodeClaims:

| | what | reason |
|---|---|---|
| 3a | `maxPods: "min(110,"` | `KubeletExpressionInvalid` |
| 3b | `"1048576 / (vcpus - vcpus)"` | `KubeletExpressionEvaluationFailed` |
| 3c | `registryBurstt: 20` (typo) | `InvalidKubeletConfiguration` |
| 3d | 4 semantic violations at once | `InvalidKubeletConfiguration` |

**3b is the one worth dwelling on.** It compiles fine — a compile-only check
passes it. It's only caught by evaluating against every instance type in the
cache. The offline `preflight` tool reports 3b as ACCEPT for exactly this reason,
which makes it a nice live illustration if you want one.

3c matters because the API server *cannot* catch it: the field is an open map with
`x-kubernetes-preserve-unknown-fields`, so a typo would otherwise be silently
dropped. All four of 3d's violations decode cleanly against the Go types and are
wrong only semantically — that's what `validateKubeletSemantics` is for.

### 4 — Silent-drop prevention (`04-unsupported.yaml`)

Only AL2023 sets `SupportsArbitraryKubeletConfig = true`.

- **4a Bottlerocket** — unmanaged fields *plus* `podsPerCore`, which Karpenter maps
  but Bottlerocket has no setting to render into (`PodsPerCoreEnabled = false`).
- **4b AL2** — same unmanaged fields, but `podsPerCore` is *absent* from the error.
  The check is per-family, not a blanket denial.
- **4c AL2, positive control** — restricted to fields AL2 applies, including a CEL
  expression on `kubeReserved`. Extended config isn't "AL2023-only", it's
  "whatever your family can actually apply".

> Talking point: the alternative is a node that comes up without the config you
> asked for and nothing anywhere saying so — discoverable only by SSH-ing to a node.

---

## Files

| | |
|---|---|
| `demo.sh` | driver; `NO_PAUSE=1` for capture |
| `redeploy.sh` | build HEAD + deploy; `--dry-run` supported |
| `fix-fixtures.sh` | patches the 3 stale `cel-*` fixtures |
| `cleanup.sh` | `demo` / `stale` / `all`, all confirmed |
| `preflight/` | offline validator using the branch's real validation code |
| `capture/` | fallback output |

`preflight/` is its own Go module with a `replace` onto the repo, so it always
tests the code you're about to present without adding a file to the branch.
