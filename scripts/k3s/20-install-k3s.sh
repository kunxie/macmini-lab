#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Environment variables let you override defaults without editing the script.
K3S_CHANNEL="${K3S_CHANNEL:-stable}"
K3S_NODE_NAME="${K3S_NODE_NAME:-macmini-lab}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"

# Build install arguments as an array so values with special characters stay safe.
install_args=(
  "--node-name=${K3S_NODE_NAME}"
)

# Keep the default data directory now; allow moving it to another disk later.
if [[ "${K3S_DATA_DIR}" != "/var/lib/rancher/k3s" ]]; then
  sudo mkdir -p "${K3S_DATA_DIR}"
  install_args+=("--data-dir=${K3S_DATA_DIR}")
fi

# Official K3s installer. It installs and starts the systemd service.
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -s - server "${install_args[@]}"

# Copy kubeconfig to the current user so kubectl works without sudo.
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"

kubectl get nodes -o wide

echo "K3s installed."
