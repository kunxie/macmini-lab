# Overview

This lab is intentionally simple: one Mac mini, one Ubuntu VM, one K3s node.
The Mac mini is only for deployment. Development happens from a MacBook Air and
an Ubuntu 24.04/WSL machine.

## Goals

- Deploy personal apps from GitHub merges.
- Keep all infrastructure reproducible.
- Avoid exposing the home network directly.
- Work without router access, port forwarding, or DHCP reservations.
- Make backups boring and testable.

## Non-Goals

- High availability.
- Multi-node Kubernetes on day one.
- Service mesh.
- Complex storage orchestration.
- Running production-critical workloads.

## Recommended Flow

```text
GitHub main branch
  -> GitHub Actions runs tests
  -> GitHub Actions builds image
  -> image pushed to GHCR
  -> manifests or Helm values updated
  -> Argo CD syncs into K3s
```

Use GitHub-hosted runners first. Add a self-hosted runner later only if you need
private network access, faster local builds, or ARM-specific builds.

## Connectivity Model

Because the devices are on Wi-Fi without router access, assume IP addresses can
change and inbound ports may not be reachable.

Use:

- Tailscale for admin access from MacBook/WSL to the Ubuntu VM.
- GitHub Actions and Argo CD for CI/CD, so deployment does not depend on inbound
  network access to the Mac mini.

Later, after you have a domain/public URL, add Cloudflare Tunnel for public HTTPS
access to deployed apps.

Avoid:

- Router port forwarding.
- Public Kubernetes API exposure.
- Workflows that require GitHub Actions to SSH into the home network.
- Public exposure of Grafana, Argo CD, Postgres, Redis, or MinIO admin.

## Upgrade Path

When this Mac mini becomes full:

- Add an external SSD first and move persistent volumes there.
- Move larger object storage or backups off-machine.
- Add a second node only when you actually need more compute.
- Move critical apps to a cloud VM if uptime matters.
