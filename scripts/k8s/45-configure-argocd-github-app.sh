#!/usr/bin/env bash
# Configure one read-only Argo CD credential template for private repositories.
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
GITHUB_OWNER="${GITHUB_OWNER:-kunxie}"
SECRET_NAME="${SECRET_NAME:-argocd-github-private-repositories}"

: "${GITHUB_APP_ID:?set GITHUB_APP_ID to the read-only GitHub App ID}"
: "${GITHUB_APP_INSTALLATION_ID:?set GITHUB_APP_INSTALLATION_ID}"
: "${GITHUB_APP_PRIVATE_KEY_FILE:?set GITHUB_APP_PRIVATE_KEY_FILE}"

test -r "${GITHUB_APP_PRIVATE_KEY_FILE}" || {
  echo "GitHub App private-key file is not readable" >&2
  exit 1
}
grep -Fq -- "BEGIN RSA PRIVATE KEY" "${GITHUB_APP_PRIVATE_KEY_FILE}" ||
  grep -Fq -- "BEGIN PRIVATE KEY" "${GITHUB_APP_PRIVATE_KEY_FILE}" || {
    echo "GitHub App private-key file is not a recognized PEM key" >&2
    exit 1
  }

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
manifest="${work_dir}/repo-creds.yaml"
umask 077

"${KUBECTL}" -n argocd create secret generic "${SECRET_NAME}" \
  --from-literal=type=git \
  --from-literal="url=https://github.com/${GITHUB_OWNER}" \
  --from-literal="githubAppID=${GITHUB_APP_ID}" \
  --from-literal="githubAppInstallationID=${GITHUB_APP_INSTALLATION_ID}" \
  --from-file="githubAppPrivateKey=${GITHUB_APP_PRIVATE_KEY_FILE}" \
  --dry-run=client -o yaml >"${manifest}"

"${KUBECTL}" label --local -f "${manifest}" \
  argocd.argoproj.io/secret-type=repo-creds -o yaml |
  "${KUBECTL}" apply -f - >/dev/null

actual_type="$("${KUBECTL}" -n argocd get secret "${SECRET_NAME}" \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
test "${actual_type}" = repo-creds || {
  echo "Argo CD repository credential label was not applied" >&2
  exit 1
}

echo "Argo CD GitHub App credential template configured for:"
echo "  https://github.com/${GITHUB_OWNER}"
echo "Secret values were not printed."
