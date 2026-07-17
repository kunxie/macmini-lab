#!/usr/bin/env bash
# Create the database credentials for one app that connects to the shared
# Postgres Cluster, outside Git. Writes the same credential to two places:
#
#   - <postgres-namespace>/<app-name>-db-credentials: a kubernetes.io/basic-auth
#     Secret consumed by the Cluster's declarative "roles" entry (see
#     cluster.values.yaml). CNPG requires this Secret to live in the same
#     namespace as the Cluster, not the app's namespace.
#   - <app-namespace>/<app-name>-db-credentials: the same username/password
#     plus host/port/dbname, for the app's workloads to reference explicitly.
set -euo pipefail

POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-data}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-postgres}"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required." >&2
  exit 1
}

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset DB_PASSWORD
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${APP_NAME:-}" ]]; then
  read -r -p "App name (also the default namespace, database, and role): " APP_NAME
fi

if [[ -z "${DB_PASSWORD:-}" ]]; then
  read -r -s -p "Database password: " DB_PASSWORD
  echo
fi

if [[ -z "${APP_NAME}" || -z "${DB_PASSWORD}" ]]; then
  echo "Both the app name and database password are required." >&2
  exit 1
fi

APP_NAMESPACE="${APP_NAMESPACE:-${APP_NAME}}"
DB_NAME="${DB_NAME:-${APP_NAME}}"
DB_USER="${DB_USER:-${APP_NAME}}"
SECRET_NAME="${SECRET_NAME:-${APP_NAME}-db-credentials}"

HOST="${POSTGRES_CLUSTER}-rw.${POSTGRES_NAMESPACE}.svc.cluster.local"

kubectl create namespace "${POSTGRES_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# CNPG's declarative role management requires exactly this Secret shape.
kubectl -n "${POSTGRES_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
# Ask CloudNativePG to apply password rotations immediately rather than waiting
# for a later cache refresh. The runbook still verifies the observed revision.
kubectl -n "${POSTGRES_NAMESPACE}" label secret "${SECRET_NAME}" \
  cnpg.io/reload=true --overwrite >/dev/null

kubectl -n "${APP_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${DB_PASSWORD}" \
  --from-literal=host="${HOST}" \
  --from-literal=port="5432" \
  --from-literal=dbname="${DB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Earlier revisions stored a composed connection URI. Remove that redundant
# credential explicitly so upgrades converge even when kubectl did not own the
# legacy map entry. The migration receives only the five fields above.
kubectl -n "${APP_NAMESPACE}" patch secret "${SECRET_NAME}" \
  --type=merge --patch '{"data":{"uri":null}}' >/dev/null

verify_secret_shape() {
  local namespace="$1"
  local secret_name="$2"
  local secret_type="$3"
  local expected_keys="$4"

  if ! kubectl -n "${namespace}" get secret "${secret_name}" -o json | \
    jq -e --arg secret_type "${secret_type}" \
      --argjson expected_keys "${expected_keys}" \
      '.type == $secret_type and ((.data | keys | sort) == ($expected_keys | sort))' \
      >/dev/null; then
    echo "Secret ${namespace}/${secret_name} has an unexpected type or key set." >&2
    return 1
  fi
}

# Validate only metadata and key names. Secret values are never decoded or printed.
verify_secret_shape "${POSTGRES_NAMESPACE}" "${SECRET_NAME}" \
  kubernetes.io/basic-auth '["username", "password"]'
verify_secret_shape "${APP_NAMESPACE}" "${SECRET_NAME}" Opaque \
  '["username", "password", "host", "port", "dbname"]'

echo "Database credentials for '${APP_NAME}' configured:"
echo "  - ${POSTGRES_NAMESPACE}/${SECRET_NAME} (consumed by the Cluster's declarative role)"
echo "  - ${APP_NAMESPACE}/${SECRET_NAME} (referenced by app workloads)"
echo "Secret types and key names verified without reading their values."
