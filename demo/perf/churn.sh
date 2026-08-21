#!/usr/bin/env bash
# Force repeated full instance-type re-resolution so a CPU profile has something
# to sample. Launches no EC2 capacity -- this is pure controller CPU.
#
# The mechanism matters. Bumping an annotation triggers a reconcile but does NOT
# redo the CEL work: instancetype.(*Provider).cacheKey folds in
# DefaultResolver.CacheKey(nodeClass), which hashes the kubelet config, so an
# unchanged kubelet block is a cache HIT and Resolve() never runs again.
#
# To actually re-run CEL across every instance type you have to change the kubelet
# config itself. So this alternates a semantically-identical expression pair:
#
#     max(60, vcpus * 30)      <->      max(60, vcpus * 30 + 0)
#
# Different string -> different kcHash -> cache miss -> full re-resolve of ~800
# instance types x 6 expressions. Same resolved value every time, so nothing about
# the cluster's actual configuration drifts while it runs.
#
# Side effect worth knowing: each flip is a distinct expression string, so it also
# inserts a new entry into the CEL compilation cache. Two strings alternating is
# bounded at two entries -- do not "improve" this by using a counter in the
# expression unless growing that cache is what you want to measure.
#
#   ./churn.sh              churn perf-cel every 5s until Ctrl-C
#   ./churn.sh 2            every 2s
#   ./churn.sh 5 perf-static   churn the static control instead

set -euo pipefail

NS_CONTEXT_CLUSTER="${NS_CONTEXT_CLUSTER:-karpenter-cel-demo}"    # override: export NS_CONTEXT_CLUSTER=<your-cluster>
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>

INTERVAL=${1:-5}
TARGET=${2:-perf-cel}

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; R=$'\e[0m'
die() { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }

kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${NS_CONTEXT_CLUSTER}" >/dev/null

kubectl get ec2nodeclass "$TARGET" >/dev/null 2>&1 \
  || die "ec2nodeclass/${TARGET} not found. kubectl apply -f load.yaml first."

# perf-static has no expressions; churning it still busts the cache (the hash is
# over the whole kubelet block) but the flip has to be on a static field instead.
if [[ "$TARGET" == "perf-static" ]]; then
  A='{"spec":{"kubelet":{"kubeReserved":{"cpu":"60m"}}}}'
  Bp='{"spec":{"kubelet":{"kubeReserved":{"cpu":"61m"}}}}'
else
  A='{"spec":{"kubelet":{"kubeReserved":{"cpu":"max(60, vcpus * 30)"}}}}'
  Bp='{"spec":{"kubelet":{"kubeReserved":{"cpu":"max(60, vcpus * 30 + 0)"}}}}'
fi

printf '%s▸ Churning ec2nodeclass/%s every %ss. Ctrl-C to stop.%s\n' "$B" "$TARGET" "$INTERVAL" "$R"
printf '%s  Each flip = one full re-resolve over every instance type.%s\n\n' "$DIM" "$R"

i=0
trap 'printf "\n%s stopped after %s flips%s\n" "$GRN" "$i" "$R"; exit 0' INT

while true; do
  if (( i % 2 == 0 )); then PATCH="$Bp"; else PATCH="$A"; fi
  kubectl patch ec2nodeclass "$TARGET" --type=merge -p "$PATCH" >/dev/null
  i=$((i + 1))
  printf '\r%s  flips: %-6s%s' "$DIM" "$i" "$R"
  sleep "$INTERVAL"
done
