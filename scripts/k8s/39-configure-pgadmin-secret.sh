#!/usr/bin/env bash
# Create the pgAdmin web login Secret outside Git before Argo CD deploys it.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-pgadmin-admin-credentials}"

cleanup() {
  unset PGADMIN_PASSWORD
}
trap cleanup EXIT

if [[ -z "${PGADMIN_EMAIL:-}" ]]; then
  read -r -p "pgAdmin login email: " PGADMIN_EMAIL
fi

if [[ -z "${PGADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "pgAdmin login password: " PGADMIN_PASSWORD
  echo
fi

if [[ -z "${PGADMIN_EMAIL}" || -z "${PGADMIN_PASSWORD}" ]]; then
  echo "Both the pgAdmin email and password are required." >&2
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=email="${PGADMIN_EMAIL}" \
  --from-literal=password="${PGADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "pgAdmin login Secret configured in ${NAMESPACE}/${SECRET_NAME}."
