# Observability

This directory contains Helm values for the basic observability stack. Argo CD
Application definitions under `k8s/argocd/applications` pair these values with
version-pinned upstream charts.

## Components

- `kube-prometheus-stack`
- `loki`
- `alloy`

## GitOps Install

Create the Grafana credential before bootstrapping the root Application:

```bash
GRAFANA_ADMIN_PASSWORD='choose-a-password' \
  ./scripts/k8s/32-configure-observability-secret.sh
./scripts/k8s/33-bootstrap-gitops.sh
```

The root Application reads the public `main` branch. Commit and push these files
before running the bootstrap script. Check synchronization with:

```bash
kubectl -n argocd get applications
kubectl -n observability get pods,pvc
```

Access Grafana privately over Tailscale:

```bash
kubectl -n observability port-forward \
  --address="$(tailscale ip -4)" \
  svc/kube-prometheus-stack-grafana 3000:80
```

Script `31-install-observability.sh` is a manual recovery path for use when Argo
CD is unavailable. Do not use Helm and Argo CD to manage the same releases at
the same time.

## Chart Versions

- `kube-prometheus-stack`: `86.0.0`
- `loki`: `18.4.2` from the Grafana Community chart repository
- `alloy`: `1.10.0`

Update one chart version at a time and review its upstream upgrade notes before
merging. Argo CD will deploy a pinned version; it does not automatically select
new chart releases.
