# Kubernetes Manifests

Use this directory for cluster desired state.

Suggested structure:

```text
k8s/
  bootstrap/
    argocd/
  infra/
    observability/
    postgres/
    redis/
    minio/
  apps/
    example-app/
```

Keep generated secrets out of Git. Prefer SOPS + age for encrypted secrets once
you start storing real credentials.
