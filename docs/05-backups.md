# Backups

Backups matter even for personal infrastructure.

## What to Back Up

- This Git repo.
- Postgres dumps or CloudNativePG backups.
- MinIO buckets.
- Important app volumes.
- Argo CD app definitions and Helm values.

## Minimum Backup Policy

- Daily database backup.
- Weekly full object storage sync.
- At least one remote copy outside the Mac mini.
- Monthly restore test.

## Suggested Remote Targets

- Backblaze B2
- Cloudflare R2
- AWS S3
- Another machine on your LAN

Do not keep the only backup on the same disk as the live data.
