# macOS Host Setup

The Mac mini stays as the host OS. Kubernetes runs inside an Ubuntu ARM64 VM.
Use the Mac mini as a deployment appliance, not as a daily development machine.

## Host Power Settings

The `00-prepare-macos.sh` entry point applies these power settings through its
numbered `03-configure-host-power.sh` stage:

- Enable automatic startup after power failure.
- Disable sleep while plugged in.
- Turn off only the display after 15 minutes.

To rerun only the power configuration:

```bash
DISPLAY_SLEEP_MINUTES=15 ./scripts/macos/03-configure-host-power.sh
```

System sleep is disabled, but display sleep and the lock screen remain enabled.
Locking macOS or allowing the display to turn off does not stop the Ubuntu VM.

Configure these security and access choices manually:

- Enable remote access you are comfortable with for emergency host maintenance,
  such as Screen Sharing.
- Keep FileVault and normal macOS updates enabled.

## Host Tools

Keep macOS simple. You do not need `kubectl`, `helm`, `argocd`, `age`, or `sops`
on macOS for the initial setup. Those tools are installed inside the Ubuntu VM
by `scripts/ubuntu/11-bootstrap.sh`.

Run the main macOS preparation script:

```bash
./scripts/00-prepare-macos.sh
```

It calls `01-install-host-tools.sh` to install UTM with Homebrew,
`02-download-ubuntu-iso.sh` to download and verify Ubuntu Server ARM64, and
`03-configure-host-power.sh` to configure always-on host power behavior.

The ISO is saved under `~/Downloads/macmini-lab/`, outside this Git repository.
Continue with [02-ubuntu-vm.md](02-ubuntu-vm.md) to create the VM and run the
Ubuntu installer.

Day-to-day Kubernetes admin commands should run inside the Ubuntu VM or from
your development machines over Tailscale.

## VM Auto-Start

After the UTM VM has been created and named `macmini-lab`, run on macOS:

```bash
./scripts/macos/04-enable-utm-autostart.sh
```

This installs a per-user LaunchAgent that starts the VM whenever that macOS user
logs in. With FileVault enabled, a person must still log in once after a complete
restart; locking the screen afterward does not stop the VM.

## VM Recommendation

Use UTM to create an Ubuntu Server ARM64 VM:

- CPU: 6 cores
- RAM: 10 GB
- Disk: 120 GB maximum (UTM creates a sparse disk that grows as it is used)
- Network: NAT is acceptable; bridged is optional

Since you do not control the router, do not depend on DHCP reservations or port
forwarding. NAT networking is fine if the VM can make outbound connections to
Tailscale, GitHub, container registries, and Cloudflare.

Do not add an external data disk yet. Start with the VM disk on the Mac mini
internal storage, then add an external SSD once storage pressure is real.
