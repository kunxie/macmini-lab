# Private Tailscale Access

The Tailscale Kubernetes Operator exposes Grafana and Argo CD only to devices
in the tailnet. Each `Ingress` receives a private MagicDNS hostname and a valid
HTTPS certificate. Tailscale Funnel is not enabled.

Before Argo CD installs the Operator, create its OAuth Secret outside Git:

```bash
./scripts/k8s/34-configure-tailscale-operator-secret.sh
```

After the applications synchronize, restart Argo CD Server once so it reads
the Git-managed `server.insecure` setting:

```bash
kubectl -n argocd rollout restart deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-server
```

Find the private hostnames with:

```bash
kubectl get ingress -A
```

The backend connection for Argo CD is HTTP inside the cluster because the
Tailscale proxy terminates HTTPS. Traffic between user devices and the proxy
remains HTTPS over the tailnet.
