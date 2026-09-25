#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Exercise the Docker E2E runner without Docker, PostgreSQL or network access."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK_DOCKER = r'''
import json, os, sys
args = sys.argv[1:]
with open(os.environ["DOCKER_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[0] == "exec" and "pg_isready" in args:
    sys.exit(1 if os.environ.get("NOT_READY") else 0)
if args[0] == "cp" and os.environ.get("COPY_FAIL") and args[1].endswith(".sql"):
    print("copy failed", file=sys.stderr)
    sys.exit(1)
if args[0] == "exec" and "-f" in args:
    name = args[args.index("-f") + 1]
    if "00_failure" in name:
        print(os.environ.get("FAILURE_OUTPUT", "psql: connection lost"))
        sys.exit(int(os.environ.get("FAILURE_CODE", "3")))
    print("TEST PASSED")
elif args[0] == "exec" and "-c" in args and "df.version()" in args[-1]:
    if os.environ.get("VERSION_FAIL"):
        print("version lookup failed", file=sys.stderr)
        sys.exit(3)
    print("0.2.9")
'''


class DockerRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.sql = self.root / "tests" / "e2e" / "sql"
        self.sql.mkdir(parents=True)
        self.runner = self.root / "scripts" / "test-e2e-docker.sh"
        shutil.copyfile(ROOT / "scripts" / "test-e2e-docker.sh", self.runner)
        binaries = self.root / "bin"
        binaries.mkdir()
        docker = binaries / "docker"
        docker.write_text(f"#!{sys.executable}\n{MOCK_DOCKER}", encoding="utf-8")
        docker.chmod(0o755)
        sleep = binaries / "sleep"
        sleep.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
        sleep.chmod(0o755)
        self.calls = self.root / "docker-calls.jsonl"
        self.env = {
            **os.environ,
            "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
            "DOCKER_CALLS": str(self.calls),
            "PG_DURABLE_LOG_DIR": str(self.root / "logs"),
        }
        for key in ("NOT_READY", "COPY_FAIL", "VERSION_FAIL", "FAILURE_OUTPUT", "FAILURE_CODE",
                    "PG_DURABLE_TEST_CONTAINER", "PG_DURABLE_TEST_IMAGE"):
            self.env.pop(key, None)

    def run_runner(self, names, **environment):
        for name in names:
            (self.sql / f"{name}.sql").write_text("SELECT 1;\n", encoding="ascii")
        result = subprocess.run(
            ["bash", str(self.runner)],
            env={**self.env, **environment},
            text=True,
            capture_output=True,
            timeout=30,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        tests = [args[args.index("-f") + 1] for args in calls if args[0] == "exec" and "-f" in args]
        return result, calls, tests

    def test_fixed_image_skips_every_local_special_phase(self):
        local = (ROOT / "scripts" / "test-e2e-local.sh").read_text()
        # Read only the phase classifier without running its server-management code.
        classifier = local.split("phase_for_test() {", 1)[1].split("\n}\n", 1)[0]
        names = sorted(path.stem for path in (ROOT / "tests" / "e2e" / "sql").glob("*.sql"))
        phases = subprocess.run(
            ["bash", "-c", 'NO_PRELOAD_TEST=00_requires_shared_preload\nphase_for_test() {'
             + classifier + '\n}\nfor name in "$@"; do phase_for_test "$name"; done', "phases", *names],
            text=True, capture_output=True, check=True,
        ).stdout.splitlines()
        self.assertEqual(len(phases), len(names))
        expected = [f"/tests/{name}.sql" for name, phase in zip(names, phases) if phase == "standard"]
        result, _, actual = self.run_runner(names)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(actual, expected)
        self.assertIn("/tests/75_multi_database_lifecycle.sql", actual)
        self.assertIn("/tests/77_multi_database_guards.sql", actual)
        self.assertIn("/tests/81_multi_database_autocommit.sql", actual)

    def test_sql_failure_is_reported_and_next_test_runs(self):
        result, calls, tests = self.run_runner(["00_failure", "01_success"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("psql: connection lost", result.stdout)
        self.assertIn("1 failed", result.stdout)
        self.assertIn("/tests/01_success.sql", tests)
        self.assertTrue(any(args[0] == "logs" for args in calls))
        self.assertEqual(calls[-1], ["rm", "-f", "pg_durable_e2e"])

    def test_failure_marker_wins_over_pass_marker(self):
        result, _, _ = self.run_runner(
            ["00_failure"], FAILURE_CODE="0", FAILURE_OUTPUT="TEST PASSED\nTEST FAILED: assertion"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("TEST FAILED: assertion", result.stdout)
        self.assertIn("1 failed", result.stdout)

    def test_readiness_timeout_does_not_run_tests(self):
        result, calls, tests = self.run_runner(["01_success"], NOT_READY="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("TIMEOUT", result.stdout)
        self.assertEqual(tests, [])
        self.assertFalse(any("-c" in args for args in calls))

    def test_success_exit_without_completion_marker_fails(self):
        for output in ("", "CREATE TABLE\nDO\n"):
            with self.subTest(output=output):
                result, _, _ = self.run_runner(
                    ["00_failure"], FAILURE_CODE="0", FAILURE_OUTPUT=output
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("Missing TEST PASSED marker", result.stdout)
                self.assertIn("1 failed", result.stdout)

    def test_copy_failure_does_not_run_missing_tests(self):
        result, _, tests = self.run_runner(["01_success"], COPY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy failed", result.stderr)
        self.assertEqual(tests, [])

    def test_version_failure_is_reported_before_tests(self):
        result, _, tests = self.run_runner(["01_success"], VERSION_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("version lookup failed", result.stdout)
        self.assertIn("Failed to get version", result.stdout)
        self.assertEqual(tests, [])

    def test_isolated_container_and_image_overrides(self):
        result, calls, _ = self.run_runner(
            ["01_success"],
            PG_DURABLE_TEST_CONTAINER="isolated-e2e",
            PG_DURABLE_TEST_IMAGE="isolated-image:test",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = next(args for args in calls if args[0] == "run")
        self.assertEqual(run[run.index("--name") + 1], "isolated-e2e")
        self.assertEqual(run[-1], "isolated-image:test")
        self.assertEqual(calls[-1], ["rm", "-f", "isolated-e2e"])


if __name__ == "__main__":
    unittest.main()
