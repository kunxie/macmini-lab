# CI/CD

Use GitHub Actions for CI and image building. Use Argo CD for deployment.

## Flow

```text
push to main
  -> GitHub Actions tests
  -> Docker image builds
  -> image pushed to GHCR
  -> manifest repo updated
  -> Argo CD deploys
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

For a new application, either:

- update a Helm values file in this repo from the workflow, or
- install Argo CD Image Updater later.

Start with the first option. It is explicit and easy to debug.

The job information collector implements the explicit manifest-update model
with immutable digests, a reviewed promotion, and Argo CD reconciliation. Its
credential boundary and verification procedure are documented in
[`08-job-info-collector.md`](08-job-info-collector.md).
