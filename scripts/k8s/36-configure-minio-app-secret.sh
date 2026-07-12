#!/usr/bin/env bash
# Create the MinIO credentials for one app, outside Git. Writes the same
# access key/secret key to two places:
#
#   - <minio-namespace>/<app-name>-minio-credentials: CONSOLE_ACCESS_KEY /
#     CONSOLE_SECRET_KEY, the shape the Tenant's declarative "users" list
#     requires (see tenant.values.yaml). The Operator provisions this MinIO
#     user from it once Argo CD syncs the Tenant.
#   - <app-namespace>/<app-name>-minio-credentials: the same keys, renamed
#     to access-key/secret-key, plus endpoint/bucket, for the app's own
#     Deployment to mount.
#
# A user created this way starts with zero permissions -- the Tenant CRD has
# no field to attach an IAM policy. This script also creates and attaches a
# policy scoping the user to only its own bucket, using a disposable mc pod
# run inside the cluster against the MinIO root credentials. Re-running this
# script is safe; the policy step is idempotent and self-healing -- it
# detaches any other policy the user has accumulated (e.g. a broad built-in
# policy like "readwrite" attached by hand during earlier testing), so the
# user is always left with only the scoped ${APP_NAME}-rw policy.
set -euo pipefail

MINIO_NAMESPACE="${MINIO_NAMESPACE:-data}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.data.svc.cluster.local}"
MINIO_ROOT_SECRET="${MINIO_ROOT_SECRET:-minio-root-credentials}"

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset MINIO_SECRET_KEY ROOT_USER ROOT_PASSWORD CONFIG_ENV
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${APP_NAME:-}" ]]; then
  read -r -p "App name (also the default namespace, bucket, and MinIO username): " APP_NAME
fi

if [[ -z "${MINIO_SECRET_KEY:-}" ]]; then
  read -r -s -p "MinIO secret key: " MINIO_SECRET_KEY
  echo
fi

if [[ -z "${APP_NAME}" || -z "${MINIO_SECRET_KEY}" ]]; then
  echo "Both the app name and MinIO secret key are required." >&2
  exit 1
fi

APP_NAMESPACE="${APP_NAMESPACE:-${APP_NAME}}"
BUCKET_NAME="${BUCKET_NAME:-${APP_NAME}}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-${APP_NAME}}"
SECRET_NAME="${SECRET_NAME:-${APP_NAME}-minio-credentials}"

kubectl create namespace "${MINIO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# The Tenant's declarative "users" list requires exactly this Secret shape.
kubectl -n "${MINIO_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=CONSOLE_ACCESS_KEY="${MINIO_ACCESS_KEY}" \
  --from-literal=CONSOLE_SECRET_KEY="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${APP_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=access-key="${MINIO_ACCESS_KEY}" \
  --from-literal=secret-key="${MINIO_SECRET_KEY}" \
  --from-literal=endpoint="${MINIO_ENDPOINT}" \
  --from-literal=bucket="${BUCKET_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "MinIO credentials for '${APP_NAME}' configured:"
echo "  - ${MINIO_NAMESPACE}/${SECRET_NAME} (consumed by the Tenant's declarative user)"
echo "  - ${APP_NAMESPACE}/${SECRET_NAME} (mount this in the app's Deployment)"

# Scoping the policy requires the Tenant to already be Synced/Healthy (the
# user and bucket must exist in MinIO before a policy can attach to them).
if ! kubectl -n "${MINIO_NAMESPACE}" get secret "${MINIO_ROOT_SECRET}" >/dev/null 2>&1; then
  echo
  echo "Skipping policy attachment: Secret ${MINIO_NAMESPACE}/${MINIO_ROOT_SECRET} not found."
  echo "Run scripts/k8s/35-configure-minio-root-secret.sh first, then re-run this script."
  exit 0
fi

CONFIG_ENV="$(kubectl -n "${MINIO_NAMESPACE}" get secret "${MINIO_ROOT_SECRET}" -o jsonpath='{.data.config\.env}' | base64 -d)"
ROOT_USER="$(sed -n 's/^export MINIO_ROOT_USER=//p' <<<"${CONFIG_ENV}")"
ROOT_PASSWORD="$(sed -n 's/^export MINIO_ROOT_PASSWORD=//p' <<<"${CONFIG_ENV}")"

echo
echo "Scoping ${MINIO_ACCESS_KEY} to bucket ${BUCKET_NAME} only..."

kubectl run "mc-${APP_NAME}-policy" --rm -i --restart=Never --quiet \
  --namespace "${MINIO_NAMESPACE}" \
  --image=minio/mc \
  --env="ROOT_USER=${ROOT_USER}" \
  --env="ROOT_PASSWORD=${ROOT_PASSWORD}" \
  --env="MINIO_ENDPOINT=${MINIO_ENDPOINT}" \
  --env="APP_NAME=${APP_NAME}" \
  --env="BUCKET_NAME=${BUCKET_NAME}" \
  --env="MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}" \
  --command -- sh -c '
set -eu
mc alias set local "$MINIO_ENDPOINT" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null
cat >/tmp/policy.json <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ]
    }
  ]
}
POLICY
mc admin policy create local "${APP_NAME}-rw" /tmp/policy.json
mc admin policy attach local "${APP_NAME}-rw" --user="${MINIO_ACCESS_KEY}"
echo "Policy ${APP_NAME}-rw attached to ${MINIO_ACCESS_KEY}."

# "mc admin policy attach" only adds a policy; it never removes ones the
# user already had. Detach every other policy so a stray broad grant (e.g.
# "readwrite", attached by hand during earlier testing) cannot linger and
# widen this user beyond its own bucket.
CURRENT_POLICIES="$(mc admin user info local "${MINIO_ACCESS_KEY}" --json | sed -n "s/.*\"policyName\":\"\([^\"]*\)\".*/\1/p")"
OLD_IFS="$IFS"
IFS=","
for p in $CURRENT_POLICIES; do
  if [ -n "$p" ] && [ "$p" != "${APP_NAME}-rw" ]; then
    echo "Detaching stray policy ${p} from ${MINIO_ACCESS_KEY}..."
    mc admin policy detach local "$p" --user="${MINIO_ACCESS_KEY}"
  fi
done
IFS="$OLD_IFS"
'

echo "Done."
