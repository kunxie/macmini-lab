# Personal application registry

`macmini-lab` is the deployment platform, not the source repository for each
application's Kubernetes package. The platform keeps only environment
registration, immutable release approval, shared Argo CD policy, and external
credentials. Each application repository owns its workloads, hooks, services,
network policies, resource settings, and non-secret configuration.

## Ownership boundary

| Concern | Owner |
| --- | --- |
| Application source, image, deployment package, and package CI | Application repository |
| Namespace, source path and revision, approved image digests, and evidence | `k8s/registry/<app>/<environment>.json` |
| Argo CD generation and namespace-scoped policy | `macmini-lab` |
| Kubernetes Secrets and Argo CD private-repository credentials | Cluster operator, outside Git |
| Shared PostgreSQL, MinIO, networking, observability, and backup infrastructure | `macmini-lab` |

The production registry is a small release ledger. A normal deployment PR
changes exactly one `production.json`; it never copies application manifests
into this repository.

## Application package contract

An application repository exposes a Kustomization at the registered
`source.path`. It must:

- render from an exact, reachable Git commit;
- contain only namespaced resources allowed by the `personal-apps` AppProject;
- contain no Secret values, Role, RoleBinding, or cluster-scoped resources;
- use `platform-runtime-image` for the approved runtime image;
- use `platform-migration-image` for the independently retained migration
  image when the application has a forward-only migration hook;
- declare its own resource limits, security contexts, network policies, hooks,
  probes, and Secret key references; and
- render and schema-check the package in application CI.

The symbolic images are part of the platform interface. The shared
ApplicationSet replaces them with immutable registry values. Applications that
do not need a migration slot may omit it from their manifests; Kustomize
ignores an unused image override.

## Registering an application

1. Merge the application-owned deployment package so its full Git SHA is
   reachable by Argo CD.
2. Add `k8s/registry/<app>/production.json` by copying the schema of an existing
   entry and changing every application identity and environment value.
3. Pin `source.revision`, `release.sourceRevision`, and both images to immutable
   identities. Keep the runtime and migration ledgers separate.
4. Provision the application's Kubernetes Secrets outside Git.
5. If the repository is private, install the read-only Argo CD credential
   described below.
6. Run `make registry-test` and `make gitops-check`, then merge the reviewed
   platform PR.

The directory name must equal `name`, and destination namespaces must be
unique. `scripts/k8s/validate_application_registry.py` rejects ownership drift,
non-canonical JSON, mutable image identities, invalid evidence, and backward
migration history. `CHECK_IMAGE_PLATFORM=true make gitops-check` additionally
pulls every registered image, verifies ARM64 and OCI identity labels, and
checks the retained migration image's packaged Alembic head.

## Private repositories

Create a GitHub App with read-only **Contents** access, install it only on the
personal application repositories Argo CD should read, and keep its private
key outside Git. On the Ubuntu VM, configure one credential template:

```bash
GITHUB_APP_ID=123 \
GITHUB_APP_INSTALLATION_ID=456 \
GITHUB_APP_PRIVATE_KEY_FILE=/secure/path/argocd-reader.pem \
  make argocd-repo-credential
```

The generated `repo-creds` Secret matches
`https://github.com/kunxie` and is usable only inside the `argocd` namespace.
The script never prints the credential. Rotate the key by rerunning the same
command, verify application refresh succeeds, and then revoke the old key.

## Deployment promotion

An application publication workflow validates its own build evidence and
emits a schema-v1 deployment candidate. It clones `macmini-lab` and invokes the
platform-owned updater:

```bash
python3 scripts/k8s/update_application_release.py \
  --candidate /path/to/deployment-candidate.json \
  --registration k8s/registry/<app>/production.json
```

The updater validates both sides of the boundary and changes only the source
revision and runtime release ledger. Application automation pushes a dedicated
branch and opens a PR; it never pushes `main`, talks to Kubernetes, or changes
another registration path. Exit status 3 means the candidate requires a
separate migration registration and no runtime update was written. Merging a
runtime PR is the deployment approval.

If the candidate's migration head differs from the registered head, accept a
separate forward-only migration update first. That reviewed change supplies
publication evidence for the migration image, increments `generation` exactly
once, and must pass the image ancestry gate. Runtime rollback changes only the
source/runtime release fields and never moves the migration ledger backward.

## Argo CD reconciliation

`personal-applications.yaml` scans `k8s/registry/*/production.json` and creates
one Application per registration. Argo CD checks out the registered private
repository at its exact revision, renders the registered path, and injects the
runtime and migration digests. Removing a registry entry preserves its
resources by default; decommissioning is therefore a separate, explicit
operator procedure.

The initial collector cutover replaces a legacy hand-written Application that
has no cascade-deletion finalizer. Its existing workloads remain while the
generated Application adopts the same resource identities. If both controllers
briefly report an ownership conflict, allow the root Application to prune the
legacy Application object; do not delete the collector namespace or workloads.

## Rollback and recovery

Rollback is a reviewed registry change that restores an earlier application
source revision and runtime release identity while retaining the latest
migration object. After merge, verify the generated Application is `Synced`
and `Healthy` and inspect the application-owned verification hook. Never use a
mutable tag, edit the generated Application, or make a direct `kubectl` change
as a substitute for the registry review.
