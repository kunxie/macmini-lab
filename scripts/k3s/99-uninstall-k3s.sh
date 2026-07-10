#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Require an exact confirmation because uninstalling K3s is disruptive.
echo "This removes K3s from the VM but does not remove external data volumes."
read -r -p "Type 'uninstall k3s' to continue: " confirmation

if [[ "${confirmation}" != "uninstall k3s" ]]; then
  echo "Aborted."
  exit 1
fi

sudo /usr/local/bin/k3s-uninstall.sh
