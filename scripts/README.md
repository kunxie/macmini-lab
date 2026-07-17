# Script Execution Order

Script numbers are unique across the repository. For the initial installation,
you normally run only `00`, complete the interactive Ubuntu installation, run
`10`, install Argo CD with `30`, create the required external Secrets with `32`
and `38`, then bootstrap GitOps with `33`.

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
| 31 | `scripts/k8s/31-install-observability.sh` | Ubuntu VM | Manual recovery path; installs the pinned observability charts without Argo CD. |
| 32 | `scripts/k8s/32-configure-observability-secret.sh` | Ubuntu VM | Creates or updates Grafana credentials outside Git. |
| 33 | `scripts/k8s/33-bootstrap-gitops.sh` | Ubuntu VM | Registers the root Argo CD Application after the Git changes are pushed. |
| 34 | `scripts/k8s/34-configure-tailscale-operator-secret.sh` | Ubuntu VM | Interactively creates or updates the Tailscale Operator OAuth Secret outside Git. |
| 35 | `scripts/k8s/35-configure-minio-root-secret.sh` | Ubuntu VM | Creates or updates the MinIO root credentials outside Git. |
| 36 | `scripts/k8s/36-configure-minio-app-secret.sh` | Ubuntu VM | Creates an app-scoped MinIO user, bucket policy, and credentials. |
| 37 | `scripts/k8s/37-configure-postgres-backup-secret.sh` | Ubuntu VM | Creates a bucket-scoped MinIO user for PostgreSQL backups. |
| 38 | `scripts/k8s/38-configure-postgres-app-secret.sh` | Ubuntu VM | Creates and safely verifies the two app-scoped PostgreSQL credential Secrets. |
| 39 | `scripts/k8s/39-configure-pgadmin-secret.sh` | Ubuntu VM | Creates or updates the pgAdmin web login outside Git. |
| 40 | `scripts/k8s/40-install-cloudflared.sh` | Ubuntu VM | Optional later, after obtaining a domain and tunnel token. |
| 41 | `scripts/k8s/41-validate-job-info-collector.sh` | Workstation or CI | Renders and validates collector release and migration contracts. |
| 42 | `scripts/k8s/42-validate-headlamp.sh` | Workstation or CI | Renders and validates the pinned Headlamp chart. |
| 43 | `scripts/k8s/43-test-job-info-collector-validator.sh` | Workstation or CI | Runs deterministic collector-validator regression and negative tests. |
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
GRAFANA_ADMIN_PASSWORD='choose-a-password' ./scripts/k8s/32-configure-observability-secret.sh
APP_NAME=job-info-collector ./scripts/k8s/38-configure-postgres-app-secret.sh
./scripts/k8s/33-bootstrap-gitops.sh
```

Run `38` before `33` even though its number is higher: the PostgreSQL Cluster
and collector migration Job both reference those externally managed Secrets
during their first reconciliation. Re-running `38` rotates both copies
together and verifies their types and key names without printing values.

Script `31` remains available when Argo CD is unavailable. Do not manage the
same observability releases with script `31` and Argo CD at the same time.
