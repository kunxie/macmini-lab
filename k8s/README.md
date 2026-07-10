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
    example-app/
```

Keep generated secrets out of Git. Prefer SOPS + age for encrypted secrets once
you start storing real credentials.

The root Application watches only `k8s/argocd/applications`. Each child
Application points at one pinned Helm chart and reads its values from
`k8s/infra`. Apply the root once with `scripts/k8s/33-bootstrap-gitops.sh`;
Argo CD handles subsequent changes from `main`.
