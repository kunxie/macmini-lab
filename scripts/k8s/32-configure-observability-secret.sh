#!/usr/bin/env bash
# Create the Grafana credential outside Git before Argo CD deploys the chart.
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  echo "Set GRAFANA_ADMIN_PASSWORD before running this script."
  echo "Example: GRAFANA_ADMIN_PASSWORD='a-long-random-password' $0"
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create secret generic grafana-admin-credentials \
  --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
  --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Grafana admin Secret configured in namespace ${NAMESPACE}."
