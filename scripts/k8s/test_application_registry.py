#!/usr/bin/env python3
"""Regression tests for the generic application registry contract."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import call, patch

from update_application_release import (
    RegistryError,
    _load_json,
    main,
    update_migration_registration,
    update_registration,
    validate_candidate,
)
from validate_application_registry import (
    _validate_migration_sync_trigger,
    validate_history,
)
from verify_registered_images import _verify_migration

REGISTRATION_PATH = Path("k8s/registry/job-info-collector/production.json")


def candidate() -> dict[str, object]:
    revision = "a" * 40
    digest = f"sha256:{'b' * 64}"
    repository = "kunxie/job-info-collector"
    return {
        "schemaVersion": 1,
        "application": "job-info-collector",
        "sourceRepository": repository,
        "sourceRevision": revision,
        "sourceCreatedAt": "2026-07-20T00:00:00Z",
        "version": "0.8.0.dev0",
        "releaseKind": "development",
        "imageRepository": "ghcr.io/kunxie/job-info-collector",
        "imageDigest": digest,
        "image": f"ghcr.io/kunxie/job-info-collector@{digest}",
        "platform": "linux/arm64",
        "evidence": {
            "publicationRecordSha256": "c" * 64,
            "publicationRun": (f"https://github.com/{repository}/actions/runs/200"),
            "ciRun": f"https://github.com/{repository}/actions/runs/199",
        },
        "migration": {"kind": "alembic", "head": "0001_initial_schema"},
    }


class RegistryUpdaterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registration = _load_json(REGISTRATION_PATH, "test registration")

    def test_update_changes_only_source_revision_and_runtime_release(self) -> None:
        original_migration = copy.deepcopy(self.registration["migration"])

        updated, changed = update_registration(self.registration, candidate())

        self.assertTrue(changed)
        self.assertEqual(updated["source"]["revision"], "a" * 40)
        self.assertEqual(updated["release"]["sourceRevision"], "a" * 40)
        self.assertEqual(updated["release"]["imageDigest"], f"sha256:{'b' * 64}")
        self.assertEqual(updated["migration"], original_migration)

        repeated, repeated_changed = update_registration(updated, candidate())
        self.assertFalse(repeated_changed)
        self.assertEqual(repeated, updated)

    def test_candidate_cannot_cross_application_or_image_boundaries(self) -> None:
        wrong_application = candidate()
        wrong_application["application"] = "another-app"
        with self.assertRaisesRegex(RegistryError, "application does not match"):
            update_registration(self.registration, wrong_application)

        wrong_image = candidate()
        wrong_image["imageRepository"] = "ghcr.io/kunxie/another-app"
        wrong_image["image"] = (
            f"ghcr.io/kunxie/another-app@{wrong_image['imageDigest']}"
        )
        with self.assertRaisesRegex(RegistryError, "image repository"):
            update_registration(self.registration, wrong_image)

        with self.assertRaisesRegex(RegistryError, "image repository"):
            update_migration_registration(self.registration, wrong_image)

    def test_invalid_or_mutable_candidate_identity_is_rejected(self) -> None:
        invalid = candidate()
        invalid["imageDigest"] = "latest"
        invalid["image"] = "ghcr.io/kunxie/job-info-collector:latest"
        with self.assertRaisesRegex(RegistryError, "immutable sha256"):
            validate_candidate(invalid)

    def test_migration_history_is_monotonic_and_separate(self) -> None:
        previous = copy.deepcopy(self.registration)
        current = copy.deepcopy(previous)
        previous_source_time = datetime.strptime(
            previous["migration"]["sourceCreatedAt"], "%Y-%m-%dT%H:%M:%SZ"
        )
        current["migration"]["sourceRevision"] = "d" * 40
        current["migration"]["sourceCreatedAt"] = (
            previous_source_time + timedelta(seconds=1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        current["migration"]["imageDigest"] = f"sha256:{'e' * 64}"
        current["migration"]["image"] = (
            f"ghcr.io/kunxie/job-info-collector@{current['migration']['imageDigest']}"
        )
        current["migration"]["generation"] += 1

        validate_history(current, previous)

        current["migration"]["generation"] += 1
        with self.assertRaisesRegex(RegistryError, "increment generation exactly once"):
            validate_history(current, previous)

    def test_migration_update_changes_only_forward_migration_ledger(self) -> None:
        pending = candidate()
        pending["migration"] = {"kind": "alembic", "head": "0002_next"}
        original_source = copy.deepcopy(self.registration["source"])
        original_release = copy.deepcopy(self.registration["release"])
        original_generation = self.registration["migration"]["generation"]

        updated, changed = update_migration_registration(
            self.registration, pending
        )

        self.assertTrue(changed)
        self.assertEqual(updated["source"], original_source)
        self.assertEqual(updated["release"], original_release)
        self.assertEqual(updated["migration"]["head"], "0002_next")
        self.assertEqual(
            updated["migration"]["generation"], original_generation + 1
        )
        self.assertEqual(updated["migration"]["sourceRevision"], "a" * 40)
        self.assertEqual(
            updated["migration"]["imageDigest"], f"sha256:{'b' * 64}"
        )

        repeated, repeated_changed = update_migration_registration(updated, pending)
        self.assertFalse(repeated_changed)
        self.assertEqual(repeated, updated)

    def test_cli_defers_runtime_update_until_migration_is_registered(self) -> None:
        pending = candidate()
        pending["migration"] = {"kind": "alembic", "head": "0002_next"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registration_path = root / "production.json"
            candidate_path = root / "candidate.json"
            output_path = root / "output"
            original = f"{json.dumps(self.registration, indent=2)}\n"
            registration_path.write_text(original, encoding="utf-8")
            candidate_path.write_text(
                f"{json.dumps(pending, indent=2)}\n", encoding="utf-8"
            )

            status = main(
                [
                    "--registration",
                    str(registration_path),
                    "--candidate",
                    str(candidate_path),
                    "--github-output",
                    str(output_path),
                ]
            )

            self.assertEqual(status, 3)
            self.assertEqual(registration_path.read_text(encoding="utf-8"), original)
            self.assertEqual(
                output_path.read_text(encoding="utf-8"),
                "changed=false\nmigration_required=true\n",
            )

    def test_cli_writes_a_migration_only_registration(self) -> None:
        pending = candidate()
        pending["migration"] = {"kind": "alembic", "head": "0002_next"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            registration_path = root / "production.json"
            candidate_path = root / "candidate.json"
            output_path = root / "output"
            registration_path.write_text(
                f"{json.dumps(self.registration, indent=2)}\n", encoding="utf-8"
            )
            candidate_path.write_text(
                f"{json.dumps(pending, indent=2)}\n", encoding="utf-8"
            )

            status = main(
                [
                    "--registration",
                    str(registration_path),
                    "--candidate",
                    str(candidate_path),
                    "--component",
                    "migration",
                    "--github-output",
                    str(output_path),
                ]
            )

            self.assertEqual(status, 0)
            written = json.loads(registration_path.read_text(encoding="utf-8"))
            self.assertEqual(written["source"], self.registration["source"])
            self.assertEqual(written["release"], self.registration["release"])
            self.assertEqual(written["migration"]["head"], "0002_next")
            self.assertEqual(
                written["migration"]["generation"],
                self.registration["migration"]["generation"] + 1,
            )
            self.assertEqual(
                output_path.read_text(encoding="utf-8"),
                "changed=true\nmigration_required=false\n",
            )

    def test_image_gate_checks_the_previous_migration_head(self) -> None:
        identity = {
            "image": f"ghcr.io/kunxie/example@sha256:{'a' * 64}",
            "head": "0002_next",
        }

        with patch(
            "verify_registered_images._run", side_effect=["0002_next", ""]
        ) as run:
            _verify_migration(identity, "0001_initial")

        first, second = run.call_args_list
        self.assertEqual(first.args[0][-1], "schema-head")
        self.assertEqual(
            second,
            call(
                [
                    *first.args[0][:-1],
                    "schema-descends-from",
                    "0001_initial",
                ]
            ),
        )


class MigrationSyncTriggerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.application_set = Path(
            "k8s/argocd/applications/personal-applications.yaml"
        ).read_text(encoding="utf-8")

    def test_trigger_targets_only_persistent_network_policy_metadata(self) -> None:
        _validate_migration_sync_trigger(self.application_set)

    def test_common_annotations_are_rejected_to_avoid_runtime_restart(self) -> None:
        unsafe = self.application_set.replace(
            "          patches:\n",
            "          commonAnnotations:\n"
            '            platform.kunxie.dev/migration-generation: "2"\n'
            "          patches:\n",
            1,
        )

        with self.assertRaisesRegex(RegistryError, "must not annotate workload"):
            _validate_migration_sync_trigger(unsafe)

    def test_missing_default_deny_target_is_rejected(self) -> None:
        missing_target = self.application_set.replace(
            'name: "{{ .name }}-default-deny"',
            'name: "{{ .name }}-missing-trigger"',
        )

        with self.assertRaisesRegex(RegistryError, "persistent default-deny"):
            _validate_migration_sync_trigger(missing_target)


if __name__ == "__main__":
    unittest.main()
