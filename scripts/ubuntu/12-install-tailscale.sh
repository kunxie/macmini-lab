#!/usr/bin/env bash
# Stop on command errors, unset variables, and failures hidden inside pipelines.
set -euo pipefail

# This script is intended for the Ubuntu VM, not the macOS host.
if [[ ! -f /etc/os-release ]]; then
  echo "Cannot identify this operating system because /etc/os-release is missing."
  exit 1
fi

# /etc/os-release defines values such as ID=ubuntu and VERSION_CODENAME=noble.
# Tailscale uses the Ubuntu codename to select the correct apt repository.
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" || -z "${VERSION_CODENAME:-}" ]]; then
  echo "This script supports Ubuntu releases with a VERSION_CODENAME."
  exit 1
fi

repo_base="https://pkgs.tailscale.com/stable/ubuntu"
keyring_path="/usr/share/keyrings/tailscale-archive-keyring.gpg"
repository_path="/etc/apt/sources.list.d/tailscale.list"

echo "Configuring the official Tailscale repository for Ubuntu ${VERSION_CODENAME}..."

# Store the repository key in a dedicated keyring instead of the deprecated
# system-wide apt-key store.
sudo install -d -m 0755 /usr/share/keyrings
curl --fail --silent --show-error --location \
  "${repo_base}/${VERSION_CODENAME}.noarmor.gpg" \
  | sudo tee "${keyring_path}" >/dev/null

# The repository file includes its own signed-by reference to the key above.
curl --fail --silent --show-error --location \
  "${repo_base}/${VERSION_CODENAME}.tailscale-keyring.list" \
  | sudo tee "${repository_path}" >/dev/null

sudo apt-get update
sudo apt-get install -y tailscale
sudo systemctl enable --now tailscaled

# Tailscale SSH lets trusted devices in this tailnet reach the Ubuntu VM without
# router port forwarding. The first run prints a URL for interactive sign-in.
tailscale_hostname="${TAILSCALE_HOSTNAME:-macmini-lab}"
sudo tailscale up --ssh --hostname="${tailscale_hostname}"

echo
echo "Tailscale is connected. Current addresses:"
tailscale ip
echo
echo "Status:"
tailscale status
