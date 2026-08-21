#!/usr/bin/env bash
# Install kube-prometheus-stack + the Karpenter ServiceMonitor, then print the
# Grafana credentials. Idempotent: re-running upgrades in place.
#
#   ./setup-monitoring.sh            install / upgrade
#   ./setup-monitoring.sh --dry-run  show what it would do, touch nothing

set -euo pipefail

HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
CLUSTER="${CLUSTER:-karpenter-cel-demo}"    # override: export CLUSTER=<your-cluster>
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-000000000000}"        # override: export ACCOUNT=<your-account-id>
NS=monitoring
RELEASE=kube-prometheus-stack

DRY=""
[[ "${1:-}" == "--dry-run" ]] && DRY=1

B=$'\e[1m'; GRN=$'\e[32m'; RED=$'\e[31m'; DIM=$'\e[2m'; R=$'\e[0m'
step() { printf '\n%s▸ %s%s\n' "$B" "$1" "$R"; }
die()  { printf '\n%s%s%s\n' "$RED" "$1" "$R"; exit 1; }

step "Credentials"
aws sts get-caller-identity --query Arn --output text 2>/dev/null \
  || die "AWS credentials are not valid. Re-auth (Isengard / ada credentials update) and re-run."

step "Context"
kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT}:cluster/${CLUSTER}"

step "Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update prometheus-community grafana >/dev/null
printf '%s  added/updated%s\n' "$DIM" "$R"

if [[ -n "$DRY" ]]; then
  step "Would now: helm upgrade --install $RELEASE -> ns/$NS, then apply servicemonitor.yaml"
  printf '%s  Re-run without --dry-run to execute.%s\n' "$DIM" "$R"
  exit 0
fi

# `upgrade --install` rather than `install` so a second run is not an error. The
# retention/resource caps keep this from becoming the biggest thing on a 2-node
# demo cluster -- Prometheus defaults are sized for real clusters.
step "kube-prometheus-stack"
helm upgrade --install "$RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=24h \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --wait --timeout 15m

step "ServiceMonitor for Karpenter"
kubectl apply -f "${HERE}/servicemonitor.yaml"

step "Confirm Prometheus picked up the Karpenter target"
printf '%s  Targets take ~30-60s to register. Checking...%s\n' "$DIM" "$R"
sleep 45
if kubectl get servicemonitor -n "$NS" karpenter >/dev/null 2>&1; then
  printf '%s  ServiceMonitor exists.%s\n' "$GRN" "$R"
else
  die "ServiceMonitor missing -- apply failed."
fi

PW=$(kubectl get secret "${RELEASE}-grafana" -n "$NS" -o jsonpath='{.data.admin-password}' | base64 --decode)

cat <<EOF

${GRN}Monitoring is up.${R}

  Grafana:   kubectl port-forward svc/${RELEASE}-grafana 3000:80 -n ${NS}
             http://localhost:3000/login
             user: admin
             pass: ${PW}

  Import the prebuilt dashboard instead of hand-building panels:
    Grafana > Dashboards > New > Import > Upload JSON file
    ${HERE}/dashboard.json

  Verify the Karpenter scrape target is UP:
    kubectl port-forward svc/${RELEASE}-prometheus 9090:9090 -n ${NS}
    open http://localhost:9090/targets   # look for serviceMonitor/monitoring/karpenter

  Next: ./enable-profiling.sh   (pprof is off by default)
EOF
