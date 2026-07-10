#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Use "stable" by default; set ARGOCD_VERSION=vX.Y.Z to pin a release.
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

# --dry-run=client makes namespace creation idempotent.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Production setups should pin a version instead of tracking stable.
if [[ "${ARGOCD_VERSION}" == "stable" ]]; then
  manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
else
  manifest_url="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
fi

kubectl apply -n argocd --server-side --force-conflicts -f "${manifest_url}"

echo "Argo CD install submitted."
echo "Check status with: kubectl -n argocd get pods"
