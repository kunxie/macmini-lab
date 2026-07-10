#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Base packages for operating the VM and installing third-party repositories.
sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  jq \
  vim \
  git \
  htop \
  net-tools \
  nfs-common \
  open-iscsi \
  qemu-guest-agent \
  unattended-upgrades

# Keep Tailscale as a separate, visible setup step. The optional flag remains
# available for unattended reuse of the older bootstrap command.
if [[ "${INSTALL_TAILSCALE:-false}" == "true" ]]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  "${script_dir}/12-install-tailscale.sh"
fi

# Modern apt repositories store signing keys under /etc/apt/keyrings.
sudo install -m 0755 -d /etc/apt/keyrings

# Add the official Kubernetes apt repository for kubectl.
if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# Add the Helm apt repository.
if [[ ! -f /etc/apt/keyrings/helm.gpg ]]; then
  curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
    | sudo gpg --dearmor -o /etc/apt/keyrings/helm.gpg
fi

echo 'deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main' \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubectl helm

install_bin_dir="/usr/local/bin"

# Install the Argo CD CLI from the latest GitHub release if it is missing.
if ! command -v argocd >/dev/null 2>&1; then
  arch="$(uname -m)"
  case "${arch}" in
    aarch64|arm64) argocd_arch="arm64" ;;
    x86_64|amd64) argocd_arch="amd64" ;;
    *) echo "Unsupported architecture for argocd: ${arch}"; exit 1 ;;
  esac

  curl -fsSL "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-${argocd_arch}" \
    -o /tmp/argocd
  sudo install -m 0755 /tmp/argocd "${install_bin_dir}/argocd"
  rm -f /tmp/argocd
fi

# Optional later: install cloudflared only when you have a domain/public URL.
if [[ "${INSTALL_CLOUDFLARED:-false}" == "true" ]] && ! command -v cloudflared >/dev/null 2>&1; then
  arch="$(uname -m)"
  case "${arch}" in
    aarch64|arm64) cloudflared_arch="arm64" ;;
    x86_64|amd64) cloudflared_arch="amd64" ;;
    *) echo "Unsupported architecture for cloudflared: ${arch}"; exit 1 ;;
  esac

  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cloudflared_arch}" \
    -o /tmp/cloudflared
  sudo install -m 0755 /tmp/cloudflared "${install_bin_dir}/cloudflared"
  rm -f /tmp/cloudflared
fi

# Install SOPS for encrypted secrets in Git.
if ! command -v sops >/dev/null 2>&1; then
  arch="$(uname -m)"
  case "${arch}" in
    aarch64|arm64) sops_arch="arm64" ;;
    x86_64|amd64) sops_arch="amd64" ;;
    *) echo "Unsupported architecture for sops: ${arch}"; exit 1 ;;
  esac

  sops_version="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r '.tag_name')"
  curl -fsSL "https://github.com/getsops/sops/releases/latest/download/sops-${sops_version}.linux.${sops_arch}" \
    -o /tmp/sops
  sudo install -m 0755 /tmp/sops "${install_bin_dir}/sops"
  rm -f /tmp/sops
fi

# age provides the key format commonly used with SOPS.
if ! command -v age-keygen >/dev/null 2>&1; then
  sudo apt-get install -y age
fi

# These services are useful in VMs and for future storage integrations.
sudo systemctl enable --now qemu-guest-agent || true
sudo systemctl enable --now iscsid || true

# Default to the user's current timezone, but allow override with TIMEZONE=...
sudo timedatectl set-timezone "${TIMEZONE:-America/Chicago}"

echo "Ubuntu bootstrap complete."
echo "Installed admin tools: kubectl, helm, argocd, sops, age."
echo "Next: run ./scripts/ubuntu/12-install-tailscale.sh to connect this VM to Tailscale."
echo "Optional later: run INSTALL_CLOUDFLARED=true ./scripts/ubuntu/11-bootstrap.sh to install cloudflared."
