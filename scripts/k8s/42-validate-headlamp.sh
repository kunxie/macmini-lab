#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALUES_FILE="${ROOT_DIR}/k8s/infra/headlamp/values.yaml"
RESOURCES_DIR="${ROOT_DIR}/k8s/infra/headlamp/resources"
APPLICATION_FILE="${ROOT_DIR}/k8s/argocd/applications/headlamp.yaml"
PROJECT_FILE="${ROOT_DIR}/k8s/argocd/applications/infra-project.yaml"
HELM="${HELM:-helm}"
KUBECTL="${KUBECTL:-kubectl}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
KUBERNETES_SCHEMA_REVISION="${KUBERNETES_SCHEMA_REVISION:-5a65d88146aaabf1648f5a21fca28b6abf196f83}"
HEADLAMP_CHART_VERSION="0.43.0"
HEADLAMP_CHART_SHA256="6a6b8102984c07df31d800c27e0ea8fc91c766366ba7fcdc2ff4113b03ae9a75"
HEADLAMP_CHART_URL="https://github.com/kubernetes-sigs/headlamp/releases/download/headlamp-helm-${HEADLAMP_CHART_VERSION}/headlamp-${HEADLAMP_CHART_VERSION}.tgz"
HEADLAMP_IMAGE="ghcr.io/headlamp-k8s/headlamp:v0.43.0@sha256:5d03caa26df7a715079405df2949907160518750b9b62b6bf4de8d1a6142c541"

fail() {
  echo "Headlamp GitOps validation failed: $*" >&2
  exit 1
}

command -v "${HELM}" >/dev/null 2>&1 || fail "helm is required"
command -v "${KUBECTL}" >/dev/null 2>&1 || fail "kubectl is required"
command -v "${KUBECONFORM}" >/dev/null 2>&1 || fail "kubeconform is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

chart_path="${HEADLAMP_CHART_PATH:-${work_dir}/headlamp-${HEADLAMP_CHART_VERSION}.tgz}"
if [[ -z "${HEADLAMP_CHART_PATH:-}" ]]; then
  curl --fail --location --silent --show-error \
    --output "${chart_path}" "${HEADLAMP_CHART_URL}"
fi
test -f "${chart_path}" || fail "chart package does not exist: ${chart_path}"

actual_chart_sha256="$(sha256sum "${chart_path}" | awk '{print $1}')"
test "${actual_chart_sha256}" = "${HEADLAMP_CHART_SHA256}" || \
  fail "chart digest is ${actual_chart_sha256}, expected ${HEADLAMP_CHART_SHA256}"

"${HELM}" lint "${chart_path}" --values "${VALUES_FILE}"
"${HELM}" template headlamp "${chart_path}" \
  --namespace headlamp \
  --kube-version 1.36.2 \
  --values "${VALUES_FILE}" > "${work_dir}/chart.yaml"
"${KUBECTL}" kustomize "${RESOURCES_DIR}" > "${work_dir}/resources.yaml"

cp "${work_dir}/chart.yaml" "${work_dir}/all.yaml"
printf '\n---\n' >> "${work_dir}/all.yaml"
sed '/^apiVersion:/,$!d' "${work_dir}/resources.yaml" >> "${work_dir}/all.yaml"

"${KUBECONFORM}" \
  -kubernetes-version 1.36.0 \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_SCHEMA_REVISION}/{{ .NormalizedKubernetesVersion }}-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -strict \
  -summary \
  - < "${work_dir}/all.yaml"

if grep -Eq '^[[:space:]]*kind:[[:space:]]*(Secret|SealedSecret|ExternalSecret)[[:space:]]*$' \
  "${work_dir}/all.yaml"; then
  fail "secret resources are not allowed in the Headlamp deployment"
fi
if grep -Fq 'name: cluster-admin' "${work_dir}/all.yaml"; then
  fail "Headlamp must not receive cluster-admin"
fi

mapfile -t images < <(
  awk '$1 == "image:" {gsub(/^"|"$/, "", $2); print $2}' "${work_dir}/chart.yaml"
)
test "${#images[@]}" -eq 1 || fail "expected exactly one workload image"
test "${images[0]}" = "${HEADLAMP_IMAGE}" || \
  fail "Headlamp must use the pinned v0.43.0 image digest"

grep -Fq 'unsafeUseServiceAccountToken: false' "${VALUES_FILE}" || \
  fail "unsafe service-account login must remain disabled"
grep -A1 '^clusterRoleBinding:' "${VALUES_FILE}" | grep -Fq 'create: false' || \
  fail "the chart's default ClusterRoleBinding must remain disabled"
grep -Fq 'readOnlyRootFilesystem: true' "${VALUES_FILE}" || \
  fail "the Headlamp container must use a read-only root filesystem"
grep -Fq 'allowPrivilegeEscalation: false' "${VALUES_FILE}" || \
  fail "the Headlamp container must disallow privilege escalation"

grep -Fq 'name: view' "${RESOURCES_DIR}/viewer-rbac.yaml" || \
  fail "the login ServiceAccount must use the built-in view ClusterRole"
if grep -Eq '^[[:space:]]+- (create|delete|deletecollection|patch|update)[[:space:]]*$' \
  "${RESOURCES_DIR}/viewer-rbac.yaml"; then
  fail "the Headlamp login roles must not contain mutating verbs"
fi
grep -Fq 'ingressClassName: tailscale' "${RESOURCES_DIR}/ingress.yaml" || \
  fail "Headlamp must use the private Tailscale IngressClass"
grep -Fq 'name: headlamp' "${RESOURCES_DIR}/ingress.yaml" || \
  fail "the Tailscale Ingress hostname is missing"

grep -Fq 'project: infrastructure' "${APPLICATION_FILE}" || \
  fail "the Application must use the infrastructure AppProject"
grep -Fq 'targetRevision: 0.43.0' "${APPLICATION_FILE}" || \
  fail "the Application chart version must remain pinned"
grep -Fq 'path: k8s/infra/headlamp/resources' "${APPLICATION_FILE}" || \
  fail "the Application must reconcile the local RBAC and Ingress resources"
grep -Fq 'namespace: headlamp' "${PROJECT_FILE}" || \
  fail "the infrastructure AppProject must allow the Headlamp namespace"
grep -Fq 'https://kubernetes-sigs.github.io/headlamp/' "${PROJECT_FILE}" || \
  fail "the infrastructure AppProject must allow the official chart repository"

if test "${CHECK_IMAGE_PLATFORM:-false}" = true; then
  command -v docker >/dev/null 2>&1 || fail "docker is required for platform verification"
  inspect_output="$(docker buildx imagetools inspect "${HEADLAMP_IMAGE}")"
  grep -Eq 'Platform:[[:space:]]+linux/arm64' <<< "${inspect_output}" || \
    fail "the Headlamp image digest does not publish a linux/arm64 manifest"
fi

echo "Headlamp GitOps deployment is valid: chart ${HEADLAMP_CHART_VERSION} (${HEADLAMP_CHART_SHA256})"
