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

## Milestone 4 database migration

Milestone 4 adds a finite Argo CD PreSync migration Job. Kustomize copies the
approved immutable migration image, version, source revision, and digest from a
dedicated migration-release ConfigMap. The migration identity advances
monotonically and is independent of application promotion and rollback. A
narrowly selected PreSync NetworkPolicy permits only cluster DNS and TCP/5432
to the `postgres` CloudNativePG pods.

The Job runs `job-info-collector migrate`, receives only the `username`,
`password`, `host`, `port`, and `dbname` keys from the existing
`job-info-collector-db-credentials` Secret, and has a five-minute deadline with
one retry. It receives no S3, source, alert, Kubernetes API, or filesystem write
access. Migration failure stops synchronization before release verification.

### Database Secret prerequisite

Create both externally managed database Secret copies before bootstrapping
GitOps or merging the migration foundation. The script prompts for the password
without placing it in shell history and verifies only the Secret types and key
names; it never prints or decodes values:

```bash
APP_NAME=job-info-collector \
  ./scripts/k8s/38-configure-postgres-app-secret.sh
```

The `data` copy must be a `kubernetes.io/basic-auth` Secret with `username` and
`password`. The `job-info-collector` copy must be an `Opaque` Secret with
exactly `username`, `password`, `host`, `port`, and `dbname`. Confirm PostgreSQL
is ready after GitOps bootstrap:

```bash
kubectl -n data get secret job-info-collector-db-credentials
kubectl -n job-info-collector get secret job-info-collector-db-credentials
kubectl -n data wait --for=condition=Ready cluster/postgres --timeout=5m

SECRET_RV="$(kubectl -n data get secret job-info-collector-db-credentials \
  -o jsonpath='{.metadata.resourceVersion}')"
ROLE_RV="$(kubectl -n data get cluster/postgres \
  -o jsonpath='{.status.managedRolesStatus.passwordStatus.job-info-collector.resourceVersion}')"
test -n "${SECRET_RV}"
test "${ROLE_RV}" = "${SECRET_RV}"
unset SECRET_RV ROLE_RV
```

The resource-version comparison proves that CloudNativePG reconciled the exact
password Secret revision before the migration starts. It reads only Kubernetes
metadata; it does not print or decode either credential.

Do not use `kubectl get secret -o yaml`, decode these Secrets for inspection, or
copy their values into Git, an issue, logs, or an Actions secret.

## Milestone 5 dependency verification

Milestone 5 upgrades the finite PostSync Job from an image-only check to
`job-info-collector verify-services`. The command opens PostgreSQL, executes
`SELECT 1`, and calls MinIO `HeadBucket`; it does not write a row, object,
manifest, or test fixture. Successful output is exactly the safe dependency
category summary emitted by the application and contains no endpoint,
credential, bucket contents, or database data.

The Job receives the same five database keys used by the migration Job plus
the `endpoint`, `bucket`, `access-key`, and `secret-key` keys from the existing
`job-info-collector-minio-credentials` Secret. It receives no source response,
source authorization, alert, Kubernetes API, volume, or filesystem write
access. A dedicated NetworkPolicy permits only cluster DNS, TCP/5432 to pods
selected by `cnpg.io/cluster: postgres`, and TCP/9000 to pods selected by
`v1.min.io/tenant: minio`.

Create and scope the externally managed MinIO credential before approving the
Milestone 5 promotion:

```bash
APP_NAME=job-info-collector \
  ./scripts/k8s/36-configure-minio-app-secret.sh
kubectl -n job-info-collector get secret \
  job-info-collector-minio-credentials \
  -o go-template='{{range $k,$v := .data}}{{printf "%s\n" $k}}{{end}}'
```

The second command prints key names only. The expected names are `access-key`,
`bucket`, `endpoint`, and `secret-key`. Do not print or decode their values.

## Milestone 6 opt-in discovery

Milestone 6 adds a reviewed discovery Job and egress NetworkPolicy template at
`k8s/apps/job-info-collector/templates/discovery-job.yaml`. The template is
intentionally absent from `kustomization.yaml`: Argo CD cannot reconcile it,
and merging this repository cannot make a public source request. It also
contains unusable names, approval identity, release identity, timestamp,
digest, and alert-threshold blockers. Validator `44` requires those blockers
to remain in the committed template.

Each invocation is a separate operator action. Before approving one, confirm
that the accepted application release implements the Milestone 6 `discover`
command, PostgreSQL and MinIO are healthy, the externally managed Secrets have
the key sets documented above, and the intended Walmart Careers request is
authorized. Copy the template outside the repository; never replace blockers
in the committed source:

```bash
install -m 0600 \
  k8s/apps/job-info-collector/templates/discovery-job.yaml \
  /tmp/job-info-collector-discovery-approved.yaml
```

