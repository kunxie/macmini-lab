# CI/CD

Use GitHub Actions for CI and image building. Use Argo CD for deployment.

## Flow

```text
push to main
  -> GitHub Actions tests
  -> Docker image builds
  -> image pushed to GHCR
  -> reviewed registry PR
  -> Argo CD reads the application package at an exact commit
```

## Example GitHub Actions Workflow

Put this in an app repo as `.github/workflows/build.yaml`:

```yaml
name: build

on:
  push:
    branches: [main]

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/YOUR_USER/YOUR_APP:${{ github.sha }}
```

For a new personal application, keep its Kustomize package and package CI in
the application repository. Add one production registration under
`k8s/registry/<app>/production.json`; the shared ApplicationSet creates the
Argo CD Application. The application's publication workflow submits a reviewed
PR that changes only that registration's source revision and immutable runtime
release identity.

The ownership contract, candidate schema, private-repository credential,
migration boundary, and onboarding procedure are documented in
[`08-application-registry.md`](08-application-registry.md).
