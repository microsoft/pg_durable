#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Validate release eligibility and the exact ZIP sent to PGXN (Python 3.11+)."""

import argparse
import json
from pathlib import Path
import re
import sys
import tomllib
import zipfile


def release_version(tag):
    number = r"(0|[1-9][0-9]*)"
    if not re.fullmatch(rf"v{number}\.{number}\.{number}", tag):
        raise ValueError("PGXN requires a stable vX.Y.Z tag (no prerelease or build suffix)")
    return tag[1:]


def validate_release(tag, release, publish=False):
    release_version(tag)
    if release["tagName"] != tag:
        raise ValueError("GitHub release tag does not match the requested tag")
    if release["isPrerelease"] is not False:
        raise ValueError("GitHub prereleases cannot be published to PGXN")
    if publish and release["isDraft"] is not False:
        raise ValueError("Publish the draft GitHub Release before uploading to PGXN")


def validate_bundle(tag, source):
    version = release_version(tag)
    with (source / "Cargo.toml").open("rb") as manifest:
        if tomllib.load(manifest)["package"]["version"] != version:
            raise ValueError("Cargo.toml version does not match the release tag")

    prefix = f"pg_durable-{version}/"
    archive_path = source / f"pg_durable-{version}.zip"
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("PGXN archive contains duplicate entries")
        if any(
            not name.startswith(prefix) or ".." in name.split("/") or "\\" in name
            for name in names
        ):
            raise ValueError("PGXN archive must contain a single versioned root directory")
        metadata_bytes = archive.read(prefix + "META.json")
        if metadata_bytes != (source / "META.json").read_bytes():
            raise ValueError("Archived META.json differs from the validated metadata")
        metadata = json.loads(metadata_bytes)
        if metadata["name"] != "pg_durable" or metadata["version"] != version:
            raise ValueError("PGXN distribution name/version does not match the release")
        if metadata["release_status"] != "stable":
            raise ValueError("PGXN release_status must be stable")
        if set(metadata["provides"]) != {"pg_durable"}:
            raise ValueError("PGXN bundle must provide only the pg_durable extension")
        provided = metadata["provides"]["pg_durable"]
        if provided["version"] != version:
            raise ValueError("Provided extension version does not match the release")
        for name in (
            "Makefile", "Cargo.toml", "Cargo.lock", "pg_durable.control",
            "LICENSE.txt", "README.md", provided["file"], provided["docfile"],
        ):
            if prefix + name not in names or archive.getinfo(prefix + name).is_dir():
                raise ValueError(f"PGXN archive is missing required file: {name}")
        archived_manifest = tomllib.loads(archive.read(prefix + "Cargo.toml").decode())
        if archived_manifest["package"]["version"] != version:
            raise ValueError("Archived Cargo.toml version does not match the release")
        if archive.testzip() is not None:
            raise ValueError("PGXN archive has a corrupt entry")
    return archive_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tag").add_argument("tag")
    release = commands.add_parser("release")
    release.add_argument("tag")
    release.add_argument("metadata", type=Path)
    release.add_argument("--publish", action="store_true")
    bundle = commands.add_parser("bundle")
    bundle.add_argument("tag")
    bundle.add_argument("source", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "tag":
            print(release_version(args.tag))
        elif args.command == "release":
            validate_release(args.tag, json.loads(args.metadata.read_text()), args.publish)
        else:
            print(f"Validated {validate_bundle(args.tag, args.source)}")
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        print(f"PGXN validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