In that copy, replace every occurrence of each blocker as one reviewed unit:

- use unique DNS-safe Job and NetworkPolicy names;
- use the same immutable approval ID in both resources and all pod selectors;
- copy the accepted version, complete source revision, and image digest from
  `k8s/apps/job-info-collector/release.yaml`;
- choose a whole-second scheduled timestamp on the current UTC date, no later
  than creation time, from `00:00:00` inclusive through `05:00:00` exclusive;
  and
- set all four alert thresholds to reviewed positive values appropriate for
  the expected population and queue state.

The application stops at the next UTC midnight. The Job's 19-hour active
deadline covers the remaining day even when creation occurs at the end of the
allowed start window; it has one pod, no Kubernetes retry, and no recurring
controller. Standard Kubernetes NetworkPolicy cannot select an HTTPS FQDN, so
the public egress rule allows TCP/443 to any destination. It still denies every
other public egress port and narrows DNS, PostgreSQL, and MinIO by namespace,
pod selector, and port. Review that limitation as part of every approval.

Before the live action, validate the exact approved copy and prove that no
blocker remains:

```bash
kubeconform -kubernetes-version 1.36.0 -strict \
  /tmp/job-info-collector-discovery-approved.yaml
if rg -n 'REPLACE|replace-with|sha256:0{64}' \
  /tmp/job-info-collector-discovery-approved.yaml; then
  echo 'discovery manifest still contains a blocker' >&2
  exit 1
fi
kubectl apply --dry-run=server \
  -f /tmp/job-info-collector-discovery-approved.yaml
```

The server dry run does not authorize creation. Record the reviewed manifest
checksum, release revision and digest, approval ID, UTC timestamp, expected
targets, and approving operator. Only after that explicit approval, create the
two resources in a separate command; this command begins the live traversal:

```bash
kubectl create -f /tmp/job-info-collector-discovery-approved.yaml
```

Inspect the exact labeled Job without printing either Secret. Retain the
sanitized command output, terminal Job condition, application run UUID,
manifest object key, database counts, object counts, approved-manifest
checksum, and Git revision as acceptance evidence. A failed or partial run is
durable evidence and must not be automatically repeated. After the Job reaches
a terminal state and evidence is captured, delete only its uniquely named
discovery NetworkPolicy; retain the Job until the acceptance record is
complete. The namespace default-deny policy remains in force.

Do not commit the populated copy, print Secret values, use a mutable image tag,
attach an Argo CD hook annotation, add the template to Kustomize, or invoke it
from CI. The application repository's discovery operations guide defines the
request, persistence, exit-status, and failure-handling contracts.

## Release identity

Application release values live together in
`k8s/apps/job-info-collector/release.yaml`. Migration release values live in
`k8s/apps/job-info-collector/migration-release.yaml` with an Alembic head and a
positive `migrationGeneration`. Both identities record the image digest,
application version, complete source revision, source timestamp,
publication-record checksum, and CI/publication links as one reviewed unit. The
migration identity also records the schema version and packaged Alembic head
from the schema-5 publication record. Schema 5 guarantees that the image can
prove Alembic ancestry without credentials. Readable image tags are evidence,
not deployment state; both Jobs always use immutable
`ghcr.io/kunxie/job-info-collector@sha256:...` references.

The application repository's narrowly scoped promotion workflow proposes only
the corresponding `release.yaml` change and never changes the migration
identity. A schema-bearing image advances `migration-release.yaml` in a
separate reviewed pull request. GitOps CI rejects a decreased migration
version, timestamp, source ancestry, or generation; proves the selected image
labels and packaged `schema-head`; runs the image's `schema-descends-from`
contract against the prior accepted head (or its own head for the first
migration); and requires every migration identity change to increment its
generation exactly once. Application rollback therefore leaves the latest
forward migration image and schema head in place.

The source-ancestry check reads the public `job-info-collector` GitHub compare
API without a cross-repository credential, so that source repository must remain
publicly readable.

Populate `migration-release.yaml` only from an accepted schema-5 publication
record. Commit that artifact byte-for-byte as
`migration-publication-record.json`; CI checks its SHA-256, exact schema and
fields against the release identity. GitOps CI rejects placeholder values; do
not open a migration pull request until both files come from that one record.
The operator downloads the artifact once from the accepted publication run;
GitOps CI validates the committed copy and needs no access to the application
repository's Actions artifacts. Do not reformat or reserialize the JSON:

```bash
install -m 0644 /path/to/downloaded/publication-record.json \
  k8s/apps/job-info-collector/migration-publication-record.json
sha256sum k8s/apps/job-info-collector/migration-publication-record.json
```

Copy that checksum and the corresponding record fields into
`migration-release.yaml` as one reviewed change.

