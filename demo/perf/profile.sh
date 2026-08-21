#!/usr/bin/env bash
# Pull a pprof profile off the Karpenter *leader* and open it in the pprof web UI.
#
# The guide says `kubectl port-forward deployment/karpenter -n kube-system 8080`.
# That is the one step in the guide that will quietly waste your afternoon on this
# cluster: charts/karpenter/values.yaml sets `replicas: 2`, leader election is on,
# and only the leader reconciles anything. `port-forward deployment/...` resolves
# to an arbitrary ready pod -- roughly a coin flip -- and profiling the standby
# gives you a flat, idle profile that looks like "my change costs nothing".
#
# So: resolve the leader from the lease, port-forward that POD by name.
#
#   ./profile.sh heap              heap now, open in browser
#   ./profile.sh cpu [seconds]     CPU profile (default 180s), open in browser
#   ./profile.sh allocs            cumulative allocations since start
#   ./profile.sh goroutine         goroutine dump
#   ./profile.sh top heap          text `top` instead of the browser
#   ./profile.sh diff a.pb.gz b.pb.gz    open b relative to a (regression check)
#
# Profiles are saved under ./captures/ so you can diff a before/after pair later.

set -euo pipefail

HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
OUT="${HERE}/captures"
CLUSTER="${CLUSTER:-karpenter-cel-demo}"    # override: export CLUSTER=<your-cluster>
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>
NS=kube-system
RELEASE=karpenter
LEASE=karpenter-leader-election
LOCAL_PORT=${LOCAL_PORT:-8080}
UI_PORT=${UI_PORT:-9000}

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; R=$'\e[0m'
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
die()  { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }

mkdir -p "$OUT"

# ------------------------------------------------------------------ diff mode
# No cluster needed -- just two files already on disk.
if [[ "${1:-}" == "diff" ]]; then
  BASE=${2:?usage: ./profile.sh diff BASE.pb.gz NEW.pb.gz}
  NEW=${3:?usage: ./profile.sh diff BASE.pb.gz NEW.pb.gz}
  [[ -f "$BASE" ]] || die "no such file: $BASE"
  [[ -f "$NEW"  ]] || die "no such file: $NEW"
  step "pprof -base $(basename "$BASE") $(basename "$NEW")"
  printf '%s  Positive numbers = NEW spends more than BASE.%s\n' "$DIM" "$R"
  exec go tool pprof -http "0.0.0.0:${UI_PORT}" -base "$BASE" "$NEW"
fi

MODE=${1:-heap}
TEXT=""
if [[ "$MODE" == "top" ]]; then
  TEXT=1
  MODE=${2:-heap}
fi

case "$MODE" in
  heap|allocs|goroutine|block|threadcreate) PATH_SUFFIX="/debug/pprof/${MODE}"; SECS="" ;;
  cpu)     SECS=${2:-180}; [[ -n "$TEXT" ]] && SECS=${3:-180}
           PATH_SUFFIX="/debug/pprof/profile?seconds=${SECS}" ;;
  *)       die "unknown profile: ${MODE} (heap|cpu|allocs|goroutine|block|threadcreate|diff)" ;;
esac

# ------------------------------------------------------------------ preflight
step "Credentials"
aws sts get-caller-identity --query Arn --output text 2>/dev/null \
  || die "AWS credentials are not valid. Re-auth and re-run."

kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}" >/dev/null

step "Is profiling actually on?"
PROF=$(kubectl get deploy -n "$NS" "$RELEASE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_PROFILING")].value}')
if [[ "$PROF" != "true" ]]; then
  die "ENABLE_PROFILING is '${PROF:-<unset>}'. The /debug/pprof routes are not registered -- you would get a 404. Run ./enable-profiling.sh first."
fi
printf '%s  ENABLE_PROFILING=true%s\n' "$GRN" "$R"

