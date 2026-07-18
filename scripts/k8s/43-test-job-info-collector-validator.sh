#!/usr/bin/env bash
# Exercise collector validator history and rendered-Job binding without network
# access, registry access, a Kubernetes cluster, or production credentials.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_KUBECTL="$(command -v "${KUBECTL:-kubectl}" || true)"
REAL_JQ="$(command -v jq || true)"

test -n "${REAL_KUBECTL}" || {
  echo "kubectl is required for collector validator tests" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "git is required for collector validator tests" >&2
  exit 1
}
if [[ -z "${REAL_JQ}" ]]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "jq or python3 is required for collector validator tests" >&2
    exit 1
  }
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
fixture="${work_dir}/repo"
mock_bin="${work_dir}/bin"
mkdir -p "${fixture}/scripts/k8s" "${mock_bin}"
cp -R "${ROOT_DIR}/k8s" "${fixture}/k8s"
cp "${ROOT_DIR}/scripts/k8s/41-validate-job-info-collector.sh" \
  "${fixture}/scripts/k8s/41-validate-job-info-collector.sh"

app_release="${fixture}/k8s/apps/job-info-collector/release.yaml"
migration_release="${fixture}/k8s/apps/job-info-collector/migration-release.yaml"
migration_record="${fixture}/k8s/apps/job-info-collector/migration-publication-record.json"
migration_revision="1111111111111111111111111111111111111111"
migration_digest="sha256:2222222222222222222222222222222222222222222222222222222222222222"
migration_reference="ghcr.io/kunxie/job-info-collector@${migration_digest}"
migration_head="0001_initial_schema"
base_migration_revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
base_migration_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
base_migration_head="0000_previous_schema"

sed -i \
  -e "s#^    job-info-collector.kunxie.dev/source-revision:.*#    job-info-collector.kunxie.dev/source-revision: \"${migration_revision}\"#" \
  -e "s#^    job-info-collector.kunxie.dev/image-digest:.*#    job-info-collector.kunxie.dev/image-digest: \"${migration_digest}\"#" \
  -e "s#^  sourceRevision:.*#  sourceRevision: \"${migration_revision}\"#" \
  -e 's#^  sourceCreatedAt:.*#  sourceCreatedAt: "2026-07-16T12:00:00Z"#' \
  -e "s#^  imageDigest:.*#  imageDigest: \"${migration_digest}\"#" \
  -e "s#^  imageReference:.*#  imageReference: \"${migration_reference}\"#" \
  -e 's#^  publicationRun:.*#  publicationRun: "https://github.com/kunxie/job-info-collector/actions/runs/2"#' \
  -e 's#^  ciRun:.*#  ciRun: "https://github.com/kunxie/job-info-collector/actions/runs/1"#' \
  "${migration_release}"

cat > "${migration_record}" <<EOF
{
  "schema_version": 5,
  "application_version": "0.4.0.dev0",
  "release_kind": "development",
  "source_commit": "${migration_revision}",
  "source_created_at": "2026-07-16T12:00:00Z",
  "image_tag": "ghcr.io/kunxie/job-info-collector:${migration_revision}",
  "versioned_image_tag": "ghcr.io/kunxie/job-info-collector:0.4.0.dev0-g${migration_revision:0:12}",
  "image_digest": "${migration_digest}",
  "alembic_head": "${migration_head}",
  "platform": "linux/arm64",
  "vulnerability_policy": "success",
  "anonymous_pull": "success",
  "sbom": "job-info-collector.cdx.json",
  "vulnerability_report": "trivy-published-image.json",
  "ci_run": "https://github.com/kunxie/job-info-collector/actions/runs/1",
  "publication_run": "https://github.com/kunxie/job-info-collector/actions/runs/2"
}
EOF
record_sha256="$(sha256sum "${migration_record}" | awk '{print $1}')"
sed -i \
  "s#^  publicationRecordSha256:.*#  publicationRecordSha256: \"${record_sha256}\"#" \
  "${migration_release}"
sed -i \
  -e 's/migration-generation: "1"/migration-generation: "2"/g' \
  -e 's/migrationGeneration: "1"/migrationGeneration: "2"/g' \
  "${migration_release}"

current_release_snapshot="${work_dir}/current-migration-release.yaml"
current_record_snapshot="${work_dir}/current-migration-publication-record.json"
cp "${migration_release}" "${current_release_snapshot}"
cp "${migration_record}" "${current_record_snapshot}"