The `KUBERNETES_SCHEMA_REVISION` in `gitops-checks.yml` pins only the JSON
schemas used by CI to validate Kubernetes resources. It is independent of the
collector version and image digest and does not change during a promotion.

Validate a proposed release locally with:

```bash
make check
make gitops-validator-test
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
kubectl -n job-info-collector get configmap/job-info-collector-migration-release
kubectl -n job-info-collector get job/job-info-collector-database-migration
kubectl -n job-info-collector logs job/job-info-collector-database-migration
kubectl -n job-info-collector get job/job-info-collector-release-verification
kubectl -n job-info-collector logs job/job-info-collector-release-verification
kubectl -n job-info-collector get pod \
  -l app.kubernetes.io/component=release-verification \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
kubectl -n job-info-collector get pod \
  -l app.kubernetes.io/component=database-migration \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

The PostSync image identity must match the application release ConfigMap and
its log must end with `service verification succeeded (postgresql and object
store; no writes)`. The migration Job annotations and image must match the
migration-release ConfigMap, and its log must end with `database migrations
applied`.

Argo CD retains the completed Job for inspection. The next release deletes it
immediately before creating the new PostSync verification Job. A failed Job
fails the sync operation rather than installing a restarting placeholder
Deployment.

Confirm the database revision independently from the current CloudNativePG
primary. This command uses a local administrative socket, forces read-only
transactions, reads no Secret, and prints only the Alembic revision. Its output
must equal the migration release's `alembicHead`:

```bash
PRIMARY_POD="$(kubectl -n data get cluster/postgres \
  -o jsonpath='{.status.currentPrimary}')"
test -n "${PRIMARY_POD}"
kubectl -n data exec "${PRIMARY_POD}" -- \
  env 'PGOPTIONS=-c default_transaction_read_only=on' \
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --tuples-only --no-align \
  --username=postgres --dbname=job-info-collector \
  --command='SELECT version_num FROM alembic_version;'
unset PRIMARY_POD
```

If migration fails, inspect its pod events and logs. Correct application or
manifest failures through a reviewed pull request. For a missing or rejected
database credential, rerun script `38` interactively so both Secret copies are
updated together, wait for CloudNativePG reconciliation, and use Argo CD's
manual **Retry** action. A Secret fixed within the five-minute Job deadline may
allow the existing pod to start; after the deadline, retry creates a fresh Job.
Do not commit credentials, edit `alembic_version`, run ad hoc DDL, delete the
live hook manually, or bypass the hook.

### Initial Milestone 4 rollout order

1. Merge the application implementation and wait for its accepted public 0.4
   publication, but do not merge the automatic application promotion yet.
2. Copy the exact publication record into Git, replace every migration-release
   blocker with that record's identity and byte checksum, and merge the
   migration foundation. The 0.4 image applies the schema while the current 0.3
   application verification remains harmless.
3. After the migration foundation reaches `main`, refresh the automatic 0.4
   application-promotion branch against the new `main` (use GitHub's **Update
   branch** action or an equivalent rebase), rerun its checks, and confirm the
   resulting file diff changes only `release.yaml`.
4. Merge the refreshed application promotion. PreSync reruns the same forward
   migration safely before PostSync verifies the 0.4 application.
5. Record both ConfigMap identities, the `alembic_version`, Job logs, and Argo CD
   `Synced`/`Healthy` status.

## Rollback

Application rollback is a reviewed revert of only the automated `release.yaml`
promotion commit. Never revert `migration-release.yaml` or reduce its
`migrationGeneration`; database migrations remain forward-only. After the
application revert, Argo CD first runs the latest monotonic migration image as a
safe no-op, then verifies the older application digest against the forward
schema. Each application release must remain compatible with that schema under
the expand-and-contract policy. Never repair release state by changing a live
Job, applying a tag, or pushing directly to `main`.

Before accepting the foundation, promote a second harmless accepted application
digest and then revert only that promotion. Confirm that the migration identity
and database head do not move backward, and record both application revisions,
digests, Job output, and Argo CD health. Finally, restore the newer application
identity through a fresh or refreshed reviewed promotion pull request and verify
both hooks and Argo CD health again. Rollback testing is incomplete while the
live application remains on the deliberately reverted identity.

## Later milestones

Later collector milestones extend this same Argo CD Application rather than
creating parallel deployment paths:

- Milestones 6 through 8 add finite discovery/operator Jobs, the detail-worker
  Deployment, and then the scheduler Deployment as their commands become real.
- Milestone 9 reuses the PostgreSQL and MinIO Secret references introduced by
  finite Milestone 4/5 hooks for runtime workloads, and adds the runtime
  ConfigMap, ServiceMonitor, PrometheusRule, resource tuning, and recovery
  verification.

Expand the AppProject resource allowlist only when a reviewed milestone adds a
new namespaced resource kind. Secret values remain provisioned out of band and
must never be copied into this repository.
