# Script Execution Order

Script numbers are unique across the repository. For the initial installation,
you normally run only `00`, complete the interactive Ubuntu installation, run
`10`, and then install add-ons with `30` and `31`.

| Number | Script | Run in | When to use it |
| --- | --- | --- | --- |
| 00 | `scripts/00-prepare-macos.sh` | macOS | First. Prepares the host by running `01`, `02`, and `03`. |
| 01 | `scripts/macos/01-install-host-tools.sh` | macOS | Called by `00`; installs UTM with Homebrew. |
| 02 | `scripts/macos/02-download-ubuntu-iso.sh` | macOS | Called by `00`; downloads and verifies Ubuntu ARM64. |
| 03 | `scripts/macos/03-configure-host-power.sh` | macOS | Called by `00`; prevents host sleep and enables automatic recovery. |
| 04 | `scripts/macos/04-enable-utm-autostart.sh` | macOS | After creating the VM; starts it automatically at macOS login. |
| 10 | `scripts/10-setup-ubuntu.sh` | Ubuntu VM | After Ubuntu is installed; runs `11`, `12`, and `20`. |
| 11 | `scripts/ubuntu/11-bootstrap.sh` | Ubuntu VM | Called by `10`; installs Linux administration tools. |
| 12 | `scripts/ubuntu/12-install-tailscale.sh` | Ubuntu VM | Called by `10`; connects the VM to your tailnet. |
| 20 | `scripts/k3s/20-install-k3s.sh` | Ubuntu VM | Called by `10`; installs the single-node K3s cluster. |
| 30 | `scripts/k8s/30-install-argocd.sh` | Ubuntu VM | After `10`; installs Argo CD. |
| 31 | `scripts/k8s/31-install-observability.sh` | Ubuntu VM | After `30`; installs Prometheus, Grafana, Loki, and Alloy. |
| 40 | `scripts/k8s/40-install-cloudflared.sh` | Ubuntu VM | Optional later, after obtaining a domain and tunnel token. |
| 80 | `scripts/ubuntu/80-mount-data-disk.sh` | Ubuntu VM | Optional later, when adding an external SSD. |
| 90 | `scripts/k8s/90-uninstall-observability.sh` | Ubuntu VM | Removes observability releases but keeps their PVCs. |
| 99 | `scripts/k3s/99-uninstall-k3s.sh` | Ubuntu VM | Destructive recovery action; removes K3s after confirmation. |

## Initial Installation

On macOS:

```bash
./scripts/00-prepare-macos.sh
```

After creating the VM and completing the Ubuntu installer, return to macOS and
enable VM auto-start:

```bash
./scripts/macos/04-enable-utm-autostart.sh
```

Then run inside Ubuntu:

```bash
./scripts/10-setup-ubuntu.sh
./scripts/k8s/30-install-argocd.sh
GRAFANA_ADMIN_PASSWORD='choose-a-password' ./scripts/k8s/31-install-observability.sh
```
