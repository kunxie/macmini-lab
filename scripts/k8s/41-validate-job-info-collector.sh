#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${ROOT_DIR}/k8s/apps/job-info-collector"
RELEASE_FILE="${APP_DIR}/release.yaml"
MIGRATION_FILE="${APP_DIR}/migration.yaml"
MIGRATION_RELEASE_FILE="${APP_DIR}/migration-release.yaml"
MIGRATION_RELEASE_PATH="k8s/apps/job-info-collector/migration-release.yaml"
MIGRATION_PUBLICATION_RECORD_FILE="${APP_DIR}/migration-publication-record.json"
APPLICATION_FILE="${ROOT_DIR}/k8s/argocd/applications/job-info-collector.yaml"
PROJECT_FILE="${ROOT_DIR}/k8s/argocd/applications/job-info-collector-project.yaml"
KUBECTL="${KUBECTL:-kubectl}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
KUBERNETES_SCHEMA_REVISION="${KUBERNETES_SCHEMA_REVISION:-5a65d88146aaabf1648f5a21fca28b6abf196f83}"
PREVIOUS_MIGRATION_REVISION=""
PREVIOUS_ALEMBIC_HEAD=""

fail() {
  echo "collector GitOps validation failed: $*" >&2
  exit 1
}

scalar() {
  local file="$1"
  local key="$2"
  awk -v key="${key}:" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}' \
    "${file}"
}

rendered_object() {
  local file="$1"
  local wanted_kind="$2"
  local wanted_name="$3"

  awk -v wanted_kind="${wanted_kind}" -v wanted_name="${wanted_name}" '
    function emit() {
      if (kind == wanted_kind && name == wanted_name) {
        printf "%s", document
      }
    }
    function reset() {
      document = ""
      kind = ""
      name = ""
      in_metadata = 0
    }
    BEGIN { reset() }
    /^---[[:space:]]*$/ {
      emit()
      reset()
      next
    }
    {
      document = document $0 ORS
      if ($0 ~ /^kind:[[:space:]]+/) {
        kind = $2
        gsub(/^"|"$/, "", kind)
      }
      if ($0 == "metadata:") {
        in_metadata = 1
        next
      }
      if (in_metadata && $0 ~ /^[^[:space:]]/) {
        in_metadata = 0
      }
      if (in_metadata && $0 ~ /^  name:[[:space:]]+/) {
        name = $2
        gsub(/^"|"$/, "", name)
      }
    }
    END { emit() }
  ' "${file}"
}

rendered_inventory() {
  local file="$1"

  awk '
    function emit() {
      if (kind != "" && name != "") {
        print kind "/" name
      }
    }
    function reset() {
      kind = ""
      name = ""
      in_metadata = 0
    }
    BEGIN { reset() }
    /^---[[:space:]]*$/ {
      emit()
      reset()
      next
    }
    /^kind:[[:space:]]+/ {
      kind = $2
      gsub(/^"|"$/, "", kind)
    }
    $0 == "metadata:" {
      in_metadata = 1
      next
    }
    in_metadata && $0 ~ /^[^[:space:]]/ { in_metadata = 0 }
    in_metadata && $0 ~ /^  name:[[:space:]]+/ {
      name = $2
      gsub(/^"|"$/, "", name)
    }
    END { emit() }
  ' "${file}"
}

yaml_scalar_count() {
  local document="$1"
  local key="$2"
  local expected="$3"

  awk -v key="${key}:" -v expected="${expected}" '
    $1 == key {
      value = $2
      gsub(/^"|"$/, "", value)
      if (value == expected) {
        count++
      }
    }
    END { print count + 0 }
  ' <<< "${document}"
}

rendered_job_argument() {
  local document="$1"

  awk '
    $1 == "-" && $2 == "args:" {
      blocks++
      in_args = 1
      match($0, /^[ ]*/)
      argument_prefix = substr($0, 1, RLENGTH) "  - "
      next
    }
    in_args && index($0, argument_prefix) == 1 {
      arguments++
      argument = substr($0, length(argument_prefix) + 1)
      gsub(/^"|"$/, "", argument)
      next
    }
    in_args { in_args = 0 }
    END {
      if (blocks == 1 && arguments == 1) {
        print argument
      } else {
        print "invalid-rendered-arguments"
      }
    }
  ' <<< "${document}"
}

