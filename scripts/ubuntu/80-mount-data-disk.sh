#!/usr/bin/env bash
# Fail fast on command errors, unset variables, and failed pipeline commands.
set -euo pipefail

# These variables make the script reusable when you add an external SSD later.
DATA_DEVICE="${DATA_DEVICE:-}"
DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"
FS_TYPE="${FS_TYPE:-ext4}"

# Refuse to guess the disk. Formatting the wrong disk would be destructive.
if [[ -z "${DATA_DEVICE}" ]]; then
  echo "Set DATA_DEVICE, for example: sudo DATA_DEVICE=/dev/disk/by-id/... $0"
  exit 1
fi

if [[ ! -b "${DATA_DEVICE}" ]]; then
  echo "Block device not found: ${DATA_DEVICE}"
  exit 1
fi

# Only create a filesystem when the device is blank.
existing_fs="$(blkid -o value -s TYPE "${DATA_DEVICE}" || true)"

if [[ -z "${existing_fs}" ]]; then
  echo "No filesystem found on ${DATA_DEVICE}; creating ${FS_TYPE}."
  mkfs -t "${FS_TYPE}" "${DATA_DEVICE}"
else
  echo "Existing filesystem detected on ${DATA_DEVICE}: ${existing_fs}"
fi

mkdir -p "${DATA_MOUNT}"

# Use UUID in /etc/fstab so the mount survives device name changes.
uuid="$(blkid -o value -s UUID "${DATA_DEVICE}")"
fstab_line="UUID=${uuid} ${DATA_MOUNT} ${FS_TYPE} defaults,nofail 0 2"

if ! grep -q "UUID=${uuid}" /etc/fstab; then
  echo "${fstab_line}" >> /etc/fstab
fi

mount "${DATA_MOUNT}"

# Pre-create common data directories for future persistent workloads.
mkdir -p "${DATA_MOUNT}/k3s" "${DATA_MOUNT}/postgres" "${DATA_MOUNT}/redis" "${DATA_MOUNT}/minio" "${DATA_MOUNT}/backups"

echo "Mounted ${DATA_DEVICE} at ${DATA_MOUNT}."
