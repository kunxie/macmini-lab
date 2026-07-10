# Mac Mini Lab

Personal deployment lab for a 2024 Mac mini M4. The target setup is a macOS host
running an Ubuntu ARM64 VM with a single-node K3s cluster.

This repo is meant to be the source of truth for setup notes, reusable scripts,
and Kubernetes manifests.

The Mac mini is deployment-only. Development happens from a MacBook Air and an
Ubuntu 24.04/WSL machine.

## Target Architecture

```text
Mac mini macOS host
  Ubuntu ARM64 VM
    K3s single-node cluster
      Traefik ingress
      Argo CD
      Postgres
      Redis
      MinIO
      personal apps

Developer machines
  MacBook Air
  Ubuntu 24.04 / WSL
```

## Setup Order

The setup has two executable entry points because macOS is the host and Ubuntu
is a separate guest operating system.

1. On macOS, install UTM, download the verified Ubuntu ARM64 installer, and
   configure always-on host power settings:

   ```bash
   ./scripts/00-prepare-macos.sh
   ```

2. After `00` finishes, open UTM from the macOS Applications folder. Click `+`,
   then select `Virtualize` and `Linux`. Use Apple Virtualization if UTM shows
   that option, and select the ARM64 ISO from:

   ```text
   ~/Downloads/macmini-lab/ubuntu-24.04.x-live-server-arm64.iso
   ```

   Configure the VM with:

   ```text
   Name:     macmini-lab
   CPU:      6 cores
   Memory:   10240 MiB (10 GB)
   Storage:  120 GB
   Network:  Shared/NAT
   ```

3. Start the VM and complete the interactive Ubuntu installer:

   - Select the standard `Ubuntu Server` installation.
   - Keep the default DHCP network configuration and Ubuntu package mirror.
   - Leave the proxy empty.
   - Select `Use an entire disk`. This is the UTM virtual disk, not the macOS
     disk.
   - Set the hostname to `macmini-lab` and create your Linux username/password.
   - Skip Ubuntu Pro and optional server snaps.
   - Enable `Install OpenSSH server`.
   - Finish the installation and reboot.

   If the installer starts again after reboot, stop the VM, eject the Ubuntu ISO
   from UTM's removable-drive menu, and start the VM again. The detailed version
   is in [docs/02-ubuntu-vm.md](docs/02-ubuntu-vm.md).

4. Log in to Ubuntu through the UTM console and update it:

   ```bash
   sudo apt update
   sudo apt upgrade -y
   sudo reboot
   ```

5. Make this repository available inside Ubuntu. If it has been pushed to a Git
   remote, clone it inside Ubuntu:

   ```bash
   git clone YOUR_GIT_REPOSITORY_URL ~/macmini-lab
   ```

   To copy the current local repository instead, run `hostname -I` inside Ubuntu
   to find its VM IP, then run this from macOS:

   ```bash
   scp -r /Users/kunxie/Projects/macmini-lab YOUR_UBUNTU_USER@VM_IP:~/
   ```

6. From the repository root inside Ubuntu, run the Ubuntu setup entry point:

   ```bash
   cd ~/macmini-lab
   ./scripts/10-setup-ubuntu.sh
   ```

   This installs the Ubuntu tools, connects Tailscale, and installs K3s. Open the
   Tailscale sign-in URL when the script prints it.

7. Back in macOS, enable automatic VM startup at login:

   ```bash
   cd /Users/kunxie/Projects/macmini-lab
   ./scripts/macos/04-enable-utm-autostart.sh
   ```

8. Install Argo CD, create the Grafana Secret, and bootstrap the GitOps root
   Application inside Ubuntu. Push the GitOps files to `main` before the final
   command because Argo CD reads the public GitHub repository:

   ```bash
   ./scripts/k8s/30-install-argocd.sh
   GRAFANA_ADMIN_PASSWORD='choose-a-password' ./scripts/k8s/32-configure-observability-secret.sh
   ./scripts/k8s/33-bootstrap-gitops.sh
   ```

9. Skip external storage for now. When the internal disk becomes tight, mount an
   external SSD:

   ```bash
   sudo DATA_DEVICE=/dev/disk/by-id/YOUR_DISK DATA_MOUNT=/mnt/data ./scripts/ubuntu/80-mount-data-disk.sh
   ```

10. Add infra charts and app manifests under `k8s/`.
11. Later, after you have a domain/public URL, add Cloudflare Tunnel:

   ```bash
   TUNNEL_TOKEN=ey... make cloudflared-install
   ```

## Repository Layout

```text
docs/                 Runbooks and design notes
scripts/macos/        Scripts run on the macOS host
scripts/ubuntu/       Scripts run inside the Ubuntu VM; includes admin tools
scripts/k3s/          K3s lifecycle scripts
scripts/k8s/          Kubernetes add-on installation scripts
k8s/                  Cluster manifests, Helm values, and app definitions
```

See [scripts/README.md](scripts/README.md) for the globally numbered execution
order and an explanation of which scripts are optional.

## Namespace Strategy

Use namespaces as lifecycle, ownership, and access boundaries. Do not create a
namespace for every individual pod or minor component.

```text
kube-system      K3s system components
argocd           Argo CD deployment control plane
observability    Prometheus, Grafana, Loki, Alloy, and Alertmanager
tailscale        Tailscale Operator and private ingress proxies
data             Shared Postgres, Redis, and MinIO services
<app-name>       Resources owned by one deployed application
```

Prometheus, Grafana, Loki, Alloy, and Alertmanager share the `observability`
namespace because they form one operational stack. Argo CD uses its own
`argocd` namespace because it manages deployments across the cluster.

Start shared stateful services in a single `data` namespace, and install each
service only when an application requires it. Split Postgres, Redis, or MinIO
into dedicated namespaces later if they need independent access policies,
backup procedures, or upgrade lifecycles. Give each application its own
namespace so its Deployments, Services, ConfigMaps, and Secrets remain grouped.

Namespaces separate resource names and provide boundaries for RBAC, quotas, and
NetworkPolicies. They do not automatically provide physical storage isolation,
runtime isolation, network isolation without policies, or CPU and memory limits
without resource settings.

## Assumptions

- This is for personal usage, not high availability.
- The Kubernetes node runs Linux in a VM, not directly on macOS.
- Persistent data can start on the internal disk. Add an external SSD when space
  becomes the real constraint.
- No router access or public domain is assumed. Use Tailscale for private admin
  access now. Add Cloudflare Tunnel later when you have a domain/public URL.
