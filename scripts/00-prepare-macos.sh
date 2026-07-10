#!/usr/bin/env bash
# Prepare the Mac mini host for the Ubuntu VM.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this script in macOS on the Mac mini."
  exit 1
fi

echo "Stage 1/3: installing the macOS host tools..."
"${script_dir}/macos/01-install-host-tools.sh"

echo
echo "Stage 2/3: downloading and verifying Ubuntu Server ARM64..."
"${script_dir}/macos/02-download-ubuntu-iso.sh"

echo
echo "Stage 3/3: configuring the Mac mini for always-on operation..."
"${script_dir}/macos/03-configure-host-power.sh"

echo
echo "macOS preparation is complete."
echo "Next: open UTM and follow docs/02-ubuntu-vm.md to install Ubuntu once."