METRICS_PORT=$(kubectl get deploy -n "$NS" "$RELEASE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="METRICS_PORT")].value}')
METRICS_PORT=${METRICS_PORT:-8080}

# ------------------------------------------------------------------ leader
step "Resolving the leader"
# controller-runtime writes holderIdentity as "<hostname>_<uuid>", and the
# hostname inside the pod is the pod name.
HOLDER=$(kubectl get lease -n "$NS" "$LEASE" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null) \
  || die "lease ${NS}/${LEASE} not found. Is leader election disabled (DISABLE_LEADER_ELECTION)? If so, port-forward any pod."
LEADER=${HOLDER%%_*}
[[ -n "$LEADER" ]] || die "could not parse a pod name out of holderIdentity '${HOLDER}'"

kubectl get pod -n "$NS" "$LEADER" >/dev/null 2>&1 \
  || die "lease points at pod '${LEADER}', which does not exist. Stale lease -- wait for re-election and retry."

printf '%s  leader:  %s%s\n' "$GRN" "$LEADER" "$R"
kubectl get pods -n "$NS" -l app.kubernetes.io/name=karpenter \
  -o custom-columns='POD:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp' --no-headers \
  | while read -r p rest; do
      if [[ "$p" == "$LEADER" ]]; then printf '%s    %-40s %s  <-- profiling this one%s\n' "$GRN" "$p" "$rest" "$R"
      else                             printf '%s    %-40s %s  (standby, idle)%s\n' "$DIM" "$p" "$rest" "$R"; fi
    done

# ------------------------------------------------------------------ forward
step "Port-forward ${LEADER}:${METRICS_PORT} -> localhost:${LOCAL_PORT}"
kubectl port-forward -n "$NS" "pod/${LEADER}" "${LOCAL_PORT}:${METRICS_PORT}" >/tmp/karpenter-pf.log 2>&1 &
PF=$!
cleanup() { kill "$PF" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 20); do
  curl -sf "http://localhost:${LOCAL_PORT}/metrics" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "http://localhost:${LOCAL_PORT}/metrics" >/dev/null 2>&1 \
  || { cat /tmp/karpenter-pf.log; die "port-forward never became ready."; }
printf '%s  ready%s\n' "$GRN" "$R"

# ------------------------------------------------------------------ fetch
STAMP=$(date +%Y%m%d-%H%M%S)
FILE="${OUT}/${MODE}-${STAMP}.pb.gz"

if [[ "$MODE" == cpu ]]; then
  step "Sampling CPU for ${SECS}s"
  cat <<EOF
${YEL}  A CPU profile only shows work that happens DURING the window. An idle
  Karpenter produces an empty profile. Generate load NOW, in another terminal:

    kubectl apply -f ${HERE}/load.yaml     # churns nodeclass reconciles
    # or, cheaper: force reconciles by bumping an annotation in a loop
    ${HERE}/churn.sh${R}

EOF
fi

step "Fetching ${PATH_SUFFIX}"
curl -sf --max-time $(( ${SECS:-30} + 60 )) \
  "http://localhost:${LOCAL_PORT}${PATH_SUFFIX}" -o "$FILE" \
  || die "fetch failed. If this 404'd, ENABLE_PROFILING did not take effect on THIS pod -- check that the pod was restarted after the helm upgrade."
printf '%s  %s (%s)%s\n' "$GRN" "$FILE" "$(du -h "$FILE" | cut -f1)" "$R"

# The port-forward is no longer needed -- the profile is a local file now, and
# `pprof -http` on a local file resolves symbols from the file itself.
cleanup
trap - EXIT

# ------------------------------------------------------------------ view
if [[ -n "$TEXT" ]]; then
  step "top 30"
  go tool pprof -top -nodecount=30 "$FILE"
  cat <<EOF

${DIM}  flat  = time/bytes in this function's own instructions
  cum   = flat + everything it called
  For the CEL work, look for cum on:
    pkg/cel.(*CELEnvironment).EvaluateExpression
    pkg/cel.(*CELEnvironment).compileCached
    github.com/google/cel-go/interpreter.*
    pkg/providers/instancetype.(*DefaultResolver).Resolve${R}

  Saved: ${FILE}
  Diff against an earlier capture:
    ./profile.sh diff <older>.pb.gz ${FILE}
EOF
else
  step "Opening pprof UI on http://0.0.0.0:${UI_PORT}"
  printf '%s  Saved: %s%s\n' "$DIM" "$FILE" "$R"
  printf '%s  Ctrl-C to stop. Diff later: ./profile.sh diff <older>.pb.gz %s%s\n' "$DIM" "$(basename "$FILE")" "$R"
  go tool pprof -http "0.0.0.0:${UI_PORT}" "$FILE"
fi
