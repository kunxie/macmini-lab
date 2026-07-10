#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Keep observability isolated in its own namespace.
NAMESPACE="${NAMESPACE:-observability}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-86.0.0}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-18.4.2}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.10.0}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

if ! kubectl -n "${NAMESPACE}" get secret grafana-admin-credentials >/dev/null 2>&1; then
  echo "Grafana credentials are not configured."
  echo "Run scripts/k8s/32-configure-observability-secret.sh first."
  exit 1
fi

# Idempotently create the namespace.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Helm repos provide the charts for Prometheus, Grafana, Loki, and Alloy.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update

# Metrics stack: Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --version "${PROMETHEUS_CHART_VERSION}" \
  --values "${repo_root}/k8s/infra/observability/kube-prometheus-stack.values.yaml"

# Log storage.
helm upgrade --install loki grafana-community/loki \
  --namespace "${NAMESPACE}" \
  --version "${LOKI_CHART_VERSION}" \
  --values "${repo_root}/k8s/infra/observability/loki.values.yaml"

# Log collector running on each node.
helm upgrade --install alloy grafana/alloy \
  --namespace "${NAMESPACE}" \
  --version "${ALLOY_CHART_VERSION}" \
  --values "${repo_root}/k8s/infra/observability/alloy.values.yaml"

echo "Observability install submitted."
echo "Check status with: kubectl -n ${NAMESPACE} get pods,pvc"
echo "Access Grafana over Tailscale with:"
echo "  kubectl -n ${NAMESPACE} port-forward --address=\"\$(tailscale ip -4)\" svc/kube-prometheus-stack-grafana 3000:80"
