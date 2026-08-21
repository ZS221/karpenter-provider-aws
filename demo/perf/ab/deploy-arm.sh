#!/usr/bin/env bash
# Swap the cluster to one arm: tear down experiment state, replace the CRDs, deploy that
# arm's chart and image, wait for steady state.
#
# The teardown is not optional and it is not politeness. Each arm has a DIFFERENT
# EC2NodeClass schema -- V0's spec.kubelet is a closed struct with an int-only maxPods,
# V2's is an open map with x-kubernetes-preserve-unknown-fields. Applying V0's CRD while
# a V2 NodeClass holding `maxPods: "vcpus * 8"` still exists leaves an object the new
# schema cannot validate and the new controller cannot parse: the nodeclass controller
# then spins on it for the whole run and poisons every metric in the window.
#
# So: delete NodePools first (they own NodeClaims), wait for NodeClaims to drain, then
# NodeClasses, then swap CRDs. Deleting NodeClasses first would orphan NodeClaims whose
# nodeClassRef no longer resolves, and those block on finalizers.
#
#   ./deploy-arm.sh v1
#   ./deploy-arm.sh v1 --keep-nodes   skip the drain (only safe within the same arm)

set -euo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"
ARM=${1:?usage: ./deploy-arm.sh <v0|v1|v2> [--keep-nodes]}
KEEP=${2:-}
[[ -f "${HERE}/arms.env" ]] || die "arms.env not found. Run ./build-arms.sh first."
source "${HERE}/arms.env"

ref_var()  { eval "echo \${${ARM}_$1:-}"; }
WORKTREE=$(ref_var WORKTREE); IMG_REPO=$(ref_var IMG_REPO)
IMG_DIGEST=$(ref_var IMG_DIGEST); TAG=$(ref_var TAG); SHA=$(ref_var SHA)
[[ -n "$WORKTREE" && -d "$WORKTREE" ]] || die "no worktree recorded for ${ARM}. Re-run ./build-arms.sh ${ARM}."
[[ -n "$IMG_DIGEST" ]] || die "no image digest recorded for ${ARM}."

step "Preflight"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || die "AWS credentials are not valid. Re-auth and re-run."
ensure_kubeconfig   # private KUBECONFIG pinned to the A/B cluster; never touches ~/.kube/config
ok "$(arm_label "$ARM")  ${SHA}  ->  cluster ${CLUSTER}"

# ------------------------------------------------------------------ teardown
if [[ "$KEEP" != "--keep-nodes" ]]; then
  step "Tearing down experiment state (ordered: workloads -> nodepools -> nodeclaims -> nodeclasses)"

  kubectl delete deploy -l ab-experiment=true --ignore-not-found --wait=false >/dev/null 2>&1 || true

  if kubectl get nodepools >/dev/null 2>&1; then
    kubectl delete nodepools --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
    info "waiting for NodeClaims to drain (up to 10m) ..."
    for i in $(seq 1 120); do
      N=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
      [[ "$N" == "0" ]] && { ok "all NodeClaims gone"; break; }
      printf '\r%s  NodeClaims remaining: %-4s (%ss)%s' "$DIM" "$N" "$((i*5))" "$R"
      sleep 5
    done
    echo
    N=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$N" != "0" ]]; then
      warn "${N} NodeClaims still present. Stripping finalizers so the CRD swap cannot wedge."
      for nc in $(kubectl get nodeclaims -o name 2>/dev/null); do
        kubectl patch "$nc" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done
    fi
    kubectl delete ec2nodeclasses --all --ignore-not-found >/dev/null 2>&1 || true
    ok "NodePools and NodeClasses deleted"
  fi
fi

