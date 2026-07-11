#!/usr/bin/env bash
# Create the MinIO Tenant root credential Secret outside Git before Argo CD
# deploys the Tenant.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-minio-root-credentials}"

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset MINIO_ROOT_USER MINIO_ROOT_PASSWORD
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${MINIO_ROOT_USER:-}" ]]; then
  read -r -p "MinIO root username: " MINIO_ROOT_USER
fi

if [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
  read -r -s -p "MinIO root password: " MINIO_ROOT_PASSWORD
  echo
fi

if [[ -z "${MINIO_ROOT_USER}" || -z "${MINIO_ROOT_PASSWORD}" ]]; then
  echo "Both the MinIO root username and password are required." >&2
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# The MinIO Tenant chart expects a "config.env" key of shell export statements,
# not discrete literal keys.
kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=config.env="export MINIO_ROOT_USER=${MINIO_ROOT_USER}
export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "MinIO root credential Secret configured in namespace ${NAMESPACE}."
echo "Verify with: kubectl -n ${NAMESPACE} get secret ${SECRET_NAME}"
