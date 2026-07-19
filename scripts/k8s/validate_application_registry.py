#!/usr/bin/env python3
"""Validate registered applications and monotonic environment release state."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

from update_application_release import (
    RegistryError,
    _load_json,
    validate_registration,
)

DEFAULT_REGISTRY_ROOT = Path("k8s/registry")
APPLICATION_SET = Path("k8s/argocd/applications/personal-applications.yaml")
PROJECT = Path("k8s/argocd/applications/personal-apps-project.yaml")


def _version_key(value: str) -> tuple[int, int, int, int]:
    base, separator, suffix = value.partition(".dev")
    major, minor, patch = (int(part) for part in base.split("."))
    stability = 0 if separator and suffix == "0" else 1
    return major, minor, patch, stability


def validate_history(
    current: dict[str, Any],
    previous: dict[str, Any],
) -> None:
    """Reject environment ownership drift and backward migration state."""
    stable_current = {
        "schemaVersion": current["schemaVersion"],
        "name": current["name"],
        "project": current["project"],
        "source": {
            key: current["source"][key] for key in ("repository", "repoURL", "path")
        },
        "destination": current["destination"],
    }
    stable_previous = {
        "schemaVersion": previous["schemaVersion"],
        "name": previous["name"],
        "project": previous["project"],
        "source": {
            key: previous["source"][key] for key in ("repository", "repoURL", "path")
        },
        "destination": previous["destination"],
    }
    if stable_current != stable_previous:
        raise RegistryError(
            "existing registration ownership fields cannot change during deployment"
        )

    current_release = current["release"]
    previous_release = previous["release"]
    if (
        current_release["sourceRevision"] == previous_release["sourceRevision"]
        and current_release["imageDigest"] != previous_release["imageDigest"]
    ):
        raise RegistryError("one release source revision must retain one digest")

    current_migration = current["migration"]
    previous_migration = previous["migration"]
    identity_keys = ("sourceRevision", "imageDigest", "head")
    identity_changed = any(
        current_migration[key] != previous_migration[key] for key in identity_keys
    )
    if not identity_changed:
        if current_migration != previous_migration:
            raise RegistryError(
                "migration evidence or generation changed without an identity change"
            )
        return

    if current_migration["sourceRevision"] == previous_migration["sourceRevision"]:
        raise RegistryError(
            "a migration identity change requires a new source revision"
        )
    if current_migration["generation"] != previous_migration["generation"] + 1:
        raise RegistryError(
            "migration identity change must increment generation exactly once"
        )
    if _version_key(current_migration["version"]) < _version_key(
        previous_migration["version"]
    ):
        raise RegistryError("migration version must not move backward")
    if current_migration["sourceCreatedAt"] <= previous_migration["sourceCreatedAt"]:
        raise RegistryError("new migration source time must be later")
    for key in ("imageRepository", "platform", "kind"):
        if current_migration[key] != previous_migration[key]:
            raise RegistryError(f"migration {key} cannot change")


def _base_registration(base_ref: str, relative_path: Path) -> dict[str, Any] | None:
    if not base_ref or base_ref == "0" * 40:
        return None
    commit = subprocess.run(
        ["git", "cat-file", "-e", f"{base_ref}^{{commit}}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if commit.returncode != 0:
        raise RegistryError("BASE_REF does not identify an existing Git commit")
    result = subprocess.run(
        ["git", "show", f"{base_ref}:{relative_path.as_posix()}"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RegistryError("base registration is not valid JSON") from error
    if type(value) is not dict:
        raise RegistryError("base registration must be a JSON object")
    return value


def _validate_migration_sync_trigger(application_set: str) -> None:
    """Require a persistent, metadata-only drift target for migration hooks."""
    expected_patch = '''          patches:
            - target:
                group: networking.k8s.io
                version: v1
                kind: NetworkPolicy
                name: "{{ .name }}-default-deny"
              patch: |-
                apiVersion: networking.k8s.io/v1
                kind: NetworkPolicy
                metadata:
                  name: "{{ .name }}-default-deny"
                  annotations:
                    platform.kunxie.dev/migration-generation: "{{ .migration.generation }}"
'''
    if expected_patch not in application_set:
        raise RegistryError(
            "personal ApplicationSet must patch only the persistent default-deny "
            "NetworkPolicy with the migration generation"
        )
    generation_annotation = (
        'platform.kunxie.dev/migration-generation: "{{ .migration.generation }}"'
    )
    if application_set.count(generation_annotation) != 2:
        raise RegistryError(
            "personal ApplicationSet must expose the migration generation on the "
            "Application and its persistent sync trigger"
        )
    if "commonAnnotations:" in application_set:
        raise RegistryError(
            "migration sync trigger must not annotate workload pod templates"
        )


def _validate_platform_templates() -> None:
    application_set = APPLICATION_SET.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")
    required_application_set_text = (
        "kind: ApplicationSet",
        "project: personal-apps",
        "path: k8s/registry/*/production.json",
        'targetRevision: "{{ .source.revision }}"',
        'platform.kunxie.dev/deployment-revision: "{{ .source.revision }}"',
        "platform-runtime-image={{ .release.image }}",
        "platform-migration-image={{ .migration.image }}",
        "preserveResourcesOnDeletion: true",
    )
    for expected in required_application_set_text:
        if expected not in application_set:
            raise RegistryError(
                f"personal ApplicationSet is missing required contract: {expected}"
            )
    _validate_migration_sync_trigger(application_set)
    required_project_text = (
        "name: personal-apps",
        "https://github.com/kunxie/*.git",
        "kind: Secret",
        "kind: Role",
        "kind: RoleBinding",
    )
    for expected in required_project_text:
        if expected not in project:
            raise RegistryError(
                f"personal AppProject is missing required boundary: {expected}"
            )


def validate_registry(root: Path, base_ref: str) -> int:
    """Validate every production registration and return its count."""
    paths = sorted(root.glob("*/production.json"))
    if not paths:
        raise RegistryError("application registry contains no production entries")
    unexpected = [
        path
        for path in root.rglob("*")
        if path.is_file() and path.name != "production.json"
    ]
    if unexpected:
        raise RegistryError(
            f"application registry contains unexpected files: {unexpected}"
        )

    names: set[str] = set()
    namespaces: set[str] = set()
    for path in paths:
        registration = _load_json(path, f"registration {path}")
        validate_registration(registration)
        canonical = f"{json.dumps(registration, indent=2)}\n"
        if path.read_text(encoding="utf-8") != canonical:
            raise RegistryError(f"{path} is not canonical indented JSON")
        if path.parent.name != registration["name"]:
            raise RegistryError(f"{path} directory does not match application name")
        if registration["name"] in names:
            raise RegistryError(f"duplicate application name: {registration['name']}")
        namespace = registration["destination"]["namespace"]
        if namespace in namespaces:
            raise RegistryError(f"duplicate destination namespace: {namespace}")
        names.add(registration["name"])
        namespaces.add(namespace)

        relative_path = path.relative_to(Path.cwd()) if path.is_absolute() else path
        previous = _base_registration(base_ref, relative_path)
        if previous is not None:
            validate_registration(previous)
            validate_history(registration, previous)

    _validate_platform_templates()
    return len(paths)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry-root", type=Path, default=DEFAULT_REGISTRY_ROOT)
    parser.add_argument("--base-ref", default="")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        count = validate_registry(args.registry_root, args.base_ref)
    except (OSError, RegistryError) as error:
        print(f"application registry validation failed: {error}", file=sys.stderr)
        return 2
    print(f"application registry is valid: {count} production registration(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
