#!/usr/bin/env bash
# Configure the Ubuntu VM as the Mac mini's single K3s deployment node.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

if [[ "$(uname -s)" != "Linux" || ! -f /etc/os-release ]]; then
  echo "Run this script inside the Ubuntu VM, not in macOS."
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This setup script supports Ubuntu only."
  exit 1
fi

echo "Stage 1/3: installing Ubuntu administration tools..."
"${script_dir}/ubuntu/11-bootstrap.sh"

echo
echo "Stage 2/3: connecting the VM to Tailscale..."
echo "The first run will print a URL for signing in to your tailnet."
"${script_dir}/ubuntu/12-install-tailscale.sh"

echo
echo "Stage 3/3: installing the single-node K3s cluster..."
"${script_dir}/k3s/20-install-k3s.sh"

echo
echo "Ubuntu node setup is complete."
echo "Repository: ${repo_root}"
echo "Next add-ons:"
echo "  ${script_dir}/k8s/30-install-argocd.sh"
echo "  GRAFANA_ADMIN_PASSWORD='choose-a-password' ${script_dir}/k8s/31-install-observability.sh"