sed -i \
  -e "s/${migration_revision}/${base_migration_revision}/g" \
  -e 's/2026-07-16T12:00:00Z/2026-07-16T11:00:00Z/g' \
  -e "s/${migration_digest}/${base_migration_digest}/g" \
  -e "s/${migration_head}/${base_migration_head}/g" \
  -e 's/migration-generation: "2"/migration-generation: "1"/g' \
  -e 's/migrationGeneration: "2"/migrationGeneration: "1"/g' \
  "${migration_release}"
sed -i \
  -e "s/${migration_revision}/${base_migration_revision}/g" \
  -e 's/2026-07-16T12:00:00Z/2026-07-16T11:00:00Z/g' \
  -e "s/${migration_digest}/${base_migration_digest}/g" \
  -e "s/${migration_head}/${base_migration_head}/g" \
  "${migration_record}"
base_record_sha256="$(sha256sum "${migration_record}" | awk '{print $1}')"
sed -i "s/${record_sha256}/${base_record_sha256}/g" "${migration_release}"

read_scalar() {
  local file="$1"
  local key="$2"
  awk -v key="${key}:" '$1 == key {gsub(/^"|"$/, "", $2); print $2; exit}' \
    "${file}"
}

app_version="$(read_scalar "${app_release}" applicationVersion)"
app_revision="$(read_scalar "${app_release}" sourceRevision)"
app_created="$(read_scalar "${app_release}" sourceCreatedAt)"
app_reference="$(read_scalar "${app_release}" imageReference)"
migration_version="$(read_scalar "${current_release_snapshot}" applicationVersion)"
migration_created="$(read_scalar "${current_release_snapshot}" sourceCreatedAt)"

cat > "${mock_bin}/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if test "${1:-}" != kustomize; then
  echo "the kubectl test double supports only kustomize" >&2
  exit 2
fi
if [[ -z "${RENDER_MUTATION:-}" ]]; then
  exec "${REAL_KUBECTL}" "$@"
fi
"${REAL_KUBECTL}" "$@" | awk \
  -v mode="${RENDER_MUTATION}" \
  -v app_reference="${TEST_APP_REFERENCE}" \
  -v migration_reference="${TEST_MIGRATION_REFERENCE}" '
    /^---[[:space:]]*$/ { job = ""; object = "" }
    $1 == "name:" && $2 == "job-info-collector-database-migration-egress" {
      object = "migration-policy"
    }
    $1 == "name:" && $2 == "job-info-collector-default-deny" {
      object = "default-deny-policy"
    }
    $1 == "name:" && $2 == "job-info-collector-release-verification-egress" {
      object = "verification-policy"
    }
    $1 == "name:" && $2 == "job-info-collector-database-migration" {
      job = "migration"
    }
    $1 == "name:" && $2 == "job-info-collector-release-verification" {
      job = "verification"
    }
    mode == "swap-images" && job == "migration" && $1 == "image:" {
      sub(/image:.*/, "image: " app_reference)
    }
    mode == "swap-images" && job == "verification" && $1 == "image:" {
      sub(/image:.*/, "image: " migration_reference)
    }
    mode == "wrong-migration-command" && job == "migration" &&
      $1 == "-" && $2 == "migrate" {
      sub(/migrate$/, "--version")
    }
    mode == "migration-entrypoint-override" && job == "migration" &&
      $1 == "-" && $2 == "migrate" {
      print
      print "        command:"
      print "        - /bin/false"
      next
    }
    mode == "wrong-verification-command" && job == "verification" &&
      $1 == "-" && $2 == "verify-services" {
      sub(/verify-services$/, "migrate")
    }
    mode == "unbounded-migration-job" && job == "migration" &&
      $1 == "activeDeadlineSeconds:" {
      sub(/300$/, "3600")
    }
    mode == "allow-all-migration-egress" &&
      object == "migration-policy" && $1 == "egress:" {
      print
      print "  - to:"
      print "    - ipBlock:"
      print "        cidr: 0.0.0.0/0"
      next
    }
    mode == "allow-all-verification-egress" &&
      object == "verification-policy" && $1 == "egress:" {
      print
      print "  - to:"
      print "    - ipBlock:"
      print "        cidr: 0.0.0.0/0"
      next
    }
    mode == "broaden-default-deny" &&
      object == "default-deny-policy" && $1 == "policyTypes:" {
      print "  egress:"
      print "  - {}"
    }
    mode == "extra-migration-secret" && job == "migration" &&
      $1 == "image:" {
      print "        - name: UNRELATED_CREDENTIAL"
      print "          valueFrom:"
      print "            secretKeyRef:"
      print "              key: token"
      print "              name: unrelated-secret"
    }
    mode == "migration-env-from" && job == "migration" &&
      $1 == "image:" {
      print "        envFrom:"
      print "        - secretRef:"
      print "            name: unrelated-secret"
    }
    mode == "migration-volume" && job == "migration" &&
      $1 == "enableServiceLinks:" {
      print "      volumes:"
      print "      - emptyDir: {}"
      print "        name: unexpected-scratch"
    }
    mode == "extra-migration-container" && job == "migration" &&
      $1 == "enableServiceLinks:" {
      print "      - image: " migration_reference
      print "        name: unexpected-sidecar"
    }
    mode == "migration-init-container" && job == "migration" &&
      $1 == "enableServiceLinks:" {
      print "      initContainers:"
      print "      - image: " migration_reference
      print "        name: unexpected-init"
    }
    mode == "extra-verification-container" && job == "verification" &&
      $1 == "enableServiceLinks:" {
      print "      - image: " migration_reference
      print "        name: unexpected-sidecar"
    }
    mode == "extra-verification-secret" && job == "verification" &&
      $1 == "image:" {
      print "        env:"
      print "        - name: UNRELATED_CREDENTIAL"
      print "          valueFrom:"
      print "            secretKeyRef:"
      print "              key: token"
      print "              name: unrelated-secret"
    }
    { print }
    END {
      if (mode == "additional-egress-policy") {
        print "---"
        print "apiVersion: networking.k8s.io/v1"
        print "kind: NetworkPolicy"
        print "metadata:"
        print "  name: unexpected-allow-all-egress"
        print "  namespace: job-info-collector"
        print "spec:"
        print "  podSelector:"
        print "    matchLabels:"
        print "      app.kubernetes.io/name: job-info-collector"
        print "  policyTypes:"
        print "  - Egress"
        print "  egress:"
        print "  - {}"
      }
    }
  '
