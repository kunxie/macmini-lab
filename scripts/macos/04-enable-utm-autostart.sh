#!/usr/bin/env bash
# Start the Ubuntu UTM VM automatically whenever this macOS user logs in.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this script in macOS on the Mac mini."
  exit 1
fi

if [[ ! -d /Applications/UTM.app ]]; then
  echo "UTM is not installed under /Applications. Run script 00 first."
  exit 1
fi

# Keep the name URL-safe because UTM receives it through its utm:// URL scheme.
# Override with VM_NAME=another-safe-name when the VM has a different name.
vm_name="${VM_NAME:-macmini-lab}"
if [[ ! "${vm_name}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "VM_NAME may contain only letters, numbers, periods, underscores, and hyphens."
  exit 1
fi

launch_agents_dir="${HOME}/Library/LaunchAgents"
label="io.macmini-lab.start-utm-vm"
plist_path="${launch_agents_dir}/${label}.plist"
user_domain="gui/$(id -u)"

mkdir -p "${launch_agents_dir}"

# A LaunchAgent runs after this user logs in. The UTM start URL is idempotent:
# if the VM is already running, UTM leaves it running.
cat >"${plist_path}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>utm://start?name=${vm_name}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

plutil -lint "${plist_path}"

# Reload the agent when this script is rerun, then trigger it immediately so the
# configuration can be tested without restarting macOS.
launchctl bootout "${user_domain}" "${plist_path}" >/dev/null 2>&1 || true
launchctl bootstrap "${user_domain}" "${plist_path}"
launchctl kickstart -k "${user_domain}/${label}"

echo
echo "UTM auto-start is enabled for VM '${vm_name}'."
echo "It runs after this macOS user logs in: ${plist_path}"
