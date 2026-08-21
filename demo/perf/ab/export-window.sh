#!/usr/bin/env bash
# Export one run's series from Prometheus to local disk. Run this IMMEDIATELY after each
# cell.
#
# Prometheus here has no persistent volume (this cluster's only StorageClass uses the
# in-tree aws-ebs provisioner, removed in Kubernetes 1.27, and there is no EBS CSI addon),
# so its data lives in an emptyDir and dies with the pod. Exporting after every cell means
# a Prometheus restart costs you the current cell at worst, instead of every arm measured
# so far. It also means the comparison and the graphs are built from local JSON and never
# need the cluster again.
#
#   ./export-window.sh                     export every run record not yet exported
#   ./export-window.sh runs/v2-cel-*.json  export specific records

set -euo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"
RESULTS="${HERE}/results"; mkdir -p "$RESULTS"
LOCAL_PORT=${LOCAL_PORT:-19090}

step "Preflight"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 || die "AWS credentials are not valid. Re-auth and re-run."
ensure_kubeconfig   # private KUBECONFIG pinned to the A/B cluster; never touches ~/.kube/config

RECS=("$@")
if [[ ${#RECS[@]} -eq 0 ]]; then
  shopt -s nullglob
  for r in "${HERE}"/runs/*.json; do
    base=$(basename "$r"); arm=${base%%-*}; rest=${base#*-}; cell=${rest%%-*}
    [[ -f "${RESULTS}/${arm}-${cell}.json" ]] || RECS+=("$r")
  done
  shopt -u nullglob
fi
[[ ${#RECS[@]} -gt 0 ]] || { warn "nothing to export (all run records already have results)"; exit 0; }
info "${#RECS[@]} record(s) to export"

step "Port-forward Prometheus"
kubectl port-forward -n "$MON_NS" "svc/${MON_RELEASE}-prometheus" "${LOCAL_PORT}:9090" >/tmp/ab-prom-pf.log 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf "http://localhost:${LOCAL_PORT}/-/ready" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://localhost:${LOCAL_PORT}/-/ready" >/dev/null 2>&1 \
  || { cat /tmp/ab-prom-pf.log; die "Prometheus port-forward never became ready."; }
ok "ready on localhost:${LOCAL_PORT}"

# Sanity-check the Karpenter scrape target before exporting anything. Without it every
# go_* / karpenter_* / controller_runtime_* metric silently returns NO DATA and you get a
# results file that looks structurally fine and is half empty.
step "Karpenter scrape target"
UP=$(curl -sf "http://localhost:${LOCAL_PORT}/api/v1/query?query=up%7Bjob%3D%22karpenter%22%7D" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(float(r["value"][1]) for r in d["data"]["result"]) if d["data"]["result"] else 0)')
if [[ "${UP%.*}" -lt 1 ]]; then
  warn "up{job=\"karpenter\"} is ${UP} -- Karpenter's own metrics are NOT being scraped."
  warn "cAdvisor CPU/memory will still export; every go_*/karpenter_*/controller_runtime_* will be empty."
else
  ok "up{job=\"karpenter\"} = ${UP}"
fi

for rec in "${RECS[@]}"; do
  step "$(basename "$rec")"
  PROM="http://localhost:${LOCAL_PORT}" python3 "${HERE}/export.py" "$rec" "$RESULTS"
done

cat <<EOF

${GRN}Exported to ${RESULTS}/${R}
$(ls -1 "$RESULTS" | sed 's/^/  /')
EOF
