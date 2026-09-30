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


def case(shape="seq", waiting=False):
    spec = lifecycle.SHAPES[shape]
    counts = spec["before"] if waiting else spec["after"]
    captured = {} if waiting else spec.get("captured", {})
    values = spec.get("before_values" if waiting else "after_values", {})
    marks = []
    for path, count in sorted(counts.items()):
        for occurrence in range(1, count + 1):
            marks.append({"path": path, "occurrence": occurrence,
                          "value": values[path][occurrence - 1] if path in values else captured.get(path),
                          "executed_by": lifecycle.ROLE})
    if waiting:
        result = None
    elif spec.get("result") is not None:
        result = json.dumps(spec["result"])
    else:
        result = '{"rows":[{"value":null}],"row_count":1}'
    return {
        "name": "test", "shape": shape, "waiting": waiting,
        "status": "running" if waiting else "completed",
        "engine_status": "running" if waiting else "completed",
        "info_status": "running" if waiting else "completed",
        "listed": True, "subscribed": waiting,
        "result": result,
        "marks": marks,
        "race_loser_id": "test::1::loser" if shape == "race" else None,
        "race_loser_status": "running" if waiting else "failed",
        "race_loser_timer_created": shape == "race",
        "race_loser_cancelled": shape == "race" and not waiting,
    }


