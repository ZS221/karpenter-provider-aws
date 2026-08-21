#!/usr/bin/env bash
# Turn on the pprof endpoints in the running Karpenter controller.
#
# Why this needs a script: ENABLE_PROFILING is a karpenter-core option (see
# sigs.k8s.io/karpenter/pkg/operator/operator.go, gated on
# options.FromContext(ctx).EnableProfiling), but this chart has NO value for it --
# `grep -rn PROFILING charts/` comes back empty. The only way in is
# `controller.env`, which is a LIST. `--set controller.env[0].name=...` overwrites
# whatever is already at index 0, so this script reads the release's current env
# first and refuses to clobber it.
#
# pprof is registered as an ExtraHandler on the *metrics* listener, so it lands on
# controller.metrics.port -- 8080 in this chart. That happens to match the guide's
# `port-forward ... 8080`, but it is a coincidence of the default, not a fixed port.
#
#   ./enable-profiling.sh            enable
#   ./enable-profiling.sh --off      disable again
#   ./enable-profiling.sh --dry-run  show what it would do

set -euo pipefail

CLUSTER="${CLUSTER:-karpenter-cel-demo}"    # override: export CLUSTER=<your-cluster>
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>
NS=kube-system
RELEASE=karpenter
REPO=$(cd "$(dirname "$(realpath "$0")")/../.." && pwd)

MODE=on
case "${1:-}" in
  --off)     MODE=off ;;
  --dry-run) MODE=dry ;;
  "")        ;;
  *)         echo "unknown flag: $1" >&2; exit 2 ;;
esac

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; R=$'\e[0m'
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
die()  { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }

step "Credentials"
aws sts get-caller-identity --query Arn --output text 2>/dev/null \
  || die "AWS credentials are not valid. Re-auth and re-run."

step "Context"
kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

step "Current controller.env in the Helm release"
CUR=$(helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null | jq -c '.controller.env // []')
printf '%s  %s%s\n' "$DIM" "$CUR" "$R"

# Anything in controller.env other than ENABLE_PROFILING is somebody's deliberate
# choice. Bail rather than index-overwrite it.
OTHERS=$(printf '%s' "$CUR" | jq -c '[.[] | select(.name != "ENABLE_PROFILING")]')
if [[ "$OTHERS" != "[]" ]]; then
  printf '%s  controller.env already carries entries this script did not set:%s\n' "$YEL" "$R"
  printf '%s  %s%s\n' "$YEL" "$OTHERS" "$R"
  die "Refusing to overwrite. Add ENABLE_PROFILING by hand with -f values.yaml instead."
fi

METRICS_PORT=$(kubectl get deploy -n "$NS" "$RELEASE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="METRICS_PORT")].value}')
printf '%s  metrics/pprof port: %s%s\n' "$DIM" "${METRICS_PORT:-8080}" "$R"

if [[ "$MODE" == dry ]]; then
  step "Would now: helm upgrade --reuse-values with ENABLE_PROFILING (on), then rollout"
  printf '%s  Re-run without --dry-run to execute.%s\n' "$DIM" "$R"
  exit 0
fi

# --reuse-values for the same reason redeploy.sh uses it: the release already
# carries the right IRSA role, interruption queue, image digest and feature gates,
# and re-specifying them is how a working install gets clobbered.
step "helm upgrade (ENABLE_PROFILING=${MODE})"
if [[ "$MODE" == on ]]; then
  helm upgrade "$RELEASE" "${REPO}/charts/karpenter" \
    --namespace "$NS" \
    --reuse-values \
    --set        "controller.env[0].name=ENABLE_PROFILING" \
    --set-string "controller.env[0].value=true" \
    --wait --timeout 10m
else
  helm upgrade "$RELEASE" "${REPO}/charts/karpenter" \
    --namespace "$NS" \
    --reuse-values \
    --set "controller.env=[]" \
    --wait --timeout 10m
fi

step "Rollout"
kubectl rollout status -n "$NS" "deploy/${RELEASE}" --timeout=5m

step "Verify the env landed"
kubectl get deploy -n "$NS" "$RELEASE" \
  -o jsonpath='  ENABLE_PROFILING={.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PROFILING")].value}{"\n"}'

if [[ "$MODE" == on ]]; then
  cat <<EOF

${GRN}Profiling enabled.${R}
  ${YEL}This restarted both replicas -- leader election just re-ran, so the leader
  pod is probably not the one it was 5 minutes ago. Always use ./profile.sh,
  which resolves the leader from the lease.${R}

  Next: ./profile.sh heap     or     ./profile.sh cpu
EOF
else
  printf '\n%sProfiling disabled.%s\n' "$GRN" "$R"
fi
