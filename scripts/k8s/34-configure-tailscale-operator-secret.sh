#!/usr/bin/env bash
# Create the Tailscale Operator OAuth Secret without storing credentials in Git.
set -euo pipefail

NAMESPACE="${NAMESPACE:-tailscale}"
SECRET_NAME="${SECRET_NAME:-operator-oauth}"

# Clear credentials from this process when the script exits, including on error.
cleanup() {
  unset TAILSCALE_CLIENT_ID TAILSCALE_CLIENT_SECRET
}
trap cleanup EXIT

# Environment variables support automation; interactive use avoids shell history.
if [[ -z "${TAILSCALE_CLIENT_ID:-}" ]]; then
  read -r -p "Tailscale OAuth client ID: " TAILSCALE_CLIENT_ID
fi

if [[ -z "${TAILSCALE_CLIENT_SECRET:-}" ]]; then
  read -r -s -p "Tailscale OAuth client secret: " TAILSCALE_CLIENT_SECRET
  echo
fi

if [[ -z "${TAILSCALE_CLIENT_ID}" || -z "${TAILSCALE_CLIENT_SECRET}" ]]; then
  echo "Both the Tailscale OAuth client ID and client secret are required." >&2
  exit 1
fi

# Generate YAML locally and apply it so repeated runs create or update the Secret.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=client_id="${TAILSCALE_CLIENT_ID}" \
  --from-literal=client_secret="${TAILSCALE_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Tailscale Operator OAuth Secret configured in namespace ${NAMESPACE}."
echo "Verify with: kubectl -n ${NAMESPACE} get secret ${SECRET_NAME}"
