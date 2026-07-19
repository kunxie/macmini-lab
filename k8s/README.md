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
      detail-worker.yaml
      templates/
        discovery-job.yaml
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
`make gitops-check` before proposing a collector release change. The discovery
file under `templates/` is a fail-closed operator template and is deliberately
not listed in its parent Kustomization; neither Argo CD nor CI invokes it. The
detail worker is a one-replica, independently restartable Deployment bound to
the immutable application release identity.
