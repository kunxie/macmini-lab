#!/usr/bin/env bash
# Create the Secret CNPG uses to authenticate its Barman Cloud backups against
# the MinIO Tenant's S3 API, outside Git.
#
# For this personal lab, reuse the MinIO root credentials
# (scripts/k8s/35-configure-minio-secret.sh) as the values here. Create a
# dedicated least-privilege MinIO user instead if that ever matters to you.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-postgres-backup-s3-creds}"

if [[ -z "${MINIO_ACCESS_KEY:-}" || -z "${MINIO_SECRET_KEY:-}" ]]; then
  echo "Set MINIO_ACCESS_KEY and MINIO_SECRET_KEY before running this script."
  echo "Example: MINIO_ACCESS_KEY='admin' MINIO_SECRET_KEY='a-long-random-password' $0"
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=ACCESS_KEY_ID="${MINIO_ACCESS_KEY}" \
  --from-literal=ACCESS_SECRET_KEY="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Postgres backup S3 credential Secret configured in namespace ${NAMESPACE}."
echo "Verify with: kubectl -n ${NAMESPACE} get secret ${SECRET_NAME}"
