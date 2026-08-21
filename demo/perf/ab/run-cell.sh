#!/usr/bin/env bash
# Run one (arm, cell) measurement and write a run record to runs/.
#
# Two phases, in this order, because they measure different things:
#
#   Phase A -- provisioning bursts. Scale all 12 pinned Deployments to 1, wait for 12
#     nodes across 12 distinct instance types, hold, scale to 0, wait for termination.
#     Repeated BURSTS times. This exercises the launch path: instance-type resolution,
#     launch-template rendering, UserData generation, CreateFleet. It is where the
#     extended-kubelet-config work actually costs something, since that feature's output
#     is bytes in UserData.
#
#   Phase B -- reconcile churn. Cache-busting edits to the NodeClass's kubelet block at a
#     fixed rate, with no launches. Each edit forces a full re-resolve across the whole
#     ~800-type fleet (the fleetwide NodePool widens it). This is where CEL evaluation
#     costs something.
#
# Phase A is noisy by nature: node launch latency is dominated by EC2 and AMI boot, which
# this change cannot affect and which varies 30s-3min run to run. That is why it runs
# BURSTS times rather than once -- you need several samples before a launch-latency
# comparison means anything. Phase B is nearly noise-free by comparison.
#
#   ./run-cell.sh v2 cel
#   BURSTS=3 CHURN_MINUTES=10 CHURN_INTERVAL=5 ./run-cell.sh v2 cel

set -euo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"
ARM=${1:?usage: ./run-cell.sh <v0|v1|v2> <static|cel|extended>}
CELL=${2:?usage: ./run-cell.sh <arm> <cell>}
RUNS="${HERE}/runs"; mkdir -p "$RUNS"

BURSTS=${BURSTS:-3}
BURST_HOLD=${BURST_HOLD:-60}          # seconds at full node count before scaling down
NODE_TIMEOUT=${NODE_TIMEOUT:-600}     # per-burst wait for all 12 nodes Ready
CHURN_MINUTES=${CHURN_MINUTES:-10}
CHURN_INTERVAL=${CHURN_INTERVAL:-5}   # seconds between cache-busting edits
EXPECTED_NODES=12

# ------------------------------------------------------------------ preflight
step "Preflight"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
  || die "AWS credentials are not valid. Re-auth and re-run -- a run that dies mid-window is not salvageable."
ensure_kubeconfig   # private KUBECONFIG pinned to the A/B cluster; never touches ~/.kube/config

# Refuse to run a cell this arm cannot express, rather than producing a run record full of
# ValidationSucceeded=False that looks like a measurement.
grep -qw "$CELL" <<<"$(arm_cells "$ARM")" \
  || die "arm ${ARM} cannot express cell '${CELL}'. Cells for $(arm_label "$ARM"): $(arm_cells "$ARM")"

source "${HERE}/arms.env"
EXPECT_DIGEST=$(eval "echo \${${ARM}_IMG_DIGEST}")
RUNNING=$(kubectl get deploy -n "$NS" "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$RUNNING" == *"$EXPECT_DIGEST"* ]] \
  || die "cluster is NOT running ${ARM}. Running: ${RUNNING}. Run ./deploy-arm.sh ${ARM} first."
ok "$(arm_label "$ARM") confirmed running, cell=${CELL}"

