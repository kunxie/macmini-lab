# Kubernetes Manifests

This directory is the desired state consumed by Argo CD.

```text
k8s/
  argocd/
    root-application.yaml
    applications/
      personal-applications.yaml
  infra/
    observability/
    tailscale/
    postgres/
    redis/
    minio/
  registry/
    job-info-collector/
      production.json
```

Keep generated secrets out of Git. Prefer SOPS + age for encrypted secrets once
you start storing real credentials.

The root Application watches only `k8s/argocd/applications`. Infrastructure
child Applications point at pinned Helm charts and read their values from
`k8s/infra`. The personal ApplicationSet reads `k8s/registry`, then points each
generated Application at an exact revision and Kustomize path in its own
repository. A migration generation patches only the application's persistent
`<application>-default-deny` NetworkPolicy metadata, which gives Argo CD a safe
drift target for running the PreSync hook without restarting runtime pods.
Apply the root once with `scripts/k8s/33-bootstrap-gitops.sh`; Argo CD handles
subsequent changes from `main`.

The registry contract, onboarding flow, private-repository credential, and
release procedure are documented in
[`docs/08-application-registry.md`](../docs/08-application-registry.md). Run
`make gitops-check` before proposing a registration or deployment change.
