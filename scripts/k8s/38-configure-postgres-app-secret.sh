#!/usr/bin/env bash
# Create the database credentials for one app that connects to the shared
# Postgres Cluster, outside Git. Writes the same credential to two places:
#
#   - <postgres-namespace>/<app-name>-db-credentials: a kubernetes.io/basic-auth
#     Secret consumed by the Cluster's declarative "roles" entry (see
#     cluster.values.yaml). CNPG requires this Secret to live in the same
#     namespace as the Cluster, not the app's namespace.
#   - <app-namespace>/<app-name>-db-credentials: the same username/password
#     plus host/port/dbname/uri, for the app's own Deployment to mount.
set -euo pipefail

POSTGRES_NAMESPACE="${POSTGRES_NAMESPACE:-data}"
POSTGRES_CLUSTER="${POSTGRES_CLUSTER:-postgres}"

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

kubectl -n "${APP_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${DB_PASSWORD}" \
  --from-literal=host="${HOST}" \
  --from-literal=port="5432" \
  --from-literal=dbname="${DB_NAME}" \
  --from-literal=uri="postgresql://${DB_USER}:${DB_PASSWORD}@${HOST}:5432/${DB_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Database credentials for '${APP_NAME}' configured:"
echo "  - ${POSTGRES_NAMESPACE}/${SECRET_NAME} (consumed by the Cluster's declarative role)"
echo "  - ${APP_NAMESPACE}/${SECRET_NAME} (mount this in the app's Deployment)"