EOF

cat > "${mock_bin}/kubeconform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
EOF

cat > "${mock_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if test "${1:-}" = buildx && test "${2:-}" = imagetools &&
  test "${3:-}" = inspect; then
  echo "Platform: linux/arm64"
  exit 0
fi
if test "${1:-}" = pull; then
  exit 0
fi
if test "${1:-}" = image && test "${2:-}" = inspect; then
  format="${4:-}"
  image="${5:-}"
  if test "${image}" = "${TEST_APP_REFERENCE}"; then
    version="${TEST_APP_VERSION}"
    revision="${TEST_APP_REVISION}"
    created="${TEST_APP_CREATED}"
  elif test "${image}" = "${TEST_MIGRATION_REFERENCE}"; then
    version="${TEST_MIGRATION_VERSION}"
    revision="${TEST_MIGRATION_REVISION}"
    created="${TEST_MIGRATION_CREATED}"
  else
    echo "unexpected image inspection: ${image}" >&2
    exit 2
  fi
  case "${format}" in
    *org.opencontainers.image.version*) echo "${version}" ;;
    *org.opencontainers.image.revision*) echo "${revision}" ;;
    *org.opencontainers.image.created*) echo "${created}" ;;
    *) echo "unexpected image inspection format: ${format}" >&2; exit 2 ;;
  esac
  exit 0
fi
if test "${1:-}" = run; then
  printf '%s\n' "$*" >> "${DOCKER_CALLS}"
  while (($# > 0)); do
    if test "$1" = "${TEST_MIGRATION_REFERENCE}"; then
      shift
      break
    fi
    shift
  done
  case "${1:-}" in
    schema-head)
      echo "${TEST_MIGRATION_HEAD}"
      exit 0
      ;;
    schema-descends-from)
      test "${2:-}" = "${TEST_PREVIOUS_HEAD}" || exit 2
      test "${SCHEMA_DESCENDS_FAILURE:-false}" != true
      exit 0
      ;;
  esac
fi
echo "unexpected docker invocation: $*" >&2
exit 2
EOF

cat > "${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"%s"}\n' "${COMPARISON_STATUS:-ahead}"
EOF

cat > "${mock_bin}/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${REAL_JQ:-}" ]]; then
  exec "${REAL_JQ}" "$@"
fi
for argument in "$@"; do
  if test "${argument}" = .status; then
    cat >/dev/null
    echo "${COMPARISON_STATUS:-ahead}"
    exit 0
  fi
done
record=""
while (($# > 0)); do
  case "$1" in
    --arg | --argjson)
      export "JQ_ARG_$2=$3"
      shift 3
      ;;
    *)
      if test -f "$1"; then
        record="$1"
      fi
      shift
      ;;
  esac