LEASE_HOLDER=$(kubectl get lease -n "$NS" karpenter-leader-election -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
LEADER=${LEASE_HOLDER%%_*}
info "leader: ${LEADER:-unknown}"

# ------------------------------------------------------------------ isolate this cell
step "Isolating cell ${CELL}"
# Only one cell's objects may exist at a time. Leaving another cell's NodeClass behind
# means its nodeclass reconciles land inside this window and inflate every controller
# metric -- with a CEL NodeClass sitting idle, that inflation is exactly the effect we are
# trying to measure.
for other in static cel extended; do
  [[ "$other" == "$CELL" ]] && continue
  kubectl delete deploy  -l "ab-cell=${other}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete nodepool -l "ab-cell=${other}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
for i in $(seq 1 60); do
  N=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$N" == "0" ]] && break
  printf '\r%s  draining other cells, NodeClaims: %-4s%s' "$DIM" "$N" "$R"; sleep 5
done; echo
for other in static cel extended; do
  [[ "$other" == "$CELL" ]] && continue
  kubectl delete ec2nodeclass -l "ab-cell=${other}" --ignore-not-found >/dev/null 2>&1 || true
done
ok "only cell ${CELL} will exist in this window"

step "Applying cell ${CELL}"
"${HERE}/inputs/render.sh" "$CELL" > "/tmp/ab-${CELL}.yaml"
kubectl apply -f "/tmp/ab-${CELL}.yaml" >/dev/null
NC="ab-${CELL}"

# A NodeClass that fails validation never launches anything, so a run started before it is
# Ready measures nothing. Fail loudly instead of collecting 25 minutes of flat lines.
info "waiting for ec2nodeclass/${NC} to go Ready ..."
for i in $(seq 1 60); do
  ST=$(kubectl get ec2nodeclass "$NC" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$ST" == "True" ]] && { ok "Ready"; break; }
  sleep 5
done
if [[ "$(kubectl get ec2nodeclass "$NC" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" != "True" ]]; then
  kubectl get ec2nodeclass "$NC" -o jsonpath='{range .status.conditions[*]}  {.type}={.status} {.reason}: {.message}{"\n"}{end}'
  die "ec2nodeclass/${NC} never became Ready on ${ARM}. Nothing measurable here."
fi

# ------------------------------------------------------------------ helpers
scale_all() { for d in $(kubectl get deploy -l "ab-cell=${CELL}" -o name); do kubectl scale "$d" --replicas="$1" >/dev/null; done; }
ready_nodes() { kubectl get nodes -l "ab-cell=${CELL}" --no-headers 2>/dev/null | grep -c " Ready " || true; }
nodeclaim_count() { kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' '; }
now_epoch() { date +%s; }

STAMP=$(date +%Y%m%d-%H%M%S)
REC="${RUNS}/${ARM}-${CELL}-${STAMP}.json"
T_START=$(now_epoch)
BURST_LOG=""

# ------------------------------------------------------------------ Phase A
step "Phase A — ${BURSTS} provisioning bursts (${EXPECTED_NODES} nodes, ${EXPECTED_NODES} instance types each)"
PHASE_A_START=$(now_epoch)
for b in $(seq 1 "$BURSTS"); do
  info "burst ${b}/${BURSTS}: scaling up"
  BSTART=$(now_epoch)
  scale_all 1
  REACHED=0
  for i in $(seq 1 $((NODE_TIMEOUT / 5))); do
    RN=$(ready_nodes)
    printf '\r%s  burst %s: Ready nodes %s/%s (%ss)%s' "$DIM" "$b" "$RN" "$EXPECTED_NODES" "$(( $(now_epoch) - BSTART ))" "$R"
    [[ "$RN" -ge "$EXPECTED_NODES" ]] && { REACHED=1; break; }
    sleep 5
  done; echo
  BREADY=$(now_epoch); TTR=$((BREADY - BSTART))
  if [[ "$REACHED" == 1 ]]; then ok "burst ${b}: ${EXPECTED_NODES} nodes Ready in ${TTR}s"
  else warn "burst ${b}: only $(ready_nodes)/${EXPECTED_NODES} Ready after ${TTR}s (recorded as partial)"; fi

  TYPES=$(kubectl get nodes -l "ab-cell=${CELL}" -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null | sort -u | paste -sd, -)
  info "types: ${TYPES}"
  sleep "$BURST_HOLD"

  info "burst ${b}: scaling down"
  scale_all 0
  for i in $(seq 1 120); do
    NC_N=$(nodeclaim_count)
    printf '\r%s  burst %s: NodeClaims remaining %-4s%s' "$DIM" "$b" "$NC_N" "$R"
    [[ "$NC_N" == "0" ]] && break
    sleep 5
  done; echo
  BEND=$(now_epoch)
  BURST_LOG+="{\"burst\":${b},\"start\":${BSTART},\"ready\":${BREADY},\"end\":${BEND},\"time_to_ready_s\":${TTR},\"nodes_ready\":$(ready_nodes),\"complete\":${REACHED},\"instance_types\":\"${TYPES}\"},"
  sleep 30   # let the controller quiesce so bursts don't bleed into each other
done
PHASE_A_END=$(now_epoch)
ok "Phase A done in $((PHASE_A_END - PHASE_A_START))s"

# ------------------------------------------------------------------ Phase B
step "Phase B — ${CHURN_MINUTES}m reconcile churn every ${CHURN_INTERVAL}s (no launches)"
# Each patch changes the kubelet block, which changes the hash in
# instancetype.(*DefaultResolver).CacheKey, which invalidates the instance-type cache and
# forces a full re-resolve. An annotation bump would NOT do this -- it reconciles but hits
# the cache. Two alternating values keep the resolved config stable and bound the CEL
# compilation cache at two extra entries.
if [[ "$CELL" == static ]]; then
  P_A='{"spec":{"kubelet":{"kubeReserved":{"cpu":"100m"}}}}'
  P_B='{"spec":{"kubelet":{"kubeReserved":{"cpu":"101m"}}}}'
else
  P_A='{"spec":{"kubelet":{"kubeReserved":{"cpu":"max(100, vcpus * 30)"}}}}'
  P_B='{"spec":{"kubelet":{"kubeReserved":{"cpu":"max(100, vcpus * 30 + 0)"}}}}'
fi
PHASE_B_START=$(now_epoch)
FLIPS=0; DEADLINE=$((PHASE_B_START + CHURN_MINUTES * 60))
while [[ $(now_epoch) -lt $DEADLINE ]]; do
  if (( FLIPS % 2 == 0 )); then PATCH="$P_B"; else PATCH="$P_A"; fi
  kubectl patch ec2nodeclass "$NC" --type=merge -p "$PATCH" >/dev/null 2>&1 || warn "patch failed at flip ${FLIPS}"
  FLIPS=$((FLIPS + 1))
  printf '\r%s  flips: %-5s  remaining: %ss%s' "$DIM" "$FLIPS" "$((DEADLINE - $(now_epoch)))" "$R"
  sleep "$CHURN_INTERVAL"
done; echo
PHASE_B_END=$(now_epoch)
ok "Phase B done: ${FLIPS} flips over $((PHASE_B_END - PHASE_B_START))s"

# ------------------------------------------------------------------ profiles
step "Capturing pprof from the leader"
# Taken at the END of the window so the heap reflects everything the run did. The CPU
# profile is deliberately NOT taken here: it would need its own 180s of load, and Phase B
# is already over. Use ./profile-during.sh if you want a CPU profile mid-churn.
PROF_DIR="${HERE}/captures"; mkdir -p "$PROF_DIR"
LEASE_HOLDER=$(kubectl get lease -n "$NS" karpenter-leader-election -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
LEADER=${LEASE_HOLDER%%_*}
if [[ -n "$LEADER" ]] && kubectl get pod -n "$NS" "$LEADER" >/dev/null 2>&1; then
  kubectl port-forward -n "$NS" "pod/${LEADER}" 18080:8080 >/tmp/ab-pf.log 2>&1 & PF=$!
  sleep 4
  for p in heap allocs goroutine; do
    curl -sf --max-time 60 "http://localhost:18080/debug/pprof/${p}" \
      -o "${PROF_DIR}/${ARM}-${CELL}-${p}-${STAMP}.pb.gz" && info "captured ${p}" || warn "could not capture ${p}"
  done
  kill "$PF" 2>/dev/null || true
else
  warn "could not resolve the leader pod; skipping profiles"
fi

# ------------------------------------------------------------------ record
T_END=$(now_epoch)
cat > "$REC" <<JSON
{
  "arm": "${ARM}",
  "arm_label": "$(arm_label "$ARM")",
  "cell": "${CELL}",
  "cluster": "${CLUSTER}",
  "image_digest": "${EXPECT_DIGEST}",
  "leader_pod": "${LEADER:-unknown}",
  "expected_nodes": ${EXPECTED_NODES},
  "t_start": ${T_START},
  "t_end": ${T_END},
  "phase_a": { "start": ${PHASE_A_START}, "end": ${PHASE_A_END}, "bursts": ${BURSTS} },
  "phase_b": { "start": ${PHASE_B_START}, "end": ${PHASE_B_END}, "flips": ${FLIPS}, "interval_s": ${CHURN_INTERVAL} },
  "burst_detail": [ ${BURST_LOG%,} ],
  "params": { "burst_hold_s": ${BURST_HOLD}, "churn_minutes": ${CHURN_MINUTES}, "node_timeout_s": ${NODE_TIMEOUT} }
}
JSON

step "Run record"
cat "$REC"
cat <<EOF

${GRN}Cell ${CELL} on $(arm_label "$ARM") complete.${R}  ($(( (T_END - T_START) / 60 ))m)
  record:   ${REC}
  profiles: ${PROF_DIR}/${ARM}-${CELL}-*-${STAMP}.pb.gz

  Nodes are scaled to 0 but the NodePools remain. Next cell for this arm, or:
    ./deploy-arm.sh <next-arm>
EOF
