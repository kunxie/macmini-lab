#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Keep observability isolated in its own namespace.
NAMESPACE="${NAMESPACE:-observability}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-change-me}"

# Idempotently create the namespace.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Helm repos provide the charts for Prometheus, Grafana, Loki, and Alloy.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Metrics stack: Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics.
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --values k8s/infra/observability/kube-prometheus-stack.values.yaml \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}"

# Log storage.
helm upgrade --install loki grafana/loki \
  --namespace "${NAMESPACE}" \
  --values k8s/infra/observability/loki.values.yaml

# Log collector running on each node.
helm upgrade --install alloy grafana/alloy \
  --namespace "${NAMESPACE}" \
  --values k8s/infra/observability/alloy.values.yaml

echo "Observability install submitted."
echo "Check status with: kubectl -n ${NAMESPACE} get pods,pvc"
echo "Access Grafana with: kubectl -n ${NAMESPACE} port-forward svc/kube-prometheus-stack-grafana 3000:80"
