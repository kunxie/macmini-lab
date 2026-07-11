#!/usr/bin/env bash
# Create the MinIO Tenant root credential Secret outside Git before Argo CD
# deploys the Tenant.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-minio-root-credentials}"

if [[ -z "${MINIO_ROOT_USER:-}" ]]; then
  echo "Set MINIO_ROOT_USER before running this script."
  echo "Example: MINIO_ROOT_USER='choose-a-username' MINIO_ROOT_PASSWORD='a-long-random-password' $0"
  exit 1
fi

if [[ -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
  echo "Set MINIO_ROOT_PASSWORD before running this script."
  echo "Example: MINIO_ROOT_USER='choose-a-username' MINIO_ROOT_PASSWORD='a-long-random-password' $0"
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