validate_rendered_job_binding() {
  local label="$1"
  local document="$2"
  local expected_image="$3"
  local expected_version="$4"
  local expected_revision="$5"
  local expected_digest="$6"
  local expected_hook="$7"
  local expected_argument="$8"
  local -a job_images=()

  test -n "${document}" || fail "the rendered ${label} Job is missing"
  mapfile -t job_images < <(
    awk '
      $1 == "image:" {
        image = $2
        gsub(/^"|"$/, "", image)
        print image
      }
      $1 == "-" && $2 == "image:" {
        image = $3
        gsub(/^"|"$/, "", image)
        print image
      }
    ' <<< "${document}"
  )
  test "${#job_images[@]}" -eq 1 || \
    fail "the rendered ${label} Job must contain exactly one image"
  test "${job_images[0]}" = "${expected_image}" || \
    fail "the rendered ${label} Job image does not match its release identity"
  test "$(yaml_scalar_count "${document}" app.kubernetes.io/version "${expected_version}")" -eq 2 || \
    fail "the rendered ${label} Job version does not match its release identity"
  test "$(yaml_scalar_count "${document}" job-info-collector.kunxie.dev/source-revision "${expected_revision}")" -eq 2 || \
    fail "the rendered ${label} Job source revision does not match its release identity"
  test "$(yaml_scalar_count "${document}" job-info-collector.kunxie.dev/image-digest "${expected_digest}")" -eq 2 || \
    fail "the rendered ${label} Job image digest does not match its release identity"
  test "$(yaml_scalar_count "${document}" argocd.argoproj.io/hook "${expected_hook}")" -eq 1 || \
    fail "the rendered ${label} Job must be an Argo CD ${expected_hook} hook"
  test "$(awk '$1 == "command:" || ($1 == "-" && $2 == "command:") {count++} END {print count + 0}' <<< "${document}")" -eq 0 || \
    fail "the rendered ${label} Job must not override the image entrypoint"
  test "$(rendered_job_argument "${document}")" = "${expected_argument}" || \
    fail "the rendered ${label} Job must run only ${expected_argument}"
}

validate_exact_migration_runtime() {
  local job_document="$1"
  local policy_document="$2"
  local default_deny_document="$3"
  local actual_pod_spec
  local expected_default_deny
  local expected_pod_spec
  local expected_policy

  test "$(yaml_scalar_count "${job_document}" activeDeadlineSeconds 300)" -eq 1 || \
    fail "the rendered migration Job must retain its five-minute deadline"
  test "$(yaml_scalar_count "${job_document}" backoffLimit 1)" -eq 1 || \
    fail "the rendered migration Job must allow exactly one retry"
  test "$(yaml_scalar_count "${job_document}" completions 1)" -eq 1 || \
    fail "the rendered migration Job must have exactly one completion"
  test "$(yaml_scalar_count "${job_document}" parallelism 1)" -eq 1 || \
    fail "the rendered migration Job must have parallelism one"
  test "$(yaml_scalar_count "${job_document}" argocd.argoproj.io/hook-delete-policy BeforeHookCreation)" -eq 1 || \
    fail "the rendered migration Job must be replaced before every hook run"
  test "$(yaml_scalar_count "${job_document}" argocd.argoproj.io/sync-wave 0)" -eq 1 || \
    fail "the rendered migration Job must run in PreSync wave zero"

  actual_pod_spec="$(awk '
    /^    spec:$/ { in_pod_spec = 1 }
    in_pod_spec { print }
  ' <<< "${job_document}")"
  expected_pod_spec="$(cat <<EOF
    spec:
      automountServiceAccountToken: false
      containers:
      - args:
        - migrate
        env:
        - name: JIC_DATABASE_USERNAME
          valueFrom:
            secretKeyRef:
              key: username
              name: job-info-collector-db-credentials
        - name: JIC_DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              key: password
              name: job-info-collector-db-credentials
        - name: JIC_DATABASE_HOST
          valueFrom:
            secretKeyRef:
              key: host
              name: job-info-collector-db-credentials
        - name: JIC_DATABASE_PORT
          valueFrom:
            secretKeyRef:
              key: port
              name: job-info-collector-db-credentials
        - name: JIC_DATABASE_NAME
          valueFrom:
            secretKeyRef:
              key: dbname
              name: job-info-collector-db-credentials
        image: ${migration_reference}
        imagePullPolicy: Always
        name: database-migration
        resources:
          limits:
            cpu: 250m
            memory: 256Mi
          requests:
            cpu: 10m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          privileged: false
          readOnlyRootFilesystem: true
      enableServiceLinks: false
      restartPolicy: Never
      securityContext:
        runAsGroup: 10001
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
EOF
)"
  test "${actual_pod_spec}" = "${expected_pod_spec}" || \
    fail "the rendered migration pod must expose only the approved database credential and runtime surface"

  expected_policy='apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
  labels:
    app.kubernetes.io/component: database-migration
    app.kubernetes.io/name: job-info-collector
    app.kubernetes.io/part-of: job-info-collector
  name: job-info-collector-database-migration-egress
  namespace: job-info-collector
