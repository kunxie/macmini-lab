# Job Information Collector

The collector is deployed from the public
[`kunxie/job-info-collector`](https://github.com/kunxie/job-info-collector)
image through this repository's existing root Argo CD Application. Git remains
the only deployment authority: application CI may propose a release change,
but a reviewed merge to `macmini-lab/main` is the production approval event.

## Milestone 3 foundation

The initial deployment deliberately contains no application credentials,
database migration, source request, Service, ingress, or continuously running
collector process. It owns only:

- a dedicated Argo CD AppProject restricted to the `job-info-collector`
  namespace and this repository;
- one Argo CD Application rooted at `k8s/apps/job-info-collector`;
- immutable release metadata copied from the accepted publication record;
- a namespace-wide default-deny policy for collector pods; and
- a finite PostSync Job that anonymously pulls the approved ARM64 digest and
  runs `job-info-collector --version` as UID/GID 10001.

The existing namespace remains externally provisioned, so this Application does
not adopt its metadata or make the namespace subject to pruning. The
verification workload explicitly conforms to the Kubernetes `restricted` Pod
Security Standard: it receives no service-account token, has no environment
variables or volumes, drops every Linux capability, disallows privilege
escalation, and uses a read-only root filesystem.

## Release identity

All release values live together in
`k8s/apps/job-info-collector/release.yaml`. A promotion must change the image
digest, application version, complete source revision, source timestamp,
publication-record checksum, and CI/publication links as one reviewed unit.
The readable image tag is evidence, not deployment state; the Job always uses
`ghcr.io/kunxie/job-info-collector@sha256:...`.

This foundation does not yet create promotion pull requests. Until the
application repository adds its narrowly scoped promotion workflow, a newly
published collector image remains in GHCR and an operator must propose the
corresponding `release.yaml` change. After that workflow is added, it will
update the same file and still require a reviewed merge before Argo CD sees the
new digest.

The `KUBERNETES_SCHEMA_REVISION` in `gitops-checks.yml` pins only the JSON
schemas used by CI to validate Kubernetes resources. It is independent of the
collector version and image digest and does not change during a promotion.

Validate a proposed release locally with:

```bash
make check
make gitops-check
CHECK_IMAGE_PLATFORM=true make gitops-check
```

The last form contacts public GHCR and proves that the selected index contains
`linux/arm64`. Pull requests run the same platform check. After its first
successful run, configure branch protection to require the
`GitOps checks / collector manifests` status check.

## Deployment verification

The root Application discovers the child Application after the change reaches
`main`; no direct `kubectl apply` is part of the release path. Verify the
reconciled state from an administrative machine:

```bash
kubectl -n argocd get application job-info-collector
kubectl -n job-info-collector get configmap/job-info-collector-release
kubectl -n job-info-collector get job/job-info-collector-release-verification
kubectl -n job-info-collector logs job/job-info-collector-release-verification
kubectl -n job-info-collector get pod \
  -l app.kubernetes.io/component=release-verification \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

For the bootstrap release, the Job log must be exactly:

```text
job-info-collector 0.3.0.dev0 (revision 26cff0efdab7b6b16450d004ed28e1ca39451bfe)
```

Argo CD retains the completed Job for inspection. The next release deletes it
immediately before creating the new PostSync verification Job. A failed Job
fails the sync operation rather than installing a restarting placeholder
Deployment.

## Rollback

Rollback is a reviewed revert of the release metadata commit. After that revert
is merged, Argo CD reconciles the older digest and runs the same verification
Job again. Never repair release state by changing the live Job, applying a tag,
or pushing directly to `main`.

Before accepting the foundation, promote a second harmless accepted digest and
then revert it. Record the application revision, image digest, Job output, and
Argo CD health for both directions.

## Later milestones

Later collector milestones extend this same Argo CD Application rather than
creating parallel deployment paths:

- Milestone 4 adds a retry-safe migration Job ordered before release
  verification and references only the existing PostgreSQL Secret.
- Milestones 6 through 8 add finite discovery/operator Jobs, the detail-worker
  Deployment, and then the scheduler Deployment as their commands become real.
- Milestone 9 adds the runtime ConfigMap, MinIO and PostgreSQL Secret references,
  ServiceMonitor, PrometheusRule, resource tuning, and recovery verification.

Expand the AppProject resource allowlist only when a reviewed milestone adds a
new namespaced resource kind. Secret values remain provisioned out of band and
must never be copied into this repository.
