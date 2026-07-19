#!/usr/bin/env python3
"""Apply one validated deployment candidate to a registered application."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

MAX_JSON_BYTES = 128 * 1024
SCHEMA_VERSION = 1
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
CHECKSUM_PATTERN = re.compile(r"^[0-9a-f]{64}$")
NAME_PATTERN = re.compile(r"^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", re.ASCII)
VERSION_PATTERN = re.compile(
    r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:\.dev0)?$",
    re.ASCII,
)
HEAD_PATTERN = re.compile(r"^[0-9A-Za-z][0-9A-Za-z_.-]{0,31}$")

CANDIDATE_KEYS = {
    "schemaVersion",
    "application",
    "sourceRepository",
    "sourceRevision",
    "sourceCreatedAt",
    "version",
    "releaseKind",
    "imageRepository",
    "imageDigest",
    "image",
    "platform",
    "evidence",
    "migration",
}
EVIDENCE_KEYS = {"publicationRecordSha256", "publicationRun", "ciRun"}
CANDIDATE_MIGRATION_KEYS = {"kind", "head"}
REGISTRATION_KEYS = {
    "schemaVersion",
    "name",
    "project",
    "source",
    "destination",
    "release",
    "migration",
}
SOURCE_KEYS = {"repository", "repoURL", "path", "revision"}
DESTINATION_KEYS = {"server", "namespace"}
RELEASE_KEYS = {
    "version",
    "releaseKind",
    "sourceRevision",
    "sourceCreatedAt",
    "imageRepository",
    "imageDigest",
    "image",
    "platform",
    "publicationRecordSha256",
    "publicationRun",
    "ciRun",
}
MIGRATION_KEYS = RELEASE_KEYS | {"kind", "head", "generation"}


class RegistryError(ValueError):
    """The candidate or registered deployment contract is invalid."""


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RegistryError(f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def _load_json(path: Path, label: str) -> dict[str, Any]:
    raw = path.read_bytes()
    if not raw or len(raw) > MAX_JSON_BYTES:
        raise RegistryError(f"{label} must be between 1 byte and 128 KiB")
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RegistryError(f"{label} is not valid UTF-8 JSON") from error
    if type(value) is not dict:
        raise RegistryError(f"{label} must be a JSON object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) == expected:
        return
    missing = sorted(expected - set(value))
    extra = sorted(set(value) - expected)
    raise RegistryError(
        f"{label} keys do not match schema; missing={missing}, extra={extra}"
    )


def _object(value: dict[str, Any], key: str, label: str) -> dict[str, Any]:
    child = value[key]
    if type(child) is not dict:
        raise RegistryError(f"{label}.{key} must be an object")
    return child


def _string(value: dict[str, Any], key: str, label: str) -> str:
    child = value[key]
    if type(child) is not str or not child:
        raise RegistryError(f"{label}.{key} must be a non-empty string")
    if "\n" in child or "\r" in child:
        raise RegistryError(f"{label}.{key} must be a single-line string")
    return child


def _schema_version(value: dict[str, Any], label: str) -> None:
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise RegistryError(f"{label}.schemaVersion must be {SCHEMA_VERSION}")


def _timestamp(value: str, label: str) -> None:
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise RegistryError(f"{label} must be a whole-second UTC timestamp") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise RegistryError(f"{label} is not canonical")


def _version(version: str, release_kind: str, label: str) -> None:
    if not VERSION_PATTERN.fullmatch(version):
        raise RegistryError(f"{label}.version is invalid")
    expected_kind = "development" if version.endswith(".dev0") else "stable"
    if release_kind != expected_kind:
        raise RegistryError(f"{label}.releaseKind does not match its version")


def _run_url(value: str, repository: str, label: str) -> None:
    prefix = f"https://github.com/{repository}/actions/runs/"
    run_id = value.removeprefix(prefix)
    if value == run_id or not run_id.isdecimal() or run_id.startswith("0"):
        raise RegistryError(f"{label} is not a recognized Actions run URL")


def _release_identity(
    value: dict[str, Any],
    *,
    repository: str,
    label: str,
    migration: bool,
) -> None:
    _exact_keys(value, MIGRATION_KEYS if migration else RELEASE_KEYS, label)
    version = _string(value, "version", label)
    release_kind = _string(value, "releaseKind", label)
    _version(version, release_kind, label)
    revision = _string(value, "sourceRevision", label)
    if not SHA_PATTERN.fullmatch(revision):
        raise RegistryError(f"{label}.sourceRevision must be a full Git SHA")
    _timestamp(_string(value, "sourceCreatedAt", label), f"{label}.sourceCreatedAt")
    image_repository = _string(value, "imageRepository", label)
    digest = _string(value, "imageDigest", label)
    if not DIGEST_PATTERN.fullmatch(digest):
        raise RegistryError(f"{label}.imageDigest must be an immutable sha256 digest")
    if _string(value, "image", label) != f"{image_repository}@{digest}":
        raise RegistryError(f"{label}.image does not match its repository and digest")
    if _string(value, "platform", label) != "linux/arm64":
        raise RegistryError(f"{label}.platform must be linux/arm64")
    checksum = _string(value, "publicationRecordSha256", label)
    if not CHECKSUM_PATTERN.fullmatch(checksum):
        raise RegistryError(f"{label}.publicationRecordSha256 is invalid")
    _run_url(
        _string(value, "publicationRun", label), repository, f"{label}.publicationRun"
    )
    _run_url(_string(value, "ciRun", label), repository, f"{label}.ciRun")
    if migration:
        if _string(value, "kind", label) != "alembic":
            raise RegistryError(f"{label}.kind must be alembic")
        if not HEAD_PATTERN.fullmatch(_string(value, "head", label)):
            raise RegistryError(f"{label}.head is invalid")
        generation = value["generation"]
        if type(generation) is not int or generation < 1:
            raise RegistryError(f"{label}.generation must be a positive integer")


def validate_candidate(candidate: dict[str, Any]) -> None:
    """Validate the platform-neutral input produced by an application."""
    _exact_keys(candidate, CANDIDATE_KEYS, "candidate")
    _schema_version(candidate, "candidate")
    name = _string(candidate, "application", "candidate")
    if len(name) > 63 or not NAME_PATTERN.fullmatch(name):
        raise RegistryError("candidate.application must be a DNS label")
    repository = _string(candidate, "sourceRepository", "candidate")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise RegistryError("candidate.sourceRepository is invalid")
    revision = _string(candidate, "sourceRevision", "candidate")
    if not SHA_PATTERN.fullmatch(revision):
        raise RegistryError("candidate.sourceRevision must be a full Git SHA")
    _timestamp(
        _string(candidate, "sourceCreatedAt", "candidate"),
        "candidate.sourceCreatedAt",
    )
    version = _string(candidate, "version", "candidate")
    release_kind = _string(candidate, "releaseKind", "candidate")
    _version(version, release_kind, "candidate")
    image_repository = _string(candidate, "imageRepository", "candidate")
    digest = _string(candidate, "imageDigest", "candidate")
    if not DIGEST_PATTERN.fullmatch(digest):
        raise RegistryError("candidate.imageDigest must be an immutable sha256 digest")
    if _string(candidate, "image", "candidate") != f"{image_repository}@{digest}":
        raise RegistryError("candidate.image does not match its repository and digest")
    if _string(candidate, "platform", "candidate") != "linux/arm64":
        raise RegistryError("candidate.platform must be linux/arm64")

    evidence = _object(candidate, "evidence", "candidate")
    _exact_keys(evidence, EVIDENCE_KEYS, "candidate.evidence")
    checksum = _string(evidence, "publicationRecordSha256", "candidate.evidence")
    if not CHECKSUM_PATTERN.fullmatch(checksum):
        raise RegistryError("candidate publication record checksum is invalid")
    _run_url(
        _string(evidence, "publicationRun", "candidate.evidence"),
        repository,
        "candidate.evidence.publicationRun",
    )
    _run_url(
        _string(evidence, "ciRun", "candidate.evidence"),
        repository,
        "candidate.evidence.ciRun",
    )

    migration = _object(candidate, "migration", "candidate")
    _exact_keys(migration, CANDIDATE_MIGRATION_KEYS, "candidate.migration")
    if _string(migration, "kind", "candidate.migration") != "alembic":
        raise RegistryError("candidate.migration.kind must be alembic")
    if not HEAD_PATTERN.fullmatch(_string(migration, "head", "candidate.migration")):
        raise RegistryError("candidate.migration.head is invalid")


def validate_registration(registration: dict[str, Any]) -> None:
    """Validate one complete environment registration and release ledger."""
    _exact_keys(registration, REGISTRATION_KEYS, "registration")
    _schema_version(registration, "registration")
    name = _string(registration, "name", "registration")
    if len(name) > 63 or not NAME_PATTERN.fullmatch(name):
        raise RegistryError("registration.name must be a DNS label")
    if _string(registration, "project", "registration") != "personal-apps":
        raise RegistryError("registration.project must be personal-apps")

    source = _object(registration, "source", "registration")
    _exact_keys(source, SOURCE_KEYS, "registration.source")
    repository = _string(source, "repository", "registration.source")
    if not REPOSITORY_PATTERN.fullmatch(repository):
        raise RegistryError("registration.source.repository is invalid")
    expected_url = f"https://github.com/{repository}.git"
    if _string(source, "repoURL", "registration.source") != expected_url:
        raise RegistryError("registration.source.repoURL does not match its repository")
    path = Path(_string(source, "path", "registration.source"))
    if path.is_absolute() or ".." in path.parts or path.as_posix() in {"", "."}:
        raise RegistryError("registration.source.path must be a safe relative path")
    if not SHA_PATTERN.fullmatch(_string(source, "revision", "registration.source")):
        raise RegistryError("registration.source.revision must be a full Git SHA")

    destination = _object(registration, "destination", "registration")
    _exact_keys(destination, DESTINATION_KEYS, "registration.destination")
    if (
        _string(destination, "server", "registration.destination")
        != "https://kubernetes.default.svc"
    ):
        raise RegistryError("registration.destination.server must be in-cluster")
    namespace = _string(destination, "namespace", "registration.destination")
    if len(namespace) > 63 or not NAME_PATTERN.fullmatch(namespace):
        raise RegistryError("registration.destination.namespace must be a DNS label")

    _release_identity(
        _object(registration, "release", "registration"),
        repository=repository,
        label="registration.release",
        migration=False,
    )
    _release_identity(
        _object(registration, "migration", "registration"),
        repository=repository,
        label="registration.migration",
        migration=True,
    )


def _validate_update_boundary(
    registration: dict[str, Any], candidate: dict[str, Any]
) -> None:
    """Require a candidate to stay inside one registered application boundary."""
    validate_registration(registration)
    validate_candidate(candidate)
    source = _object(registration, "source", "registration")
    release = _object(registration, "release", "registration")
    if candidate["application"] != registration["name"]:
        raise RegistryError("candidate application does not match registration")
    if candidate["sourceRepository"] != source["repository"]:
        raise RegistryError("candidate source repository does not match registration")
    if candidate["imageRepository"] != release["imageRepository"]:
        raise RegistryError("candidate image repository does not match registration")


def update_registration(
    registration: dict[str, Any], candidate: dict[str, Any]
) -> tuple[dict[str, Any], bool]:
    """Return a registry copy with only source and runtime release fields updated."""
    _validate_update_boundary(registration, candidate)

    updated = copy.deepcopy(registration)
    updated["source"]["revision"] = candidate["sourceRevision"]
    evidence = candidate["evidence"]
    updated["release"] = {
        "version": candidate["version"],
        "releaseKind": candidate["releaseKind"],
        "sourceRevision": candidate["sourceRevision"],
        "sourceCreatedAt": candidate["sourceCreatedAt"],
        "imageRepository": candidate["imageRepository"],
        "imageDigest": candidate["imageDigest"],
        "image": candidate["image"],
        "platform": candidate["platform"],
        "publicationRecordSha256": evidence["publicationRecordSha256"],
        "publicationRun": evidence["publicationRun"],
        "ciRun": evidence["ciRun"],
    }
    validate_registration(updated)
    return updated, updated != registration


def update_migration_registration(
    registration: dict[str, Any], candidate: dict[str, Any]
) -> tuple[dict[str, Any], bool]:
    """Return a copy with only a new forward migration identity registered."""
    _validate_update_boundary(registration, candidate)
    current = _object(registration, "migration", "registration")
    requested = _object(candidate, "migration", "candidate")
    if requested["head"] == current["head"]:
        return copy.deepcopy(registration), False

    evidence = _object(candidate, "evidence", "candidate")
    updated = copy.deepcopy(registration)
    updated["migration"] = {
        "version": candidate["version"],
        "releaseKind": candidate["releaseKind"],
        "sourceRevision": candidate["sourceRevision"],
        "sourceCreatedAt": candidate["sourceCreatedAt"],
        "imageRepository": candidate["imageRepository"],
        "imageDigest": candidate["imageDigest"],
        "image": candidate["image"],
        "platform": candidate["platform"],
        "publicationRecordSha256": evidence["publicationRecordSha256"],
        "publicationRun": evidence["publicationRun"],
        "ciRun": evidence["ciRun"],
        "kind": requested["kind"],
        "head": requested["head"],
        "generation": current["generation"] + 1,
    }
    validate_registration(updated)
    return updated, updated != registration


def write_registration(path: Path, registration: dict[str, Any]) -> None:
    """Atomically write the canonical registry JSON representation."""
    serialized = f"{json.dumps(registration, indent=2)}\n"
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(serialized, encoding="utf-8")
    temporary.replace(path)


def write_github_output(
    path: Path,
    *,
    changed: bool,
    migration_required: bool,
) -> None:
    """Append updater decisions for subsequent workflow steps."""
    with path.open("a", encoding="utf-8") as output:
        output.write(f"changed={'true' if changed else 'false'}\n")
        output.write(
            f"migration_required={'true' if migration_required else 'false'}\n"
        )


def safe_path(value: str) -> Path:
    path = Path(value)
    if ".." in path.parts:
        raise argparse.ArgumentTypeError(
            f"unsupported path {value!r}; '..' segments are not allowed"
        )
    return path


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registration", required=True, type=safe_path)
    parser.add_argument("--candidate", required=True, type=safe_path)
    parser.add_argument(
        "--component",
        choices=("release", "migration"),
        default="release",
        help="registry ledger to update (default: release)",
    )
    parser.add_argument("--github-output", type=safe_path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        registration = _load_json(args.registration, "registration")
        candidate = _load_json(args.candidate, "candidate")
        if args.component == "migration":
            updated, changed = update_migration_registration(
                registration, candidate
            )
            migration_required = False
        else:
            updated, changed = update_registration(registration, candidate)
            migration_required = (
                candidate["migration"]["head"]
                != registration["migration"]["head"]
            )
        if args.github_output is not None:
            write_github_output(
                args.github_output,
                changed=changed and not migration_required,
                migration_required=migration_required,
            )
        if migration_required:
            print(
                "application registry update deferred: register the forward-only "
                "migration first",
                file=sys.stderr,
            )
            return 3
        if changed:
            write_registration(args.registration, updated)
    except (OSError, RegistryError) as error:
        print(f"application registry update failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
