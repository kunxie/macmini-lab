#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"

# Helm uninstall removes workloads, but PVCs are intentionally left behind.
echo "This uninstalls observability Helm releases but leaves PVCs behind."
read -r -p "Type 'uninstall observability' to continue: " confirmation

if [[ "${confirmation}" != "uninstall observability" ]]; then
  echo "Aborted."
  exit 1
fi

helm uninstall alloy --namespace "${NAMESPACE}" --ignore-not-found
helm uninstall loki --namespace "${NAMESPACE}" --ignore-not-found
helm uninstall kube-prometheus-stack --namespace "${NAMESPACE}" --ignore-not-found

echo "Observability releases removed. PVCs remain in namespace ${NAMESPACE}."
