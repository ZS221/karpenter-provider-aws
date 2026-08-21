#!/usr/bin/env bash
# Shared configuration for the three-arm A/B experiment. Sourced by every script here.
#
# Cluster is `blah` -- deliberately NOT karpenter-cel-demo, so none of this
# touches the demo fixtures.

CLUSTER="${CLUSTER:-blah}"
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>
NS=kube-system
MON_NS=monitoring
RELEASE=karpenter
MON_RELEASE=kube-prometheus-stack
ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/dev"
CTX="arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

# ---------------------------------------------------------------- kubeconfig isolation
#
# These scripts get their OWN kubeconfig, pinned to `blah`, instead of calling
# `kubectl config use-context` against ~/.kube/config.
#
# The old arrangement was actively dangerous. kubectl's current-context is global mutable
# state: a script would set it to blah, then run bare `kubectl` for everything after. So
# (a) running any script here stole the context from whatever else you were doing, and
# (b) if you switched context while a script was mid-run, every SUBSEQUENT kubectl call in
# that script followed you. deploy-arm.sh runs `kubectl delete nodepools --all` and
# `kubectl delete ec2nodeclasses --all` -- redirected at karpenter-cel-demo that
# silently destroys the demo fixtures.
#
# With a private KUBECONFIG the two are physically independent: switch your own context as
# much as you like, and nothing here can reach the demo cluster.
_AB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KUBECONFIG="${_AB_DIR}/kubeconfig"

# Build the private kubeconfig once, by extracting just the blah context from the user's
# real one. --minify keeps only the named context; --raw keeps credentials so the exec
# plugin still works.
ensure_kubeconfig() {
  if [[ ! -s "$KUBECONFIG" ]]; then
    KUBECONFIG="${HOME}/.kube/config" kubectl config view --raw --minify --context="$CTX" \
      > "${_AB_DIR}/kubeconfig.tmp" 2>/dev/null \
      || { rm -f "${_AB_DIR}/kubeconfig.tmp"; die "could not extract context ${CTX} from ~/.kube/config"; }
    mv "${_AB_DIR}/kubeconfig.tmp" "$KUBECONFIG"
    chmod 600 "$KUBECONFIG"
  fi
  # Belt and braces: refuse to run against anything but the A/B cluster, however this
  # kubeconfig came to exist.
  local cur
  cur=$(kubectl config current-context 2>/dev/null || true)
  [[ "$cur" == "$CTX" ]] || die "private kubeconfig points at '${cur}', not '${CTX}'. Delete ${KUBECONFIG} and re-run."
}

# Cluster prerequisites, discovered from the live cluster (see README for how).
NODE_ROLE="KarpenterNodeRole-${CLUSTER}"
INTERRUPTION_QUEUE="${CLUSTER}"
DISCOVERY_TAG="${CLUSTER}"

# ---------------------------------------------------------------- the three arms
#
# V0  6e13b3e0a^   neither feature
# V1  origin/main  CEL only            (code-identical to 6e13b3e0a for pkg/cmd/charts)
# V2  HEAD         CEL + extended kubelet config
#
# V0 and V1 each get `dda4e98d2` (perf: precompute offering cache keys, #9411)
# cherry-picked on top. That commit is present in V2 but absent from origin/main, and
# it is a PERFORMANCE change on the offering path that this load exercises heavily --
# left alone it would make V2 look faster for reasons that are not the feature under
# test. Verified to cherry-pick cleanly onto both baselines.
CONFOUNDER_PICK=dda4e98d2

ARMS=(v0 v1 v2)

arm_ref() {
  case "$1" in
    v0) echo "6e13b3e0a^" ;;
    v1) echo "origin/main" ;;
    v2) echo "extended_kubelet_config" ;;
    *)  echo "unknown arm: $1" >&2; return 1 ;;
  esac
}

# Whether this arm needs the confounder cherry-picked on top.
arm_needs_pick() { [[ "$1" == v0 || "$1" == v1 ]]; }

arm_label() {
  case "$1" in
    v0) echo "V0 neither" ;;
    v1) echo "V1 CEL only" ;;
    v2) echo "V2 CEL+extended" ;;
  esac
}

# Which input cells each arm can actually accept. V0's spec.kubelet is a closed
# struct with an int-only maxPods; V1 adds CEL on maxPods/kubeReserved/systemReserved;
# only V2 has the open map that accepts extended fields.
arm_cells() {
  case "$1" in
    v0) echo "static" ;;
    v1) echo "static cel" ;;
    v2) echo "static cel extended" ;;
  esac
}

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; R=$'\e[0m'
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
info() { printf '%s  %s%s\n' "$DIM" "$1" "$R"; }
warn() { printf '%s  %s%s\n' "$YEL" "$1" "$R"; }
ok()   { printf '%s  %s%s\n' "$GRN" "$1" "$R"; }
die()  { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }
