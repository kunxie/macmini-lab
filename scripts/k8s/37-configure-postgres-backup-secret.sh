#!/usr/bin/env bash
# Create a dedicated least-privilege MinIO user for CloudNativePG backups and
# store its credentials in the Secret consumed by the Postgres Cluster.
set -euo pipefail

NAMESPACE="${NAMESPACE:-data}"
SECRET_NAME="${SECRET_NAME:-postgres-backup-s3-creds}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.data.svc.cluster.local}"
MINIO_ROOT_SECRET="${MINIO_ROOT_SECRET:-minio-root-credentials}"
BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-postgres-backup}"
BACKUP_BUCKET="${BACKUP_BUCKET:-postgres-backups}"
POLICY_NAME="${POLICY_NAME:-postgres-backup-rw}"

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset BACKUP_SECRET_KEY ROOT_USER ROOT_PASSWORD CONFIG_ENV
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${BACKUP_SECRET_KEY:-}" ]]; then
  read -r -s -p "Secret key for MinIO user '${BACKUP_ACCESS_KEY}': " BACKUP_SECRET_KEY
  echo
fi

if [[ -z "${BACKUP_ACCESS_KEY}" || -z "${BACKUP_SECRET_KEY}" ]]; then
  echo "Both the backup access key and secret key are required." >&2
  exit 1
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n "${NAMESPACE}" get secret "${MINIO_ROOT_SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NAMESPACE}/${MINIO_ROOT_SECRET} not found." >&2
  echo "Run scripts/k8s/35-configure-minio-root-secret.sh first." >&2
  exit 1
fi

CONFIG_ENV="$(kubectl -n "${NAMESPACE}" get secret "${MINIO_ROOT_SECRET}" -o jsonpath='{.data.config\.env}' | base64 -d)"
ROOT_USER="$(sed -n 's/^export MINIO_ROOT_USER=//p' <<<"${CONFIG_ENV}")"
ROOT_PASSWORD="$(sed -n 's/^export MINIO_ROOT_PASSWORD=//p' <<<"${CONFIG_ENV}")"

echo "Configuring least-privilege MinIO user '${BACKUP_ACCESS_KEY}'..."

# The single-quoted script is evaluated inside the disposable mc pod.
# shellcheck disable=SC2016
kubectl run postgres-backup-minio-user --rm -i --restart=Never --quiet \
  --namespace "${NAMESPACE}" \
  --image=minio/mc \
  --env="ROOT_USER=${ROOT_USER}" \
  --env="ROOT_PASSWORD=${ROOT_PASSWORD}" \
  --env="MINIO_ENDPOINT=${MINIO_ENDPOINT}" \
  --env="BACKUP_ACCESS_KEY=${BACKUP_ACCESS_KEY}" \
  --env="BACKUP_SECRET_KEY=${BACKUP_SECRET_KEY}" \
  --env="BACKUP_BUCKET=${BACKUP_BUCKET}" \
  --env="POLICY_NAME=${POLICY_NAME}" \
  --command -- sh -c '
set -eu
mc alias set local "$MINIO_ENDPOINT" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null
mc admin user add local "$BACKUP_ACCESS_KEY" "$BACKUP_SECRET_KEY"
cat >/tmp/policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::${BACKUP_BUCKET}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListMultipartUploadParts",
        "s3:PutObject"
      ],
      "Resource": ["arn:aws:s3:::${BACKUP_BUCKET}/*"]
    }
  ]
}
POLICY
mc admin policy create local "$POLICY_NAME" /tmp/policy.json
mc admin policy attach local "$POLICY_NAME" --user="$BACKUP_ACCESS_KEY"
echo "Policy $POLICY_NAME attached to $BACKUP_ACCESS_KEY."
'

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=ACCESS_KEY_ID="${BACKUP_ACCESS_KEY}" \
  --from-literal=ACCESS_SECRET_KEY="${BACKUP_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Postgres backup credentials configured in ${NAMESPACE}/${SECRET_NAME}."
echo "The MinIO user can access only the '${BACKUP_BUCKET}' bucket."
