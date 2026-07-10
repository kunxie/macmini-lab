#!/usr/bin/env bash
# Configure the Mac mini to remain available as an always-on deployment host.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this script in macOS on the Mac mini."
  exit 1
fi

# The display can turn off without suspending UTM or the Ubuntu VM. Override the
# default with, for example: DISPLAY_SLEEP_MINUTES=30 ./this-script.sh
display_sleep_minutes="${DISPLAY_SLEEP_MINUTES:-15}"

if [[ ! "${display_sleep_minutes}" =~ ^[0-9]+$ ]]; then
  echo "DISPLAY_SLEEP_MINUTES must be a non-negative whole number."
  exit 1
fi

echo "Administrator access is required to change macOS power settings."
sudo -v

# Disable whole-system sleep. Locking the screen or turning off the display does
# not stop UTM as long as the Mac itself does not sleep.
sudo systemsetup -setsleep Never

# Recover automatically after common host-level failures.
sudo systemsetup -setrestartpowerfailure on
sudo systemsetup -setrestartfreeze on

# Wake-on-network is useful for host maintenance on networks that support it.
sudo systemsetup -setwakeonnetworkaccess on

# Apply the same policy directly through macOS power management:
#   sleep 0       - never suspend the whole Mac
#   disksleep 0   - do not idle attached disks
#   displaysleep  - turn off only the display after the selected delay
#   womp 1        - enable wake on network access
#   autorestart 1 - restart after power is restored
sudo pmset -a \
  sleep 0 \
  disksleep 0 \
  displaysleep "${display_sleep_minutes}" \
  womp 1 \
  autorestart 1

echo
echo "macOS host power configuration is complete."
echo "The display may turn off and the screen may be locked; the VM keeps running."
echo
echo "Current AC power settings:"
pmset -g custom