done
test -n "${record}"
python3 - "${record}" <<'PY'
import json
import os
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


with open(sys.argv[1], encoding="utf-8") as stream:
    actual = json.load(stream, object_pairs_hook=unique_object)
expected = {
    "schema_version": int(os.environ["JQ_ARG_schema_version"]),
    "application_version": os.environ["JQ_ARG_application_version"],
    "release_kind": os.environ["JQ_ARG_release_kind"],
    "source_commit": os.environ["JQ_ARG_source_commit"],
    "source_created_at": os.environ["JQ_ARG_source_created_at"],
    "image_tag": os.environ["JQ_ARG_image_tag"],
    "versioned_image_tag": os.environ["JQ_ARG_versioned_image_tag"],
    "image_digest": os.environ["JQ_ARG_image_digest"],
    "alembic_head": os.environ["JQ_ARG_alembic_head"],
    "platform": os.environ["JQ_ARG_platform"],
    "vulnerability_policy": "success",
    "anonymous_pull": "success",
    "sbom": "job-info-collector.cdx.json",
    "vulnerability_report": "trivy-published-image.json",
    "ci_run": os.environ["JQ_ARG_ci_run"],
    "publication_run": os.environ["JQ_ARG_publication_run"],
}
raise SystemExit(actual != expected)
PY
EOF

chmod +x "${mock_bin}/kubectl" "${mock_bin}/kubeconform" \
  "${mock_bin}/docker" "${mock_bin}/curl" "${mock_bin}/jq" \
  "${fixture}/scripts/k8s/41-validate-job-info-collector.sh"

git -C "${fixture}" init --quiet
git -C "${fixture}" config user.email validator-test@example.invalid
git -C "${fixture}" config user.name validator-test
git -C "${fixture}" commit --quiet --allow-empty -m "test: pre-migration base"
first_base_ref="$(git -C "${fixture}" rev-parse HEAD)"
git -C "${fixture}" add --all
git -C "${fixture}" commit --quiet -m "test: synthetic migration base"
base_ref="$(git -C "${fixture}" rev-parse HEAD)"
cp "${current_release_snapshot}" "${migration_release}"
cp "${current_record_snapshot}" "${migration_record}"
docker_calls="${work_dir}/docker-calls"

run_validator() {
  env \
    PATH="${mock_bin}:${PATH}" \
    KUBECTL="${mock_bin}/kubectl" \
    KUBECONFORM="${mock_bin}/kubeconform" \
    REAL_KUBECTL="${REAL_KUBECTL}" \
    REAL_JQ="${REAL_JQ}" \
    BASE_REF="${BASE_REF_OVERRIDE:-${base_ref}}" \
    CHECK_IMAGE_PLATFORM="${CHECK_IMAGE_PLATFORM_OVERRIDE:-false}" \
    RENDER_MUTATION="${RENDER_MUTATION_OVERRIDE:-}" \
    SCHEMA_DESCENDS_FAILURE="${SCHEMA_DESCENDS_FAILURE_OVERRIDE:-false}" \
    COMPARISON_STATUS="${COMPARISON_STATUS_OVERRIDE:-ahead}" \
    DOCKER_CALLS="${docker_calls}" \
    TEST_APP_REFERENCE="${app_reference}" \
    TEST_APP_VERSION="${app_version}" \
    TEST_APP_REVISION="${app_revision}" \
    TEST_APP_CREATED="${app_created}" \
    TEST_MIGRATION_REFERENCE="${migration_reference}" \
    TEST_MIGRATION_VERSION="${migration_version}" \
    TEST_MIGRATION_REVISION="${migration_revision}" \
    TEST_MIGRATION_CREATED="${migration_created}" \
    TEST_MIGRATION_HEAD="${migration_head}" \
    TEST_PREVIOUS_HEAD="${TEST_PREVIOUS_HEAD_OVERRIDE:-${base_migration_head}}" \
    "${fixture}/scripts/k8s/41-validate-job-info-collector.sh"
}

expect_failure() {
  local expected="$1"
  local output
  local status

  set +e
  output="$(run_validator 2>&1)"
  status=$?
  set -e
  test "${status}" -ne 0 || {
    echo "validator unexpectedly accepted: ${expected}" >&2
    exit 1
  }
  grep -Fq -- "${expected}" <<< "${output}" || {
    echo "validator failed for the wrong reason; expected: ${expected}" >&2
    echo "${output}" >&2
    exit 1
  }
}

run_validator >/dev/null

