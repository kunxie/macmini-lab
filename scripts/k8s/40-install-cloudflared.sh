#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# Cloudflare Tunnel is optional later, after you have a domain/public URL.
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
NAMESPACE="${NAMESPACE:-cloudflare}"

# The tunnel token comes from the Cloudflare dashboard.
if [[ -z "${TUNNEL_TOKEN}" ]]; then
  echo "Set TUNNEL_TOKEN before running this script."
  echo "Example: TUNNEL_TOKEN=ey... ./scripts/k8s/40-install-cloudflared.sh"
  exit 1
fi

# Keep Cloudflare resources isolated from app namespaces.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Store the token in a Kubernetes Secret instead of putting it in the Deployment.
kubectl -n "${NAMESPACE}" create secret generic tunnel-token \
  --from-literal=token="${TUNNEL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Run two replicas so the tunnel survives a single pod restart.
kubectl -n "${NAMESPACE}" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  labels:
    app.kubernetes.io/name: cloudflared
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudflared
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          imagePullPolicy: IfNotPresent
          args:
            - tunnel
            - --no-autoupdate
            - --loglevel
            - info
            - run
          env:
            - name: TUNNEL_TOKEN
              valueFrom:
                secretKeyRef:
                  name: tunnel-token
                  key: token
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 256Mi
YAML

echo "cloudflared installed in namespace ${NAMESPACE}."
