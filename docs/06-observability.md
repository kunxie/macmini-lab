# Observability

Use a small Grafana stack for the initial single-node K3s cluster.

## Stack

- `kube-prometheus-stack` for Prometheus, Grafana, Alertmanager, node metrics,
  and Kubernetes object metrics.
- Loki for log storage.
- Grafana Alloy for collecting Kubernetes pod logs and sending them to Loki.

Prometheus discovers release-labeled ServiceMonitors and PrometheusRules from
the `observability` and `job-info-collector` namespaces. Add another namespace
to both explicit selectors only in a reviewed platform change; application
resources do not receive cluster-wide monitoring discovery by default.

Do not install tracing on day one. Add Tempo and OpenTelemetry Collector later
when multiple services need request-level tracing.

## Install

Create the Grafana credential outside Git, then bootstrap the root Argo CD
Application after the repository changes are pushed:

```bash
GRAFANA_ADMIN_PASSWORD='your-password' \
  ./scripts/k8s/32-configure-observability-secret.sh
./scripts/k8s/33-bootstrap-gitops.sh
```

Check status:

```bash
kubectl -n observability get pods
kubectl -n observability get pvc
```

## Pod Log Collection

Alloy runs as a DaemonSet and mounts the node's `/var/log` directory read-only.
It discovers only Pods assigned to its own node, resolves their CRI log files
under `/var/log/pods`, and tails those files with `loki.source.file` before
forwarding records to Loki.

Do not replace this with cluster-wide `loki.source.kubernetes` collection on
the single node. That component opens a Kubernetes API log reader for every
container target. The kubelet backs each active follow request with a file
watcher, so the readers can exhaust Ubuntu's shared inotify instance budget
and return errors such as:

```text
failed to create fsnotify watcher: too many open files
```

If collection becomes unhealthy, compare the node limit with the number of
running container targets and inspect Alloy for reconnect loops:

```bash
sysctl fs.inotify.max_user_instances
kubectl get pods -A -o json \
  | jq '[.items[].spec.containers[]] | length'
kubectl -n observability logs daemonset/alloy -c alloy --since=5m
```

Repeated `opened log stream` messages for every target indicate API-stream
collection or reconnect churn. With file collection, confirm the Alloy Pod has
a read-only `/var/log` mount and that `loki.source.file.pod_logs` is healthy in
the Alloy component UI.

## Access Grafana

For local access:

```bash
kubectl -n observability port-forward \
  --address="$(tailscale ip -4)" \
  svc/kube-prometheus-stack-grafana 3000:80
```

Keep that command running. From a device in the same tailnet, open the Ubuntu
VM's Tailscale address:

```text
http://MACMINI_LAB_TAILSCALE_IP:3000
```

Find that address with `tailscale ip -4`. Binding to the Tailscale address keeps
Grafana off the VM's normal LAN interface.

Credentials:

```text
username: admin
password: the value passed to scripts/k8s/32-configure-observability-secret.sh
```

To rotate the password, run the Secret script again and restart Grafana:

```bash
GRAFANA_ADMIN_PASSWORD='your-new-password' \
  ./scripts/k8s/32-configure-observability-secret.sh
kubectl -n observability rollout restart deployment/kube-prometheus-stack-grafana
```

## Retention Defaults

- Prometheus: 7 days, capped around 15 GB.
- Loki: 7 days, backed by a 20 GB PVC.
- Grafana: 2 GB PVC.
- Alertmanager: 2 GB PVC.

These defaults are intentionally modest for the Mac mini internal disk.

## Expansion Notes

Existing data remains accessible as long as the persistent volumes are preserved.
When moving to an external disk or new storage class later:

1. Stop writes or scale down the affected workload.
2. Back up the PVC data.
3. Create a new PVC on the new storage.
4. Restore or copy data into the new PVC.
5. Update Helm values only after data is verified.

Do not uninstall charts with PVC deletion unless you intentionally want to lose
the stored metrics, logs, or Grafana state.
