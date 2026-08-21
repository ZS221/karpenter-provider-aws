#!/usr/bin/env bash
# Install kube-prometheus-stack on the A/B cluster and point it at Karpenter.
#
# Two settings here differ from a stock install and both matter for this experiment:
#
#   scrapeInterval 10s (not 30s) -- the arms are compared over ~20 minute windows and
#     the deltas we care about are a few percent. 30s scrapes give ~40 samples per
#     window, which is too few to separate a 5% shift from noise; 10s gives ~120 and
#     lets rate() use a [1m] window instead of [2m].
#
#   NO persistent volume -- emptyDir. This cluster's only StorageClass is `gp2` backed by
#     the in-tree `kubernetes.io/aws-ebs` provisioner, which Kubernetes REMOVED in 1.27;
#     this cluster is 1.36 and has no aws-ebs-csi-driver addon. A PVC here never binds, so
#     asking for one would leave Prometheus Pending forever.
#
#     The consequence is that a Prometheus restart loses history, which would otherwise put
#     four hours of results on one pod's uptime. export-window.sh therefore dumps each
#     cell's raw series to local disk immediately after that cell finishes, which makes
#     Prometheus disposable and the results incremental. That is a better arrangement than
#     a PVC regardless.

set -euo pipefail
HERE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
source "${HERE}/config.sh"

step "Credentials"
aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
  || die "AWS credentials are not valid. Re-auth and re-run."

step "Context"
ensure_kubeconfig   # private KUBECONFIG pinned to the A/B cluster; never touches ~/.kube/config
info "$(kubectl config current-context)"

step "Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
ok "updated"

step "kube-prometheus-stack -> ns/${MON_NS}"
helm upgrade --install "$MON_RELEASE" prometheus-community/kube-prometheus-stack \
  --namespace "$MON_NS" --create-namespace \
  --set prometheus.prometheusSpec.scrapeInterval=10s \
  --set prometheus.prometheusSpec.evaluationInterval=30s \
  --set prometheus.prometheusSpec.retention=12h \
  --set prometheus.prometheusSpec.retentionSize=8GB \
  --set prometheus.prometheusSpec.resources.requests.cpu=200m \
  --set prometheus.prometheusSpec.resources.requests.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.memory=3Gi \
  --set grafana.resources.requests.cpu=100m \
  --set grafana.resources.requests.memory=256Mi \
  --set grafana.persistence.enabled=false \
  --set alertmanager.enabled=false \
  --wait --timeout 20m

step "ServiceMonitor for Karpenter"
# Applied here rather than per-arm: the Service and its labels are chart-stable across
# all three arms, so one ServiceMonitor survives every swap. That is deliberate --
# re-creating it per arm would reset the scrape target's `up` series and put a gap in
# exactly the window we are measuring.
kubectl apply -f "${HERE}/../servicemonitor.yaml"

step "Grafana credentials"
PW=$(kubectl get secret "${MON_RELEASE}-grafana" -n "$MON_NS" -o jsonpath='{.data.admin-password}' | base64 --decode)
cat <<EOF

${GRN}Monitoring is up on ${CLUSTER}.${R}

  Grafana:     kubectl port-forward svc/${MON_RELEASE}-grafana 3000:80 -n ${MON_NS}
               http://localhost:3000  (admin / ${PW})
  Prometheus:  kubectl port-forward svc/${MON_RELEASE}-prometheus 9090:9090 -n ${MON_NS}

  Scrape interval is 10s. Verify the karpenter target is UP before running any arm:
    open http://localhost:9090/targets
EOF