# ------------------------------------------------------------------ CRDs
step "CRDs from ${ARM}'s worktree"
# `replace` rather than `apply`: the kubelet schema shrinks from an open map (V2) to a
# closed struct (V0/V1), and a shrinking schema blows the annotation size limit that
# `apply` uses to store last-applied-configuration.
for f in "${WORKTREE}"/pkg/apis/crds/*.yaml; do
  kubectl replace -f "$f" >/dev/null 2>&1 || kubectl create -f "$f" >/dev/null 2>&1 || \
    kubectl apply --server-side --force-conflicts -f "$f" >/dev/null
done
info "$(ls "${WORKTREE}"/pkg/apis/crds/*.yaml | wc -l | tr -d ' ') CRDs applied"

# ------------------------------------------------------------------ helm
step "helm upgrade --install (chart from ${ARM}'s worktree)"
# Every value is specified explicitly rather than --reuse-values. Across an arm swap
# --reuse-values would carry the previous arm's image and settings forward, which is the
# one mistake that would silently invalidate the whole experiment.
#
# resources are pinned identically on every arm so each arm gets the same ceiling and the
# same GC pressure profile. replicas=2 matches the chart default and keeps leader election
# in the picture; only the leader does work.
#
# CPU limit is 1.5 rather than the 1 the cluster's existing release used. A CPU limit is a
# ceiling, and a ceiling the load can reach is a measurement destroyed: if V2 wants more
# CPU than the limit allows, CFS throttles it and BOTH arms read as exactly 1.0 cores --
# the graph goes flat and hides the effect instead of showing it. 1.5 leaves headroom on a
# 1930m-allocatable m5.large while keeping requests at 1 so it still schedules.
# collect/export records container_cpu_cfs_throttled_seconds_total so "we were not
# throttled" is a claim backed by data rather than an assumption.
#
# Memory requests and limits stay equal at 1Gi: the chart feeds limits.memory into the
# MEMORY_LIMIT env var, so changing it would change the controller's GC behaviour, and GC
# behaviour is exactly what the allocation-rate comparison is reading.
helm upgrade --install "$RELEASE" "${WORKTREE}/charts/karpenter" \
  --namespace "$NS" --create-namespace \
  --set "settings.clusterName=${CLUSTER}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --set "settings.awsFeatureGates.nodeClassCEL=true" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT}:role/${CLUSTER}-karpenter" \
  --set "controller.image.repository=${IMG_REPO}" \
  --set "controller.image.tag=${TAG}" \
  --set "controller.image.digest=${IMG_DIGEST}" \
  --set "controller.resources.requests.cpu=1" \
  --set "controller.resources.requests.memory=1Gi" \
  --set "controller.resources.limits.cpu=1500m" \
  --set "controller.resources.limits.memory=1Gi" \
  --set "controller.env[0].name=ENABLE_PROFILING" \
  --set-string "controller.env[0].value=true" \
  --set "replicas=2" \
  --set "logLevel=info" \
  --wait --timeout 15m

step "Rollout"
kubectl rollout status -n "$NS" "deploy/${RELEASE}" --timeout=10m

step "Verify the running arm"
kubectl get deploy -n "$NS" "$RELEASE" -o jsonpath='  image:     {.spec.template.spec.containers[0].image}{"\n"}  profiling: {.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PROFILING")].value}{"\n"}  gates:     {.spec.template.spec.containers[0].env[?(@.name=="AWS_FEATURE_GATES")].value}{"\n"}'
RUNNING_DIGEST=$(kubectl get deploy -n "$NS" "$RELEASE" -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$RUNNING_DIGEST" == *"$IMG_DIGEST"* ]] || die "running image does not match ${ARM}'s digest. Refusing to proceed."
ok "digest matches ${ARM}"

# ------------------------------------------------------------------ settle
step "Settling"
# Karpenter hydrates its instance-type, offering, AMI and pricing caches on startup, and
# that hydration is CPU-expensive and completely unrelated to the feature under test.
# Measuring during it would bury the signal. 3 minutes is enough for the pricing and
# instance-type caches to fill on a fresh process.
info "waiting 180s for cache hydration to finish before any cell runs"
sleep 180
ok "ready"

cat <<EOF

${GRN}$(arm_label "$ARM") is live.${R}
  cells available for this arm:  $(arm_cells "$ARM")
  next:  ./run-cell.sh ${ARM} static
EOF
