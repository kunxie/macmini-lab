# Observability

Use a small Grafana stack for the initial single-node K3s cluster.

## Stack

- `kube-prometheus-stack` for Prometheus, Grafana, Alertmanager, node metrics,
  and Kubernetes object metrics.
- Loki for log storage.
- Grafana Alloy for collecting Kubernetes pod logs and sending them to Loki.

Do not install tracing on day one. Add Tempo and OpenTelemetry Collector later
when multiple services need request-level tracing.

## Install

From a machine with `kubectl`, `helm`, and cluster access:

```bash
make observability-install
```

Check status:

```bash
kubectl -n observability get pods
kubectl -n observability get pvc
```

## Access Grafana

For local access:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Then open:

```text
http://localhost:3000
```

Default credentials:

```text
username: admin
password: change-me
```

Change the password after install or override it before install:

```bash
GRAFANA_ADMIN_PASSWORD='your-password' make observability-install
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
