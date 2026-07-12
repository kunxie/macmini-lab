# Vendored MinIO Helm Charts

The `operator` and `tenant` charts in this directory are copied unchanged from
the MinIO Operator `v7.1.1` tag. Keeping the small chart directories here
prevents Argo CD from cloning the full upstream repository during manifest
generation, which exceeds this lab's repository-server timeout.

To upgrade, replace both directories from the same upstream release, review the
diff, render both charts locally, and update this version note.
