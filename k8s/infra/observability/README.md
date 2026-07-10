# Observability

This directory contains Helm values for the basic observability stack.

## Components

- `kube-prometheus-stack`
- `loki`
- `alloy`

Install with:

```bash
make observability-install
```

Uninstall workloads while leaving PVCs behind:

```bash
make observability-uninstall
```

PVCs are not deleted by the uninstall script.
