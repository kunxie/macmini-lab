# Headlamp Kubernetes dashboard

Headlamp provides a read-only Kubernetes dashboard over the private Tailscale
network. Argo CD installs the pinned official chart and reconciles the local
Tailscale Ingress and login RBAC resources.

## Access

1. Connect the client device to the same tailnet as the lab.
2. Create a one-hour login token from an administrator shell:

   ```bash
   kubectl -n headlamp create token headlamp-viewer --duration=1h
   ```

3. Open `https://headlamp.<tailnet-name>.ts.net` and paste the token into the
   Headlamp sign-in page.

The Tailscale Kubernetes Operator publishes the `headlamp` MagicDNS name and
provisions its TLS certificate. There is no public Internet route or Funnel.

The `headlamp-viewer` ServiceAccount is bound to Kubernetes' built-in `view`
ClusterRole plus a narrow role that can read Nodes, PersistentVolumes, and
StorageClasses. It can inspect workloads and basic cluster health, but it cannot
read Secrets or modify the cluster. The Headlamp workload's own ServiceAccount
has no role binding, and `unsafeUseServiceAccountToken` remains disabled.

## Verify

```bash
kubectl -n argocd get application headlamp
kubectl -n headlamp get deployment,service,ingress
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-viewer get pods -A
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-viewer get secrets -A
```

The first authorization check should return `yes`; the Secrets check should
return `no`.

The chart package is pinned to `0.43.0`. Its expected SHA-256 digest is
`6a6b8102984c07df31d800c27e0ea8fc91c766366ba7fcdc2ff4113b03ae9a75`.
The Headlamp `v0.43.0` multi-platform image is also pinned to OCI index digest
`sha256:5d03caa26df7a715079405df2949907160518750b9b62b6bf4de8d1a6142c541`.
Repository validation verifies both pins and the image's Linux ARM64 platform.
