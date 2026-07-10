#!/usr/bin/env bash
# Register the root Application that discovers child Applications from Git.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"

kubectl apply -f "${repo_root}/k8s/argocd/root-application.yaml"

echo "GitOps bootstrap applied."
echo "Check status with: kubectl -n argocd get applications"