class ValidationTests(unittest.TestCase):
    def test_every_shape_passes_before_and_after(self):
        for shape in lifecycle.FAMILIES:
            for waiting in (True, False):
                with self.subTest(shape=shape, waiting=waiting):
                    self.assertEqual(lifecycle.case_problems(case(shape, waiting), {}), [])

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
        for shape in lifecycle.FAMILIES:
            value = case(shape, waiting=True)
            value["subscribed"] = False
            with self.subTest(shape=shape):
                self.assertIn("signal subscription is not yet durable",
                              lifecycle.case_problems(value, {}))

    def test_rejects_missing_duplicate_or_misowned_markers(self):
        def mutate(value, change):
            if change == "duplicate":
                value["marks"].append(copy.deepcopy(value["marks"][0]))
            elif change == "missing":
                value["marks"].pop()
            elif change == "owner":
                value["marks"][0]["executed_by"] = "postgres"
        for change in ("duplicate", "missing", "owner"):
            value = case("loop")
            mutate(value, change)
            with self.subTest(change=change):
                self.assertTrue(lifecycle.case_problems(value, {}))

    def test_rejects_captured_value_drift(self):
        value = case("seq")
        next(m for m in value["marks"] if m["path"] == "r.1")["value"] = 999
        self.assertTrue(any("captured value" in problem
                            for problem in lifecycle.case_problems(value, {})))

    def test_sequence_requires_seed_value_before_and_after_resume(self):
        for waiting in (True, False):
            for seed in (None, 40, 999):
                value = case("seq", waiting=waiting)
                value["marks"][0]["value"] = seed
                with self.subTest(waiting=waiting, seed=seed):
                    self.assertIn("incorrect marker values at r.0",
                                  "; ".join(lifecycle.case_problems(value, {})))

    def test_break_requires_logical_iterations_not_just_three_effects(self):
        for iterations in ([1, 1, 2], [1, 2, 2], [1, 3, 2], [2, 3, 4]):
            value = case("break")
            for mark, iteration in zip(value["marks"], iterations):
                mark["value"] = iteration
            with self.subTest(iterations=iterations):
                self.assertIn("incorrect marker values at r.0",
                              "; ".join(lifecycle.case_problems(value, {})))

    def test_break_requires_first_iteration_before_resume(self):
        value = case("break", waiting=True)
        value["marks"][0]["value"] = 2
        self.assertIn("incorrect marker values at r.0",
                      "; ".join(lifecycle.case_problems(value, {})))

    def test_race_requires_exact_loser_and_durable_timer(self):
        for waiting in (True, False):
            for field, invalid in (("race_loser_id", None), ("race_loser_timer_created", False)):
                value = case("race", waiting=waiting)
                value[field] = invalid
                with self.subTest(waiting=waiting, field=field):
                    self.assertTrue(lifecycle.case_problems(value, {}))

    def test_race_requires_running_loser_before_resume(self):
        for status, cancelled in (("failed", True), ("completed", False), ("running", True)):
            value = case("race", waiting=True)
            value.update(race_loser_status=status, race_loser_cancelled=cancelled)
            with self.subTest(status=status, cancelled=cancelled):
                self.assertIn("race loser must still be running before resume",
                              lifecycle.case_problems(value, {}))

    def test_race_requires_terminal_cancellation_not_merely_no_loser_marks(self):
        for status, cancelled in (("running", False), ("running", True),
                                  ("failed", False), ("completed", False), (None, False)):
            value = case("race")
            value.update(race_loser_status=status, race_loser_cancelled=cancelled)
            with self.subTest(status=status, cancelled=cancelled):
                self.assertIn("race loser cancellation is not yet terminal",
                              lifecycle.case_problems(value, {}))

    def test_validate_waits_for_race_loser_cancellation(self):
        with tempfile.TemporaryDirectory() as directory:
            cluster = lifecycle.Cluster(Path(directory), Path(directory), 1)
            pending = case("race")
            pending.update(race_loser_status="running", race_loser_cancelled=False)
            terminal = case("race")
            cluster.state = Mock(side_effect=[[pending], [terminal]])
            completed = {}
            with patch.object(lifecycle.time, "sleep"):
                self.assertEqual(cluster.validate(["test"], completed), [terminal])
            self.assertEqual(cluster.state.call_count, 2)
            self.assertEqual(completed, {"test": terminal["result"]})

    def test_rejects_unexpected_branch_or_loser_markers(self):
        for shape, stray in (("if-then", "r.e"), ("if-else", "r.t"), ("race", "r.l")):
            value = case(shape)
            value["marks"].append({"path": stray, "occurrence": 1, "value": None,
                                   "executed_by": lifecycle.ROLE})
            with self.subTest(shape=shape, stray=stray):
                self.assertTrue(any("incorrect marker counts" in problem
                                    for problem in lifecycle.case_problems(value, {})))

    def test_waiting_case_must_not_run_post_suspension_markers(self):
        # A join whose suspended branch leaked its continuation before resume.
        value = case("join", waiting=True)
        value["marks"].append({"path": "r.1", "occurrence": 1, "value": None,
                               "executed_by": lifecycle.ROLE})
        self.assertTrue(any("incorrect marker counts" in problem
                            for problem in lifecycle.case_problems(value, {})))

    def test_rejects_wrong_result_shape_and_values(self):
        for result in ({}, {"rows": [{"value": 41}], "row_count": 1},
                       {"rows": [{"value": 42}], "row_count": 2}):
            value = case("seq")
            value["result"] = json.dumps(result)
            with self.subTest(result=result):
                self.assertTrue(lifecycle.case_problems(value, {}))

    def test_completed_results_remain_byte_identical(self):
        value = case("seq")
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
    def test_start_sequence_captures_variables_then_changes_live_values(self):
        for waiting in (True, False):
            with tempfile.TemporaryDirectory() as directory, self.subTest(waiting=waiting):
                cluster = lifecycle.Cluster(Path(directory), Path(directory), 1)
                cluster.set_vars = Mock()
                cluster.start_case = Mock()
                events = Mock()
                events.attach_mock(cluster.set_vars, "set_vars")
                events.attach_mock(cluster.start_case, "start_case")
                cluster.start_sequence("seq-test", waiting=waiting)
                self.assertEqual(events.mock_calls, [
                    unittest.mock.call.set_vars(41, 1),
                    unittest.mock.call.start_case("seq-test", "seq", waiting),
                    unittest.mock.call.set_vars(999, 999),
                ])

    @patch.object(lifecycle, "install")
    def test_phase_order_and_instance_cohorts(self, install):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cluster = Mock(prefix=output, schema="_duroxide")
            cluster.sql.return_value = "999"
            cohorts = []
            def validate(names, completed):
                cohorts.append(set(names))
                return []
            cluster.validate.side_effect = validate
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
            binary_wait_start = calls.index(unittest.mock.call.cluster.start_sequence(
                "seq-binary-b2", waiting=True))
            binary_wait_release = calls.index(unittest.mock.call.cluster.release("seq-binary-b2"))
            validations = [i for i, call in enumerate(calls) if call[0] == "cluster.validate"]
            self.assertLess(new_install, binary_wait_start)
            self.assertLess(binary_wait_start, validations[2])
            self.assertLess(validations[2], alter)
            self.assertLess(alter, validations[3])
            self.assertLess(validations[3], binary_wait_release)
            self.assertLess(binary_wait_release, validations[4])
            baseline = {f"{family}-{boundary}" for family in lifecycle.FAMILIES
                        for boundary in ("b1", "b2")} | {"seq-done-baseline"}
            binary = baseline | {"seq-done-b1", "seq-binary-b2"}
            self.assertEqual(cohorts, [
                baseline, baseline, binary, binary, binary | {"seq-done-b2"},
            ])
            self.assertEqual(cluster.versions.call_args_list, [
                unittest.mock.call("0.2.8", "0.2.8"),
                unittest.mock.call("0.2.8", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.8"),
                unittest.mock.call("0.2.9", "0.2.9"),
                unittest.mock.call("0.2.9", "0.2.9"),
            ])
            self.assertEqual(cluster.seed_families.call_count, 1)
            self.assertEqual(cluster.start_sequence.call_args_list, [
                unittest.mock.call("seq-done-baseline"),
                unittest.mock.call("seq-done-b1"),
                unittest.mock.call("seq-binary-b2", waiting=True),
                unittest.mock.call("seq-done-b2"),
            ])
            self.assertEqual(cluster.release.call_args_list,
                [unittest.mock.call(f"{family}-b1") for family in lifecycle.FAMILIES]
                + [unittest.mock.call(f"{family}-b2") for family in lifecycle.FAMILIES]
                + [unittest.mock.call("seq-binary-b2")])
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
