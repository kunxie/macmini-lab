#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${ROOT_DIR}/k8s/apps/job-info-collector"
RELEASE_FILE="${APP_DIR}/release.yaml"
APPLICATION_FILE="${ROOT_DIR}/k8s/argocd/applications/job-info-collector.yaml"
PROJECT_FILE="${ROOT_DIR}/k8s/argocd/applications/job-info-collector-project.yaml"
KUBECTL="${KUBECTL:-kubectl}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
KUBERNETES_SCHEMA_REVISION="${KUBERNETES_SCHEMA_REVISION:-5a65d88146aaabf1648f5a21fca28b6abf196f83}"

fail() {
  echo "collector GitOps validation failed: $*" >&2
  exit 1
}

scalar() {
  local key="$1"
  awk -v key="${key}:" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}' \
    "${RELEASE_FILE}"
}

command -v "${KUBECTL}" >/dev/null 2>&1 || fail "kubectl is required"
command -v "${KUBECONFORM}" >/dev/null 2>&1 || fail "kubeconform is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"

rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT

"${KUBECTL}" kustomize "${APP_DIR}" > "${rendered}"
test -s "${rendered}" || fail "Kustomize rendered no resources"
"${KUBECONFORM}" \
  -kubernetes-version 1.36.0 \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_SCHEMA_REVISION}/{{ .NormalizedKubernetesVersion }}-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -strict \
  -summary \
  - < "${rendered}"

if grep -Eq '^[[:space:]]*kind:[[:space:]]*(Secret|SealedSecret|ExternalSecret)[[:space:]]*$' "${rendered}"; then
  fail "secret resources are not allowed in the collector foundation"
fi
if grep -Eiq '^[[:space:]]*(password|secret|token|cookie|authorization|api[-_]?key):' "${rendered}"; then
  fail "a secret-like value was embedded in the rendered manifests"
fi

mapfile -t images < <(
  awk '$1 == "image:" {gsub(/^"|"$/, "", $2); print $2}' "${rendered}"
)
test "${#images[@]}" -eq 1 || fail "expected exactly one workload image"
image="${images[0]}"
if [[ ! "${image}" =~ ^ghcr\.io/kunxie/job-info-collector@sha256:[0-9a-f]{64}$ ]]; then
  fail "the collector image must use the public repository and an immutable sha256 digest"
fi

version="$(scalar applicationVersion)"
revision="$(scalar sourceRevision)"
digest="$(scalar imageDigest)"
reference="$(scalar imageReference)"
platform="$(scalar platform)"

[[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.dev[0-9]+)?$ ]] || \
  fail "applicationVersion is not an accepted stable or development version"
[[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || fail "sourceRevision must be a full Git commit"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "imageDigest is invalid"
test "${reference}" = "${image}" || fail "imageReference and the Job image differ"
test "${digest}" = "${image#*@}" || fail "imageDigest and the Job image differ"
test "${platform}" = "linux/arm64" || fail "the declared platform must be linux/arm64"

grep -Fq "app.kubernetes.io/version: \"${version}\"" "${RELEASE_FILE}" || \
  fail "release resources do not expose app.kubernetes.io/version"
grep -Fq "job-info-collector.kunxie.dev/source-revision: \"${revision}\"" "${RELEASE_FILE}" || \
  fail "release resources do not expose the source revision"
grep -Fq 'argocd.argoproj.io/hook: PostSync' "${RELEASE_FILE}" || \
  fail "the release verification Job must block PostSync acceptance"
grep -Fq 'automountServiceAccountToken: false' "${RELEASE_FILE}" || \
  fail "the verification pod must not receive a Kubernetes API token"
grep -Fq 'readOnlyRootFilesystem: true' "${RELEASE_FILE}" || \
  fail "the verification container must use a read-only root filesystem"
grep -Fq 'allowPrivilegeEscalation: false' "${RELEASE_FILE}" || \
  fail "the verification container must disallow privilege escalation"

grep -Fq 'project: job-info-collector' "${APPLICATION_FILE}" || \
  fail "the Application must use the dedicated AppProject"
grep -Fq 'path: k8s/apps/job-info-collector' "${APPLICATION_FILE}" || \
  fail "the Application source path is incorrect"
if grep -Fq 'managedNamespaceMetadata:' "${APPLICATION_FILE}"; then
  fail "the externally provisioned namespace must not be adopted by Argo CD"
fi
if grep -Fq 'ApplyOutOfSyncOnly=true' "${APPLICATION_FILE}"; then
  fail "selective sync would bypass the release verification hook"
fi
grep -Fq 'namespace: job-info-collector' "${PROJECT_FILE}" || \
  fail "the AppProject must be restricted to the collector namespace"

if test "${CHECK_IMAGE_PLATFORM:-false}" = true; then
  command -v docker >/dev/null 2>&1 || fail "docker is required for platform verification"
  inspect_output="$(docker buildx imagetools inspect "${image}")"
  grep -Eq 'Platform:[[:space:]]+linux/arm64' <<< "${inspect_output}" || \
    fail "the image digest does not publish a linux/arm64 manifest"
fi

echo "collector GitOps foundation is valid: ${version} ${revision} ${digest}"