spec:
  egress:
  - ports:
    - port: 53
      protocol: UDP
    - port: 53
      protocol: TCP
    to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  - ports:
    - port: 5432
      protocol: TCP
    to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: data
      podSelector:
        matchLabels:
          cnpg.io/cluster: postgres
  podSelector:
    matchLabels:
      app.kubernetes.io/component: database-migration
      app.kubernetes.io/name: job-info-collector
  policyTypes:
  - Egress'
  test "${policy_document}" = "${expected_policy}" || \
    fail "the rendered migration NetworkPolicy must allow only cluster DNS and PostgreSQL egress"

  expected_default_deny='apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  labels:
    app.kubernetes.io/name: job-info-collector
    app.kubernetes.io/part-of: job-info-collector
  name: job-info-collector-default-deny
  namespace: job-info-collector
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: job-info-collector
  policyTypes:
  - Ingress
  - Egress'
  test "${default_deny_document}" = "${expected_default_deny}" || \
    fail "the rendered collector default-deny NetworkPolicy must not grant traffic"
}

validate_exact_verification_runtime() {
  local job_document="$1"
  local actual_pod_spec
  local expected_pod_spec

  test "$(yaml_scalar_count "${job_document}" activeDeadlineSeconds 300)" -eq 1 || \
    fail "the rendered verification Job must retain its five-minute deadline"
  test "$(yaml_scalar_count "${job_document}" backoffLimit 1)" -eq 1 || \
    fail "the rendered verification Job must allow exactly one retry"
  test "$(yaml_scalar_count "${job_document}" completions 1)" -eq 1 || \
    fail "the rendered verification Job must have exactly one completion"
  test "$(yaml_scalar_count "${job_document}" parallelism 1)" -eq 1 || \
    fail "the rendered verification Job must have parallelism one"
  test "$(yaml_scalar_count "${job_document}" argocd.argoproj.io/hook-delete-policy BeforeHookCreation)" -eq 1 || \
    fail "the rendered verification Job must be replaced before every hook run"

  actual_pod_spec="$(awk '
    /^    spec:$/ { in_pod_spec = 1 }
    in_pod_spec { print }
  ' <<< "${job_document}")"
  expected_pod_spec="$(cat <<EOF
    spec:
      automountServiceAccountToken: false
      containers:
      - args:
        - --version
        image: ${reference}
        imagePullPolicy: Always
        name: release-verification
        resources:
          limits:
            cpu: 100m
            memory: 128Mi
          requests:
            cpu: 10m
            memory: 32Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          privileged: false
          readOnlyRootFilesystem: true
      enableServiceLinks: false
      restartPolicy: Never
      securityContext:
        runAsGroup: 10001
        runAsNonRoot: true
        runAsUser: 10001
        seccompProfile:
          type: RuntimeDefault
EOF
)"
  test "${actual_pod_spec}" = "${expected_pod_spec}" || \
    fail "the rendered verification pod must not receive credentials, volumes, or extra runtime access"
}

