#!/usr/bin/env bash
# Stop on command errors, unset variables, and failures hidden inside pipelines.
set -euo pipefail

# Ubuntu publishes updated point releases under this stable release directory.
# The script discovers the current filename instead of hard-coding 24.04.x.
UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads/macmini-lab}"
RELEASE_URL="https://cdimage.ubuntu.com/ubuntu/releases/${UBUNTU_RELEASE}/release"
CHECKSUMS_FILE="${DOWNLOAD_DIR}/SHA256SUMS"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this script on the Mac mini; it prepares an installer for UTM."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but was not found."
  exit 1
fi

# Keep the large installer outside the Git repository.
mkdir -p "${DOWNLOAD_DIR}"

echo "Reading the Ubuntu ${UBUNTU_RELEASE} LTS release manifest..."
curl --fail --location --show-error --silent \
  "${RELEASE_URL}/SHA256SUMS" \
  --output "${CHECKSUMS_FILE}"

# Select the standard ARM64 server installer. The +largemem image is not needed
# for this 16 GB Mac mini.
iso_name="$(
  awk -v release="${UBUNTU_RELEASE}" '
    {
      name = $2
      sub(/^\*/, "", name)
      pattern = "^ubuntu-" release "\\.[0-9]+-live-server-arm64\\.iso$"
      if (name ~ pattern) {
        print name
        exit
      }
    }
  ' "${CHECKSUMS_FILE}"
)"

if [[ -z "${iso_name}" ]]; then
  echo "Could not find the standard ARM64 server ISO in ${RELEASE_URL}/SHA256SUMS."
  exit 1
fi

iso_path="${DOWNLOAD_DIR}/${iso_name}"
expected_checksum="$(
  awk -v target="${iso_name}" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == target) {
        print $1
        exit
      }
    }
  ' "${CHECKSUMS_FILE}"
)"

if [[ -f "${iso_path}" ]]; then
  echo "Installer already exists; verifying it before reuse..."
else
  echo "Downloading ${iso_name} (approximately 3 GB)..."
  # --continue-at resumes a partial download after a network interruption.
  curl --fail --location --show-error \
    --continue-at - \
    "${RELEASE_URL}/${iso_name}" \
    --output "${iso_path}"
fi

actual_checksum="$(shasum -a 256 "${iso_path}" | awk '{print $1}')"

if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
  echo "Checksum verification failed for ${iso_path}."
  echo "Delete the file and rerun this script."
  exit 1
fi

echo
echo "Ubuntu installer downloaded and verified:"
echo "  ${iso_path}"
echo
echo "Next: open UTM and follow docs/02-ubuntu-vm.md."
