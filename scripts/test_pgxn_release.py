#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

import json
from pathlib import Path
import tempfile
import unittest
import warnings
import zipfile

from pgxn_release import release_version, validate_bundle, validate_release


class ReleaseTests(unittest.TestCase):
    def test_stable_tags(self):
        for tag in ("v0.2.8", "v1.0.0", "v12.34.56"):
            self.assertEqual(release_version(tag), tag[1:])

    def test_reject_nonstable_tags(self):
        for tag in (
            "0.2.8", "v1.0", "v1.0.0-rc1", "v1.0.0+build", "v01.0.0",
            "v1.0.0\n", "v1.0.0/../../main", "main", "$(echo injected)",
        ):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag)

    def test_live_release_and_draft_dry_run(self):
        release = {"tagName": "v0.2.8", "isDraft": False, "isPrerelease": False}
        validate_release("v0.2.8", release, publish=True)
        release["isDraft"] = True
        validate_release("v0.2.8", release)
        with self.assertRaisesRegex(ValueError, "draft"):
            validate_release("v0.2.8", release, publish=True)

    def test_prerelease_flag_and_mismatched_release(self):
        for release in (
            {"tagName": "v0.2.8", "isDraft": False, "isPrerelease": True},
            {"tagName": "v0.2.7", "isDraft": False, "isPrerelease": False},
        ):
            for publish in (False, True):
                with self.subTest(release=release, publish=publish), self.assertRaises(ValueError):
                    validate_release("v0.2.8", release, publish)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        self.manifest = '[package]\nname = "pg_durable"\nversion = "0.2.8"\n'
        (self.source / "Cargo.toml").write_text(self.manifest)
        self.metadata = {
            "name": "pg_durable",
            "version": "0.2.8",
            "release_status": "stable",
            "provides": {
                "pg_durable": {
                    "version": "0.2.8",
                    "file": "src/lib.rs",
                    "docfile": "USER_GUIDE.md",
                }
            },
        }
        self.files = {
            name: "content"
            for name in (
                "Makefile", "Cargo.lock", "pg_durable.control", "LICENSE.txt",
                "README.md", "src/lib.rs", "USER_GUIDE.md",
            )
        }
        self.files["Cargo.toml"] = self.manifest

    def write_bundle(self, prefix="pg_durable-0.2.8/"):
        metadata = json.dumps(self.metadata)
        (self.source / "META.json").write_text(metadata)
        with zipfile.ZipFile(self.source / "pg_durable-0.2.8.zip", "w") as archive:
            archive.writestr(prefix + "META.json", metadata)
            for name, content in self.files.items():
                archive.writestr(prefix + name, content)

    def test_valid_bundle(self):
        self.write_bundle()
        self.assertEqual(
            validate_bundle("v0.2.8", self.source).name, "pg_durable-0.2.8.zip"
        )

    def test_metadata_constraints(self):
        for field, value in (
            ("name", "wrong"), ("version", "0.2.7"), ("release_status", "testing"),
            ("provides", {"another_extension": {}}),
            ("provides", {"pg_durable": {"version": "0.2.7"}}),
        ):
            with self.subTest(field=field):
                original = self.metadata[field]
                self.metadata[field] = value
                self.write_bundle()
                with self.assertRaises(ValueError):
                    validate_bundle("v0.2.8", self.source)
                self.metadata[field] = original

    def test_missing_documentation(self):
        del self.files["USER_GUIDE.md"]
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "missing required file"):
            validate_bundle("v0.2.8", self.source)

    def test_wrong_root_or_unsafe_entry(self):
        self.write_bundle(prefix="")
        with self.assertRaisesRegex(ValueError, "root directory"):
            validate_bundle("v0.2.8", self.source)
        self.files["../outside"] = "content"
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "root directory"):
            validate_bundle("v0.2.8", self.source)

    def test_generated_metadata_must_be_in_archive(self):
        self.write_bundle()
        (self.source / "META.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "differs"):
            validate_bundle("v0.2.8", self.source)

    def test_missing_generated_metadata(self):
        (self.source / "META.json").write_text(json.dumps(self.metadata))
        with zipfile.ZipFile(self.source / "pg_durable-0.2.8.zip", "w") as archive:
            for name, content in self.files.items():
                archive.writestr("pg_durable-0.2.8/" + name, content)
        with self.assertRaises(KeyError):
            validate_bundle("v0.2.8", self.source)

    def test_duplicate_metadata(self):
        self.write_bundle()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.source / "pg_durable-0.2.8.zip", "a") as archive:
                archive.writestr("pg_durable-0.2.8/META.json", "{}")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validate_bundle("v0.2.8", self.source)

    def test_source_and_archived_versions(self):
        self.write_bundle()
        (self.source / "Cargo.toml").write_text(self.manifest.replace("0.2.8", "0.2.7"))
        with self.assertRaisesRegex(ValueError, "Cargo.toml version"):
            validate_bundle("v0.2.8", self.source)
        (self.source / "Cargo.toml").write_text(self.manifest)
        self.files["Cargo.toml"] = self.manifest.replace("0.2.8", "0.2.7")
        self.write_bundle()
        with self.assertRaisesRegex(ValueError, "Archived Cargo.toml"):
            validate_bundle("v0.2.8", self.source)


if __name__ == "__main__":
    unittest.main()