cp "${migration_record}" "${work_dir}/migration-publication-record.json"
printf '\n' >> "${migration_record}"
expect_failure "publicationRecordSha256 does not match the committed artifact bytes"
cp "${work_dir}/migration-publication-record.json" "${migration_record}"

cp "${migration_release}" "${work_dir}/migration-release.yaml"
sed -i 's/0001_initial_schema/0002_synthetic/g' "${migration_release}"
expect_failure "publication record fields do not match the approved release identity"
cp "${work_dir}/migration-release.yaml" "${migration_release}"

BASE_REF_OVERRIDE=ffffffffffffffffffffffffffffffffffffffff
expect_failure "BASE_REF does not identify an existing Git commit"
unset BASE_REF_OVERRIDE

BASE_REF_OVERRIDE="${first_base_ref}"
expect_failure "first migration release must use migrationGeneration 1"
unset BASE_REF_OVERRIDE

cp "${migration_release}" "${work_dir}/generation-two-history-release.yaml"
sed -i \
  -e 's/migration-generation: "2"/migration-generation: "1"/g' \
  -e 's/migrationGeneration: "2"/migrationGeneration: "1"/g' \
  "${migration_release}"
expect_failure "migration identity change must increment migrationGeneration exactly once"
cp "${work_dir}/generation-two-history-release.yaml" "${migration_release}"

RENDER_MUTATION_OVERRIDE=swap-images
expect_failure "rendered migration Job image does not match its release identity"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=wrong-migration-command
expect_failure "rendered migration Job must run only migrate"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=migration-entrypoint-override
expect_failure "rendered migration Job must not override the image entrypoint"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=wrong-verification-command
expect_failure "rendered verification Job must run only verify-services"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=extra-verification-secret
expect_failure "rendered verification pod must expose only the approved dependency credentials and runtime surface"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=allow-all-migration-egress
expect_failure "rendered migration NetworkPolicy must allow only cluster DNS and PostgreSQL egress"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=allow-all-verification-egress
expect_failure "rendered verification NetworkPolicy must allow only cluster DNS, PostgreSQL, and MinIO egress"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=additional-egress-policy
expect_failure "rendered collector resource inventory contains an unexpected or missing object"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=broaden-default-deny
expect_failure "rendered collector default-deny NetworkPolicy must not grant traffic"
unset RENDER_MUTATION_OVERRIDE

RENDER_MUTATION_OVERRIDE=unbounded-migration-job
expect_failure "rendered migration Job must retain its five-minute deadline"
unset RENDER_MUTATION_OVERRIDE

for mutation in extra-migration-secret migration-env-from migration-volume; do
  RENDER_MUTATION_OVERRIDE="${mutation}"
  expect_failure "rendered migration pod must expose only the approved database credential and runtime surface"
done
unset RENDER_MUTATION_OVERRIDE

for mutation in extra-migration-container migration-init-container \
  extra-verification-container; do
  RENDER_MUTATION_OVERRIDE="${mutation}"
  expect_failure "expected migration and verification images"
done
unset RENDER_MUTATION_OVERRIDE

CHECK_IMAGE_PLATFORM_OVERRIDE=true
BASE_REF_OVERRIDE="${first_base_ref}"
TEST_PREVIOUS_HEAD_OVERRIDE="${migration_head}"
cp "${migration_release}" "${work_dir}/generation-two-migration-release.yaml"
sed -i \
  -e 's/migration-generation: "2"/migration-generation: "1"/g' \
  -e 's/migrationGeneration: "2"/migrationGeneration: "1"/g' \
  "${migration_release}"
: > "${docker_calls}"
run_validator >/dev/null
grep -Fq -- "schema-descends-from ${migration_head}" "${docker_calls}" || {
  echo "first migration did not prove that its schema descends from itself" >&2
  exit 1
}
cp "${work_dir}/generation-two-migration-release.yaml" "${migration_release}"
unset BASE_REF_OVERRIDE
unset TEST_PREVIOUS_HEAD_OVERRIDE

: > "${docker_calls}"
run_validator >/dev/null
grep -Fq -- "schema-descends-from ${base_migration_head}" "${docker_calls}" || {
  echo "later migration did not prove ancestry from the accepted schema" >&2
  exit 1
}

SCHEMA_DESCENDS_FAILURE_OVERRIDE=true
expect_failure "schema does not descend from the required Alembic head"
unset SCHEMA_DESCENDS_FAILURE_OVERRIDE

COMPARISON_STATUS_OVERRIDE=diverged
expect_failure "migration source revision must descend from the previous accepted revision"

echo "collector validator regression tests passed"
