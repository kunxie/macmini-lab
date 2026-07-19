#!/usr/bin/env python3
"""Verify immutable registered images when the networked CI gate opts in."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from update_application_release import RegistryError, _load_json, validate_registration
from validate_application_registry import _base_registration

REGISTRY_ROOT = Path("k8s/registry")


def _run(arguments: list[str]) -> str:
    result = subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RegistryError(f"command failed: {' '.join(arguments)}: {detail}")
    return result.stdout.strip()


def _label(image: str, name: str) -> str:
    return _run(
        [
            "docker",
            "image",
            "inspect",
            "--format",
            f'{{{{index .Config.Labels "{name}"}}}}',
            image,
        ]
    )


def _verify_identity(identity: dict[str, object]) -> None:
    image = str(identity["image"])
    inspection = _run(["docker", "buildx", "imagetools", "inspect", image])
    if "linux/arm64" not in inspection:
        raise RegistryError(f"registered image does not expose linux/arm64: {image}")
    _run(["docker", "pull", "--platform", "linux/arm64", image])
    if _run(["docker", "image", "inspect", "--format", "{{.Architecture}}", image]) != (
        "arm64"
    ):
        raise RegistryError(f"registered image architecture is not arm64: {image}")
    expected_labels = {
        "org.opencontainers.image.version": str(identity["version"]),
        "org.opencontainers.image.revision": str(identity["sourceRevision"]),
        "org.opencontainers.image.created": str(identity["sourceCreatedAt"]),
    }
    for label, expected in expected_labels.items():
        if _label(image, label) != expected:
            raise RegistryError(
                f"registered image label {label} does not match: {image}"
            )


def _verify_migration(identity: dict[str, object], required_ancestor: str) -> None:
    image = str(identity["image"])
    security = [
        "docker",
        "run",
        "--rm",
        "--platform",
        "linux/arm64",
        "--network",
        "none",
        "--read-only",
        "--user",
        "10001:10001",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        image,
    ]
    head = str(identity["head"])
    if _run([*security, "schema-head"]) != head:
        raise RegistryError("migration image packaged head does not match registration")
    _run([*security, "schema-descends-from", required_ancestor])


def main() -> int:
    if os.environ.get("CHECK_IMAGE_PLATFORM", "false").lower() != "true":
        print("registered image verification skipped; CHECK_IMAGE_PLATFORM is not true")
        return 0
    try:
        registrations = sorted(REGISTRY_ROOT.glob("*/production.json"))
        if not registrations:
            raise RegistryError("application registry contains no production entries")
        base_ref = os.environ.get("BASE_REF", "")
        for path in registrations:
            registration = _load_json(path, f"registration {path}")
            validate_registration(registration)
            previous = _base_registration(base_ref, path)
            if previous is not None:
                validate_registration(previous)
            required_ancestor = (
                previous["migration"]["head"]
                if previous is not None
                else registration["migration"]["head"]
            )
            _verify_identity(registration["release"])
            _verify_identity(registration["migration"])
            _verify_migration(registration["migration"], required_ancestor)
    except (OSError, RegistryError) as error:
        print(f"registered image verification failed: {error}", file=sys.stderr)
        return 2
    print(f"registered images are valid: {len(registrations)} application(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
