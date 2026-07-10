# Networking

All devices are on the same Wi-Fi, but no router access is assumed. That means:

- no reliable DHCP reservation;
- no port forwarding;
- no public inbound access to the Mac mini;
- LAN IPs may change.

Design the lab around outbound connections.

## Current Default

Use Tailscale for private admin access:

```text
MacBook Air / WSL
  -> Tailscale
  -> Ubuntu VM on Mac mini
  -> kubectl / helm / SSH
```

Use this for:

- SSH to the Ubuntu VM;
- private Grafana access;
- private Argo CD access;
- private Kubernetes API access;
- debugging services with `kubectl port-forward`.

Install it from the repository root inside the Ubuntu VM:

```bash
make tailscale-install
```

The first run prints a browser sign-in URL. After authentication, verify the
connection with `tailscale status` and find the VM address with `tailscale ip`.

## Later: Public App Access

After you have a domain/public URL, use Cloudflare Tunnel for public app access:

```text
Internet
  -> Cloudflare
  -> outbound cloudflared pod in K3s
  -> Kubernetes service
```

## What Not To Do

- Do not expose the Kubernetes API to the internet.
- Do not expose Grafana or Argo CD publicly.
- Do not depend on GitHub Actions SSHing into the Mac mini.
- Do not depend on router port forwarding.
- Do not require a stable LAN IP for CI/CD.

## Development Machines

Your MacBook Air and Ubuntu 24.04/WSL machine can both be development machines.
They can use:

- GitHub for source control;
- GHCR for container images;
- Tailscale for private cluster access;
- Argo CD for pull-based deployment.

This keeps the Mac mini focused on deployment.
