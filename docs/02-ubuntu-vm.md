# Ubuntu VM Setup

Use Ubuntu Server 24.04 LTS ARM64. UTM creates the virtual hardware, and the
Ubuntu installer installs Linux onto that virtual disk.

## 1. Download the Installer

Run this on the Mac mini after UTM is installed:

```bash
make ubuntu-iso
```

The script finds the latest Ubuntu 24.04 point release, downloads the standard
ARM64 server ISO to `~/Downloads/macmini-lab/`, and verifies its SHA-256 checksum.
It does not use the `amd64` image; that image is for Intel/AMD computers.

## 2. Create the VM in UTM

Open UTM and make the VM once:

1. Click `+`, then choose `Virtualize` and `Linux`.
2. Select the downloaded `ubuntu-24.04.x-live-server-arm64.iso` as the boot ISO.
3. Set CPU to 6 cores and memory to 10240 MiB (10 GB).
4. Set the virtual disk maximum to 120 GB. It is sparse, so it does not consume
   all 120 GB immediately.
5. Skip the shared directory for now.
6. Use shared/NAT networking. The VM only needs outbound network access because
   Tailscale will provide private inbound access later.
7. Name the VM `macmini-lab`, save it, and start it.

This part remains interactive because UTM needs macOS permission to create and
run the VM, and Ubuntu needs you to choose credentials.

## 3. Install Ubuntu

In the Ubuntu installer:

1. Use the normal `Ubuntu Server` installation.
2. Keep the default network configuration (DHCP).
3. Use the entire virtual disk. This affects only the UTM virtual disk, not the
   Mac mini's macOS disk.
4. Set the server name to `macmini-lab`.
5. Create your Linux username and a strong password.
6. Enable `Install OpenSSH server` so you can administer the VM remotely.
7. Skip extra server snaps; the repository installs the required tools later.
8. Finish the installation and reboot.

If reboot returns to the installer, stop the VM, eject the Ubuntu ISO using the
UTM removable-drive menu, and start the VM again.

## 4. Set Up the Ubuntu Node

Log in through the UTM console first:

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

After reboot, make this repository available in the VM by cloning it from its
Git remote or by copying it from a development machine. From the repository root
inside Ubuntu, run:

```bash
./scripts/10-setup-ubuntu.sh
```

This numbered entry point runs the initial Ubuntu stages in order:

- `11` installs `kubectl`, Helm, the Argo CD CLI, SOPS, and age.
- `12` installs Tailscale and pauses for your browser sign-in.
- `20` installs the single-node K3s cluster.

No router access is assumed. Tailscale provides private access without a static
LAN IP or port forwarding. After signing in, connect from the MacBook Air or WSL
using `macmini-lab` or its Tailscale IP.

Cloudflare Tunnel is optional later, after you have a domain/public URL. At that
point, use the numbered `40` script with your tunnel token:

```bash
TUNNEL_TOKEN=ey... ./scripts/k8s/40-install-cloudflared.sh
```

## Later: External Data Disk

Skip this section for the initial setup. It is here for when the Mac mini
internal disk becomes full.

If you attach an external SSD to the VM, find it:

```bash
lsblk -f
```

Then mount it with:

```bash
sudo DATA_DEVICE=/dev/disk/by-id/YOUR_DISK DATA_MOUNT=/mnt/data ./scripts/ubuntu/80-mount-data-disk.sh
```

This script formats the disk only when it does not already contain a filesystem.
Read the script before using it on a disk with existing data.
