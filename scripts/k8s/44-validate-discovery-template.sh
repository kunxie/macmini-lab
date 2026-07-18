#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${ROOT_DIR}/k8s/apps/job-info-collector"
TEMPLATE_FILE="${APP_DIR}/templates/discovery-job.yaml"
KUSTOMIZATION_FILE="${APP_DIR}/kustomization.yaml"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
KUBERNETES_SCHEMA_REVISION="${KUBERNETES_SCHEMA_REVISION:-5a65d88146aaabf1648f5a21fca28b6abf196f83}"
ZERO_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000000"

fail() {
  echo "discovery template validation failed: $*" >&2
  exit 1
}

command -v "${KUBECONFORM}" >/dev/null 2>&1 || fail "kubeconform is required"
test -f "${TEMPLATE_FILE}" || fail "the reviewed discovery template is missing"

"${KUBECONFORM}" \
  -kubernetes-version 1.36.0 \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${KUBERNETES_SCHEMA_REVISION}/{{ .NormalizedKubernetesVersion }}-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json" \
  -strict \
  -summary \
  "${TEMPLATE_FILE}"

test "$(grep -Ec '^kind: (Job|NetworkPolicy)$' "${TEMPLATE_FILE}")" -eq 2 || \
  fail "the template must contain exactly one Job and one NetworkPolicy"
test "$(grep -Ec '^kind: Job$' "${TEMPLATE_FILE}")" -eq 1 || \
  fail "the template must contain exactly one Job"
test "$(grep -Ec '^kind: NetworkPolicy$' "${TEMPLATE_FILE}")" -eq 1 || \
  fail "the template must contain exactly one NetworkPolicy"

if grep -Fq 'templates/discovery-job.yaml' "${KUSTOMIZATION_FILE}"; then
  fail "the live-request template must not be reconciled by Argo CD"
fi
if grep -Fq 'argocd.argoproj.io/hook' "${TEMPLATE_FILE}"; then
  fail "the live-request template must not be an Argo CD hook"
fi

test "$(grep -Fc 'job-info-collector.kunxie.dev/explicit-operator-approval: required' "${TEMPLATE_FILE}")" -eq 3 || \
  fail "the explicit approval blocker must cover both resources and the pod"
grep -Fq 'name: replace-with-approved-discovery-job-name' "${TEMPLATE_FILE}" || \
  fail "the Job name must remain a fail-closed operator blocker"
grep -Fq 'name: replace-with-approved-discovery-egress-name' \
  "${TEMPLATE_FILE}" || \
  fail "the NetworkPolicy name must remain a fail-closed operator blocker"
test "$(grep -Fc 'replace-with-approval-id' "${TEMPLATE_FILE}")" -eq 4 || \
  fail "the approval ID blocker must bind both resources and the pod selector"
test "$(grep -Fc 'replace-with-approved-version' "${TEMPLATE_FILE}")" -eq 2 || \
  fail "the version blocker must cover the Job and pod"
test "$(grep -Fc 'replace-with-approved-revision' "${TEMPLATE_FILE}")" -eq 2 || \
  fail "the source-revision blocker must cover the Job and pod"
test "$(grep -Fc "${ZERO_DIGEST}" "${TEMPLATE_FILE}")" -eq 3 || \
  fail "the template must use the all-zero image-digest blocker exactly three times"
test "$(grep -Fc 'REPLACE_WITH_APPROVED_UTC_TIMESTAMP' "${TEMPLATE_FILE}")" -eq 3 || \
  fail "the approved UTC timestamp blocker must cover annotations and arguments"
test "$(grep -Fc 'REPLACE_WITH_APPROVED_POSITIVE_' "${TEMPLATE_FILE}")" -eq 4 || \
  fail "all four production alert thresholds must remain fail-closed"

grep -Fq 'activeDeadlineSeconds: 68400' "${TEMPLATE_FILE}" || \
  fail "the discovery Job must have the reviewed 19-hour active deadline"
grep -Fq 'backoffLimit: 0' "${TEMPLATE_FILE}" || \
  fail "Kubernetes must not retry an approved traversal as another pod"
grep -Fq 'completions: 1' "${TEMPLATE_FILE}" || \
  fail "the discovery Job must have one completion"
grep -Fq 'parallelism: 1' "${TEMPLATE_FILE}" || \
  fail "the discovery Job must have parallelism one"
grep -Fq 'restartPolicy: Never' "${TEMPLATE_FILE}" || \
  fail "the discovery pod must not restart in place"
grep -Fq 'automountServiceAccountToken: false' "${TEMPLATE_FILE}" || \
  fail "the discovery pod must not receive a Kubernetes API token"
grep -Fq 'readOnlyRootFilesystem: true' "${TEMPLATE_FILE}" || \
  fail "the discovery container must use a read-only root filesystem"
grep -Fq 'allowPrivilegeEscalation: false' "${TEMPLATE_FILE}" || \
  fail "the discovery container must disallow privilege escalation"
grep -Fq 'runAsUser: 10001' "${TEMPLATE_FILE}" || \
  fail "the discovery pod must run as the image's non-root UID"
grep -Fq 'runAsGroup: 10001' "${TEMPLATE_FILE}" || \
  fail "the discovery pod must run as the image's non-root GID"

grep -Fq 'value: production' "${TEMPLATE_FILE}" || \
  fail "the discovery Job must validate production configuration"
test "$(grep -Ec 'name: JIC_ALERT_' "${TEMPLATE_FILE}")" -eq 4 || \
  fail "the discovery Job must supply all four production alert thresholds"
grep -Fq 'value: https://careers.walmart.com' "${TEMPLATE_FILE}" || \
  fail "the template must target only the reviewed public source origin"
grep -Fq 'value: /api/graphql' "${TEMPLATE_FILE}" || \
  fail "the template must target the reviewed persisted-query endpoint"
test "$(grep -Fc 'name: job-info-collector-db-credentials' "${TEMPLATE_FILE}")" -eq 5 || \
  fail "the discovery Job must use five keys from the existing database Secret"
test "$(grep -Fc 'name: job-info-collector-minio-credentials' "${TEMPLATE_FILE}")" -eq 4 || \
  fail "the discovery Job must use four keys from the existing MinIO Secret"

grep -Fq 'cnpg.io/cluster: postgres' "${TEMPLATE_FILE}" || \
  fail "discovery database egress must target only the approved cluster"
grep -Fq 'v1.min.io/tenant: minio' "${TEMPLATE_FILE}" || \
  fail "discovery MinIO egress must target only the approved tenant"
grep -Fq 'k8s-app: kube-dns' "${TEMPLATE_FILE}" || \
  fail "discovery egress must include only cluster DNS resolution"
test "$(grep -Ec '^[[:space:]]+port: 443$' "${TEMPLATE_FILE}")" -eq 1 || \
  fail "discovery must receive exactly one public HTTPS egress rule"

echo "discovery Job template is schema-valid, finite, fail-closed, and opt-in"
