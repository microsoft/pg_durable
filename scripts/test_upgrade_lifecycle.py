# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import upgrade_lifecycle as lifecycle


def case(waiting=False):
    return {
        "name": "test", "waiting": waiting,
        "status": "running" if waiting else "completed",
        "engine_status": "running" if waiting else "completed",
        "info_status": "running" if waiting else "completed",
        "listed": True, "subscribed": waiting,
        "result": None if waiting else '{"rows":[{"value":42}],"row_count":1}',
        "marks": [
            {"step": step, "value": 40 + step, "executed_by": lifecycle.ROLE}
            for step in range(1, 2 if waiting else 3)
        ],
    }


class ValidationTests(unittest.TestCase):
    def test_completed_and_waiting_instances(self):
        for waiting in (False, True):
            with self.subTest(waiting=waiting):
                self.assertEqual(lifecycle.case_problems(case(waiting), {}), [])

    def test_checks_every_status_surface(self):
        for field in ("status", "engine_status", "info_status"):
            value = case()
            value[field] = "failed"
            with self.subTest(field=field):
                self.assertTrue(lifecycle.case_problems(value, {}))

    def test_rejects_missing_monitoring_entry(self):
        value = case()
        value["listed"] = False
        self.assertIn("missing from df.list_instances", lifecycle.case_problems(value, {}))

    def test_requires_durable_subscription_before_upgrade(self):
        value = case(True)
        value["subscribed"] = False
        self.assertIn("signal subscription is not yet durable", lifecycle.case_problems(value, {}))

    def test_rejects_incorrect_side_effects(self):
        for change in ("duplicate", "missing", "order", "owner", "value"):
            value = case()
            if change == "duplicate":
                value["marks"].append(copy.deepcopy(value["marks"][0]))
            elif change == "missing":
                value["marks"].pop()
            elif change == "order":
                value["marks"].reverse()
            elif change == "owner":
                value["marks"][0]["executed_by"] = "postgres"
            else:
                value["marks"][0]["value"] = 999
            with self.subTest(change=change):
                self.assertTrue(lifecycle.case_problems(value, {}))

    def test_rejects_wrong_result_shape_and_values(self):
        for result in ({}, {"rows": [{"value": 41}], "row_count": 1},
                       {"rows": [{"value": 42}], "row_count": 2}):
            value = case()
            value["result"] = json.dumps(result)
            with self.subTest(result=result):
                self.assertTrue(lifecycle.case_problems(value, {}))

    def test_completed_results_remain_byte_identical(self):
        value = case()
        self.assertEqual(lifecycle.case_problems(value, {"test": value["result"]}), [])
        self.assertIn("previously completed result changed",
                      lifecycle.case_problems(value, {"test": "{}"}))

    def test_empty_fixture_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            cluster = lifecycle.Cluster(Path(directory), Path(directory), 1)
            cluster.state = Mock(return_value=[])
            with self.assertRaisesRegex(RuntimeError, "Expected"):
                cluster.validate(["required"], {})

    def test_failed_instance_is_not_retried_until_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            cluster = lifecycle.Cluster(Path(directory), Path(directory), 60)
            value = case()
            value["engine_status"] = "failed"
            cluster.state = Mock(return_value=[value])
            with self.assertRaisesRegex(RuntimeError, "Instance failed"):
                cluster.validate(["test"], {})
            cluster.state.assert_called_once()


class LifecycleTests(unittest.TestCase):
    @patch.object(lifecycle, "install")
    def test_phase_order_and_instance_cohorts(self, install):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cluster = Mock(prefix=output, schema="_duroxide")
            cluster.sql.return_value = "999"
            cluster.validate.return_value = []
            events = Mock()
            events.attach_mock(cluster, "cluster")
            events.attach_mock(install, "install")
            lifecycle.exercise(cluster, "0.2.8", "0.2.9", "old", "new", output)
            calls = events.mock_calls
            old_install = next(i for i, c in enumerate(calls) if c == unittest.mock.call.install("old", output))
            new_install = next(i for i, c in enumerate(calls) if c == unittest.mock.call.install("new", output))
            alter = next(i for i, c in enumerate(calls) if c == unittest.mock.call.cluster.sql(
                "ALTER EXTENSION pg_durable UPDATE TO '0.2.9';"))
            self.assertLess(old_install, new_install)
            self.assertLess(new_install, alter)
            self.assertEqual(cluster.versions.call_args_list, [
                unittest.mock.call("0.2.8", "0.2.8"),
                unittest.mock.call("0.2.8", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.9"),
                unittest.mock.call("0.2.9", "0.2.9"),
            ])
            self.assertEqual(cluster.start_cases.call_args_list, [
                unittest.mock.call("old", ["b1", "b2"]),
                unittest.mock.call("binary", ["b2"]),
                unittest.mock.call("schema", []),
            ])
            self.assertEqual(cluster.release.call_args_list, [
                unittest.mock.call("old-b1"), unittest.mock.call("old-b2"),
                unittest.mock.call("binary-b2"),
            ])
            self.assertEqual(cluster.stop.call_count, 2)
            self.assertEqual(len(list(output.glob("*.json"))), 5)

    @patch.object(lifecycle, "install")
    def test_failure_stops_cluster_and_does_not_advance(self, install):
        with tempfile.TemporaryDirectory() as directory:
            cluster = Mock(prefix=Path(directory), schema="_duroxide")
            cluster.sql.return_value = "999"
            cluster.validate.side_effect = RuntimeError("broken baseline")
            with self.assertRaisesRegex(RuntimeError, "broken baseline"):
                lifecycle.exercise(cluster, "0.2.8", "0.2.9", "old", "new", Path(directory))
            cluster.stop.assert_called_once()
            install.assert_called_once_with("old", cluster.prefix)
            cluster.release.assert_not_called()

    def test_install_rejects_unrelocated_postgres(self):
        with patch.object(lifecycle, "run", return_value="/shared/postgres/lib"):
            with self.assertRaisesRegex(RuntimeError, "did not relocate"):
                lifecycle.install(Path("/package"), Path("/private/postgres"))

    def test_build_rejects_lockfile_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            lock = source / "Cargo.lock"
            lock.write_text("original")
            def mutate(*args, **kwargs):
                lock.write_text("modified")
            with patch.object(subprocess, "run", side_effect=mutate):
                with self.assertRaisesRegex(RuntimeError, "changed the pinned lockfile"):
                    lifecycle.build(source, source / "output", Path("/pg_config"), "17")

    def test_build_explicitly_selects_release_manifest_and_pg_version(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "Cargo.lock").write_text("original")
            with patch.object(subprocess, "run") as run:
                lifecycle.build(source, source / "output", Path("/pg_config"), "18")
            for call in run.call_args_list:
                command = call.args[0]
                self.assertEqual(command[command.index("--manifest-path") + 1],
                                 str(source / "Cargo.toml"))
                self.assertEqual(command[command.index("--features") + 1], "pg18")
                self.assertNotEqual(call.kwargs["env"]["CARGO_TARGET_DIR"],
                                    str(lifecycle.PROJECT / "target"))


if __name__ == "__main__":
    unittest.main()