validate_identity() {
  local label="$1"
  local version="$2"
  local revision="$3"
  local created="$4"
  local repository="$5"
  local digest="$6"
  local reference="$7"
  local platform="$8"
  local record_sha256="$9"
  local publication_run="${10}"
  local ci_run="${11}"

  [[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.dev[0-9]+)?$ ]] || \
    fail "${label} applicationVersion is not an accepted stable or development version"
  [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || \
    fail "${label} sourceRevision must be a full Git commit"
  [[ "${created}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
    fail "${label} sourceCreatedAt must be an exact UTC timestamp"
  test "${repository}" = "ghcr.io/kunxie/job-info-collector" || \
    fail "${label} imageRepository is not accepted"
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || \
    fail "${label} imageDigest is invalid"
  test "${reference}" = "${repository}@${digest}" || \
    fail "${label} imageReference does not match its repository and digest"
  test "${platform}" = "linux/arm64" || \
    fail "${label} platform must be linux/arm64"
  [[ "${record_sha256}" =~ ^[0-9a-f]{64}$ ]] || \
    fail "${label} publicationRecordSha256 is invalid"
  [[ "${publication_run}" =~ ^https://github\.com/kunxie/job-info-collector/actions/runs/[1-9][0-9]*$ ]] || \
    fail "${label} publicationRun is invalid"
  [[ "${ci_run}" =~ ^https://github\.com/kunxie/job-info-collector/actions/runs/[1-9][0-9]*$ ]] || \
    fail "${label} ciRun is invalid"
}

validate_migration_publication_record() {
  local actual_sha256
  local expected_release_kind=stable
  local record_bytes
  local short_revision="${migration_revision:0:12}"

  test -f "${MIGRATION_PUBLICATION_RECORD_FILE}" || \
    fail "the exact migration publication record artifact is missing"
  command -v jq >/dev/null 2>&1 || \
    fail "jq is required for migration publication record validation"
  command -v sha256sum >/dev/null 2>&1 || \
    fail "sha256sum is required for migration publication record validation"
  record_bytes="$(wc -c < "${MIGRATION_PUBLICATION_RECORD_FILE}")"
  test "${record_bytes}" -gt 0 && test "${record_bytes}" -le 65536 || \
    fail "the migration publication record must be between 1 byte and 64 KiB"
  actual_sha256="$(sha256sum "${MIGRATION_PUBLICATION_RECORD_FILE}" | awk '{print $1}')"
  test "${actual_sha256}" = "${migration_record_sha256}" || \
    fail "migration publicationRecordSha256 does not match the committed artifact bytes"
  if [[ "${migration_version}" == *.dev* ]]; then
    expected_release_kind=development
  fi

  if ! jq --exit-status \
    --argjson schema_version "${migration_record_schema}" \
    --arg application_version "${migration_version}" \
    --arg release_kind "${expected_release_kind}" \
    --arg source_commit "${migration_revision}" \
    --arg source_created_at "${migration_created}" \
    --arg image_tag "${migration_repository}:${migration_revision}" \
    --arg versioned_image_tag "${migration_repository}:${migration_version}-g${short_revision}" \
    --arg image_digest "${migration_digest}" \
    --arg alembic_head "${alembic_head}" \
    --arg platform "${migration_platform}" \
    --arg ci_run "${migration_ci_run}" \
    --arg publication_run "${migration_publication_run}" \
    '
      (type == "object") and
      (keys == [
        "alembic_head",
        "anonymous_pull",
        "application_version",
        "ci_run",
        "image_digest",
        "image_tag",
        "platform",
        "publication_run",
        "release_kind",
        "sbom",
        "schema_version",
        "source_commit",
        "source_created_at",
        "versioned_image_tag",
        "vulnerability_policy",
        "vulnerability_report"
      ]) and
      (.schema_version == $schema_version) and
      (.application_version == $application_version) and
      (.release_kind == $release_kind) and
      (.source_commit == $source_commit) and
      (.source_created_at == $source_created_at) and
      (.image_tag == $image_tag) and
      (.versioned_image_tag == $versioned_image_tag) and
      (.image_digest == $image_digest) and
      (.alembic_head == $alembic_head) and
      (.platform == $platform) and
      (.vulnerability_policy == "success") and
      (.anonymous_pull == "success") and
      (.sbom == "job-info-collector.cdx.json") and
      (.vulnerability_report == "trivy-published-image.json") and
      (.ci_run == $ci_run) and
      (.publication_run == $publication_run)
    ' "${MIGRATION_PUBLICATION_RECORD_FILE}" >/dev/null; then
    fail "migration publication record fields do not match the approved release identity"
  fi
}

version_is_not_older() {
  local current="$1"
  local previous="$2"
  local current_major current_minor current_patch current_dev
  local previous_major previous_minor previous_patch previous_dev
  local index
  local -a current_core previous_core
  local pattern='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(\.dev(0|[1-9][0-9]{0,8}))?$'

  [[ "${current}" =~ ${pattern} ]] || return 1
  current_major="${BASH_REMATCH[1]}"
  current_minor="${BASH_REMATCH[2]}"
  current_patch="${BASH_REMATCH[3]}"
  current_dev="${BASH_REMATCH[5]:-}"
  [[ "${previous}" =~ ${pattern} ]] || return 1
  previous_major="${BASH_REMATCH[1]}"
  previous_minor="${BASH_REMATCH[2]}"
  previous_patch="${BASH_REMATCH[3]}"
  previous_dev="${BASH_REMATCH[5]:-}"
  current_core=("${current_major}" "${current_minor}" "${current_patch}")
  previous_core=("${previous_major}" "${previous_minor}" "${previous_patch}")

  for index in 0 1 2; do
    if ((10#${current_core[index]} > 10#${previous_core[index]})); then
      return 0
    fi
    if ((10#${current_core[index]} < 10#${previous_core[index]})); then
      return 1
    fi
  done
  if [[ -z "${current_dev}" && -n "${previous_dev}" ]]; then
    return 0
  fi
  if [[ -n "${current_dev}" && -z "${previous_dev}" ]]; then
    return 1
  fi
  [[ -z "${current_dev}" ]] || ((10#${current_dev} >= 10#${previous_dev}))
}

validate_migration_history() {
  local base_ref="${BASE_REF:-}"
  local generation="$1"
  local base_document
  local base_generation
  local base_version
  local base_revision
  local base_created
  local base_digest
  local base_alembic_head
  local changed=false
  local key

  if [[ -z "${base_ref}" || "${base_ref}" =~ ^0+$ ]]; then
    return
  fi
  command -v git >/dev/null 2>&1 || fail "git is required for migration history validation"
  if ! git -C "${ROOT_DIR}" cat-file -e "${base_ref}^{commit}" 2>/dev/null; then
    fail "BASE_REF does not identify an existing Git commit"
  fi
  if ! git -C "${ROOT_DIR}" cat-file -e \
    "${base_ref}:${MIGRATION_RELEASE_PATH}" 2>/dev/null; then
    test "${generation}" -eq 1 || \
      fail "the first migration release must use migrationGeneration 1"
    return
  fi

  base_document="$(git -C "${ROOT_DIR}" show "${base_ref}:${MIGRATION_RELEASE_PATH}")"
  base_generation="$(awk '$1 == "migrationGeneration:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  [[ "${base_generation}" =~ ^[1-9][0-9]*$ ]] || \
    fail "the base migrationGeneration is invalid"
  base_version="$(awk '$1 == "applicationVersion:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  base_revision="$(awk '$1 == "sourceRevision:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  base_created="$(awk '$1 == "sourceCreatedAt:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  base_digest="$(awk '$1 == "imageDigest:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  base_alembic_head="$(awk '$1 == "alembicHead:" {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"
  [[ "${base_alembic_head}" =~ ^[0-9A-Za-z][0-9A-Za-z_.-]{0,31}$ ]] || \
    fail "the base alembicHead is invalid"
  PREVIOUS_ALEMBIC_HEAD="${base_alembic_head}"
  version_is_not_older "${migration_version}" "${base_version}" || \
    fail "migration applicationVersion must not move backward"
  [[ "${migration_created}" > "${base_created}" || \
    "${migration_created}" == "${base_created}" ]] || \
    fail "migration sourceCreatedAt must not move backward"
  if test "${migration_revision}" = "${base_revision}"; then
    test "${migration_digest}" = "${base_digest}" || \
      fail "one migration source revision must retain one immutable digest"
  else
    [[ "${migration_created}" > "${base_created}" ]] || \
      fail "a new migration source revision must have a later source timestamp"
    PREVIOUS_MIGRATION_REVISION="${base_revision}"
  fi

  for key in applicationVersion sourceRevision sourceCreatedAt imageRepository \
    imageDigest imageReference platform publicationRecordSha256 publicationRun \
    ciRun publicationSchemaVersion alembicHead; do
    if test "$(scalar "${MIGRATION_RELEASE_FILE}" "${key}")" != \
      "$(awk -v key="${key}:" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}' <<< "${base_document}")"; then
      changed=true
    fi
  done

  if test "${changed}" = true; then
    test "${generation}" -eq "$((base_generation + 1))" || \
      fail "a migration identity change must increment migrationGeneration exactly once"
  else
    test "${generation}" -eq "${base_generation}" || \
      fail "migrationGeneration must not change without a migration identity change"
  fi
}

command -v "${KUBECTL}" >/dev/null 2>&1 || fail "kubectl is required"
command -v "${KUBECONFORM}" >/dev/null 2>&1 || fail "kubeconform is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"
command -v sort >/dev/null 2>&1 || fail "sort is required"

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

inventory="$(rendered_inventory "${rendered}" | sort)"
expected_inventory='ConfigMap/job-info-collector-migration-release
ConfigMap/job-info-collector-release
Job/job-info-collector-database-migration
Job/job-info-collector-release-verification
NetworkPolicy/job-info-collector-database-migration-egress
NetworkPolicy/job-info-collector-default-deny'
test "${inventory}" = "${expected_inventory}" || \
  fail "the rendered collector resource inventory contains an unexpected or missing object"

if grep -Eq '^[[:space:]]*kind:[[:space:]]*(Secret|SealedSecret|ExternalSecret)[[:space:]]*$' "${rendered}"; then
  fail "secret resources are not allowed in the collector foundation"
fi
if grep -Eiq '^[[:space:]]*(password|secret|token|cookie|authorization|api[-_]?key):' "${rendered}"; then
  fail "a secret-like value was embedded in the rendered manifests"
fi

mapfile -t images < <(
  awk '
    $1 == "image:" {
      image = $2
      gsub(/^"|"$/, "", image)
      print image
    }
    $1 == "-" && $2 == "image:" {
      image = $3
      gsub(/^"|"$/, "", image)
      print image
    }
  ' "${rendered}"
)
test "${#images[@]}" -eq 2 || fail "expected migration and verification images"

version="$(scalar "${RELEASE_FILE}" applicationVersion)"
revision="$(scalar "${RELEASE_FILE}" sourceRevision)"
created="$(scalar "${RELEASE_FILE}" sourceCreatedAt)"
repository="$(scalar "${RELEASE_FILE}" imageRepository)"
digest="$(scalar "${RELEASE_FILE}" imageDigest)"
reference="$(scalar "${RELEASE_FILE}" imageReference)"
platform="$(scalar "${RELEASE_FILE}" platform)"
record_sha256="$(scalar "${RELEASE_FILE}" publicationRecordSha256)"
publication_run="$(scalar "${RELEASE_FILE}" publicationRun)"
ci_run="$(scalar "${RELEASE_FILE}" ciRun)"
validate_identity application "${version}" "${revision}" "${created}" \
  "${repository}" "${digest}" "${reference}" "${platform}" \
  "${record_sha256}" "${publication_run}" "${ci_run}"

migration_version="$(scalar "${MIGRATION_RELEASE_FILE}" applicationVersion)"
migration_revision="$(scalar "${MIGRATION_RELEASE_FILE}" sourceRevision)"
migration_created="$(scalar "${MIGRATION_RELEASE_FILE}" sourceCreatedAt)"
migration_repository="$(scalar "${MIGRATION_RELEASE_FILE}" imageRepository)"
migration_digest="$(scalar "${MIGRATION_RELEASE_FILE}" imageDigest)"
migration_reference="$(scalar "${MIGRATION_RELEASE_FILE}" imageReference)"
migration_platform="$(scalar "${MIGRATION_RELEASE_FILE}" platform)"
migration_record_schema="$(scalar "${MIGRATION_RELEASE_FILE}" publicationSchemaVersion)"
migration_record_sha256="$(scalar "${MIGRATION_RELEASE_FILE}" publicationRecordSha256)"
migration_publication_run="$(scalar "${MIGRATION_RELEASE_FILE}" publicationRun)"
migration_ci_run="$(scalar "${MIGRATION_RELEASE_FILE}" ciRun)"
migration_generation="$(scalar "${MIGRATION_RELEASE_FILE}" migrationGeneration)"
alembic_head="$(scalar "${MIGRATION_RELEASE_FILE}" alembicHead)"
validate_identity migration "${migration_version}" "${migration_revision}" \
  "${migration_created}" "${migration_repository}" "${migration_digest}" \
  "${migration_reference}" "${migration_platform}" \
  "${migration_record_sha256}" "${migration_publication_run}" "${migration_ci_run}"
test "${migration_record_schema}" = 5 || \
  fail "migration publicationSchemaVersion must be 5"
[[ "${migration_generation}" =~ ^[1-9][0-9]*$ ]] || \
  fail "migrationGeneration must be a positive integer"
[[ "${alembic_head}" =~ ^[0-9A-Za-z][0-9A-Za-z_.-]{0,31}$ ]] || \
  fail "alembicHead must be a valid Alembic revision identifier"
validate_migration_publication_record
validate_migration_history "${migration_generation}"

migration_job="$(rendered_object "${rendered}" Job \
  job-info-collector-database-migration)"
verification_job="$(rendered_object "${rendered}" Job \
  job-info-collector-release-verification)"
migration_policy="$(rendered_object "${rendered}" NetworkPolicy \
  job-info-collector-database-migration-egress)"
default_deny_policy="$(rendered_object "${rendered}" NetworkPolicy \
  job-info-collector-default-deny)"
validate_rendered_job_binding migration "${migration_job}" \
  "${migration_reference}" "${migration_version}" "${migration_revision}" \
  "${migration_digest}" PreSync migrate
validate_rendered_job_binding verification "${verification_job}" \
  "${reference}" "${version}" "${revision}" "${digest}" PostSync --version
validate_exact_verification_runtime "${verification_job}"
test "$(yaml_scalar_count "${migration_job}" job-info-collector.kunxie.dev/alembic-head "${alembic_head}")" -eq 2 || \
  fail "the rendered migration Job Alembic head does not match its release identity"
test "$(yaml_scalar_count "${migration_job}" job-info-collector.kunxie.dev/migration-generation "${migration_generation}")" -eq 2 || \
  fail "the rendered migration Job generation does not match its release identity"
validate_exact_migration_runtime "${migration_job}" "${migration_policy}" \
  "${default_deny_policy}"

for rendered_image in "${images[@]}"; do
  [[ "${rendered_image}" =~ ^ghcr\.io/kunxie/job-info-collector@sha256:[0-9a-f]{64}$ ]] || \
    fail "collector images must use the public repository and an immutable sha256 digest"
done
if grep -Fq 'replaced-by-kustomize' "${rendered}"; then
  fail "Kustomize did not replace every migration identity placeholder"
fi

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

grep -Fq 'argocd.argoproj.io/hook: PreSync' "${MIGRATION_FILE}" || \
  fail "the database migration must run as a PreSync hook"
grep -Fq 'argocd.argoproj.io/sync-wave: "-1"' "${MIGRATION_FILE}" || \
  fail "migration egress must be available before the migration Job"
grep -Fq 'argocd.argoproj.io/sync-wave: "0"' "${MIGRATION_FILE}" || \
  fail "the migration Job must run after its egress policy"
grep -Fq 'automountServiceAccountToken: false' "${MIGRATION_FILE}" || \
  fail "the migration pod must not receive a Kubernetes API token"
grep -Fq 'readOnlyRootFilesystem: true' "${MIGRATION_FILE}" || \
  fail "the migration container must use a read-only root filesystem"
grep -Fq 'allowPrivilegeEscalation: false' "${MIGRATION_FILE}" || \
  fail "the migration container must disallow privilege escalation"
grep -Fq "app.kubernetes.io/version: \"${migration_version}\"" \
  "${MIGRATION_RELEASE_FILE}" || \
  fail "migration release metadata does not expose its application version"
grep -Fq "job-info-collector.kunxie.dev/source-revision: \"${migration_revision}\"" \
  "${MIGRATION_RELEASE_FILE}" || \
  fail "migration release metadata does not expose its source revision"
grep -Fq "job-info-collector.kunxie.dev/image-digest: \"${migration_digest}\"" \
  "${MIGRATION_RELEASE_FILE}" || \
  fail "migration release metadata does not expose its image digest"
grep -Fq "job-info-collector.kunxie.dev/alembic-head: \"${alembic_head}\"" \
  "${MIGRATION_RELEASE_FILE}" || \
  fail "migration release metadata does not expose its Alembic head"
grep -Fq "job-info-collector.kunxie.dev/migration-generation: \"${migration_generation}\"" \
  "${MIGRATION_RELEASE_FILE}" || \
  fail "migration release metadata does not expose its generation"
grep -Fq 'cnpg.io/cluster: postgres' "${MIGRATION_FILE}" || \
  fail "migration egress must be limited to the PostgreSQL cluster"
grep -Fq 'k8s-app: kube-dns' "${MIGRATION_FILE}" || \
  fail "migration egress must allow only cluster DNS and PostgreSQL"
test "$(grep -Fc 'name: job-info-collector-db-credentials' "${MIGRATION_FILE}")" -eq 5 || \
  fail "the migration Job must use five keys from the existing database Secret"
for variable in USERNAME PASSWORD HOST PORT NAME; do
  grep -Fq "name: JIC_DATABASE_${variable}" "${MIGRATION_FILE}" || \
    fail "the migration Job is missing JIC_DATABASE_${variable}"
done
for key in username password host port dbname; do
  grep -Fq "key: ${key}" "${MIGRATION_FILE}" || \
    fail "the migration Job is missing database Secret key ${key}"
done
if grep -Eq '^[[:space:]]*- name: JIC_(S3|SOURCE|ALERT)_' "${MIGRATION_FILE}"; then
  fail "the migration Job must receive only database configuration"
fi

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
  command -v curl >/dev/null 2>&1 || fail "curl is required for source ancestry verification"
  command -v jq >/dev/null 2>&1 || fail "jq is required for source ancestry verification"
  declare -A inspected=()
  verify_image_contract() {
    local image="$1"
    local expected_version="$2"
    local expected_revision="$3"
    local expected_created="$4"
    local inspect_output

    if [[ -z "${inspected[${image}]:-}" ]]; then
      inspect_output="$(docker buildx imagetools inspect "${image}")"
      grep -Eq 'Platform:[[:space:]]+linux/arm64' <<< "${inspect_output}" || \
        fail "image ${image} does not publish a linux/arm64 manifest"
      docker pull --platform linux/arm64 "${image}" >/dev/null
      inspected["${image}"]=true
    fi
    test "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}")" = "${expected_version}" || \
      fail "image ${image} version label does not match release metadata"
    test "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${image}")" = "${expected_revision}" || \
      fail "image ${image} revision label does not match release metadata"
    test "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.created"}}' "${image}")" = "${expected_created}" || \
      fail "image ${image} created label does not match release metadata"
  }

  verify_image_contract "${reference}" "${version}" "${revision}" "${created}"
  verify_image_contract "${migration_reference}" "${migration_version}" \
    "${migration_revision}" "${migration_created}"
  reported_head="$(docker run --rm --platform linux/arm64 --network none \
    --read-only --user 10001:10001 --cap-drop ALL \
    --security-opt no-new-privileges "${migration_reference}" schema-head)"
  test "${reported_head}" = "${alembic_head}" || \
    fail "migration image packaged head does not match migration release metadata"

  schema_ancestor="${PREVIOUS_ALEMBIC_HEAD:-${alembic_head}}"
  if ! docker run --rm --platform linux/arm64 --network none \
    --read-only --user 10001:10001 --cap-drop ALL \
    --security-opt no-new-privileges "${migration_reference}" \
    schema-descends-from "${schema_ancestor}" >/dev/null; then
    fail "migration image schema does not descend from the required Alembic head"
  fi

  if [[ -n "${PREVIOUS_MIGRATION_REVISION}" ]]; then
    compare_url="https://api.github.com/repos/kunxie/job-info-collector/compare/${PREVIOUS_MIGRATION_REVISION}...${migration_revision}"
    curl_args=(--fail --location --silent --show-error --retry 3 \
      --header "Accept: application/vnd.github+json" \
      --header "X-GitHub-Api-Version: 2026-03-10")
    comparison_status="$(curl "${curl_args[@]}" "${compare_url}" | \
      jq --raw-output '.status')"
    test "${comparison_status}" = ahead || \
      fail "migration source revision must descend from the previous accepted revision"
  fi
fi

echo "collector application release is valid: ${version} ${revision} ${digest}"
echo "collector migration release is valid: generation ${migration_generation} ${alembic_head} ${migration_revision} ${migration_digest}"
