#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

echo "This repo keeps Kubernetes tools inside the Ubuntu VM."
echo

# Homebrew is only used on macOS to install the VM application.
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install UTM with this script."
  echo "Install Homebrew from https://brew.sh, then rerun this script."
  exit 1
fi

# Keep the host minimal: UTM runs the Ubuntu VM; cluster tooling lives in Ubuntu.
brew update
brew install --cask utm

echo
echo "UTM installed."
