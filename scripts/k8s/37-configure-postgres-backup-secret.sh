#!/usr/bin/env bash
# Create the Secret CNPG uses to authenticate its Barman Cloud backups against
# the MinIO Tenant's S3 API, outside Git.
#
# For this personal lab, reuse the MinIO root credentials
# (scripts/k8s/35-configure-minio-root-secret.sh) as the values here. Create a
# dedicated least-privilege MinIO user instead if that ever matters to you.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-postgres-backup-s3-creds}"

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset MINIO_ACCESS_KEY MINIO_SECRET_KEY
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${MINIO_ACCESS_KEY:-}" ]]; then
  read -r -p "MinIO access key: " MINIO_ACCESS_KEY
fi

if [[ -z "${MINIO_SECRET_KEY:-}" ]]; then
  read -r -s -p "MinIO secret key: " MINIO_SECRET_KEY
  echo
fi

if [[ -z "${MINIO_ACCESS_KEY}" || -z "${MINIO_SECRET_KEY}" ]]; then
  echo "Both the MinIO access key and secret key are required." >&2
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=ACCESS_KEY_ID="${MINIO_ACCESS_KEY}" \
  --from-literal=ACCESS_SECRET_KEY="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Postgres backup S3 credential Secret configured in namespace ${NAMESPACE}."
echo "Verify with: kubectl -n ${NAMESPACE} get secret ${SECRET_NAME}"
