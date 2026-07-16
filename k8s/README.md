# Kubernetes Manifests

This directory is the desired state consumed by Argo CD.

```text
k8s/
  argocd/
    root-application.yaml
    applications/
  infra/
    observability/
    tailscale/
    postgres/
    redis/
    minio/
  apps/
    job-info-collector/
```

Keep generated secrets out of Git. Prefer SOPS + age for encrypted secrets once
you start storing real credentials.

The root Application watches only `k8s/argocd/applications`. Infrastructure
child Applications point at pinned Helm charts and read their values from
`k8s/infra`; application child Applications point at Kustomize directories in
`k8s/apps`. Apply the root once with `scripts/k8s/33-bootstrap-gitops.sh`;
Argo CD handles subsequent changes from `main`.

The `job-info-collector` foundation and its release procedure are documented in
[`docs/08-job-info-collector.md`](../docs/08-job-info-collector.md). Run
`make gitops-check` before proposing a collector release change.
