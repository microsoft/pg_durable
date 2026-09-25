import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from upgrade_replay import check_finite, check_live_progress, exercise_chain, exit_status, install_package, known_break, main, phases, record_failure, require_version, sql_literal
from upgrade_replay import Cluster, permission_changes, sequence_expression, sequence_shape, known_sequence_break, permission_outcome, operation_outcome, check_sequences, PERMISSION_ROLES, MULTIPART, ENDPOINT_FUNCTIONS


class SequenceTests(unittest.TestCase):
    def test_exception_rejects_other_boundaries_and_corrupt_side_effects(self):
        case = {"name": "00-0.2.2-phase1-replay_never_user-held", "owner_role": "replay_never_user",
                "engine_status": "failed", "df_status": "running",
                "engine_output": 'nondeterministic: schedule mismatch: name: "pg_durable::activity::update-node-status"'}
        case["marks"] = [{"label": case["name"], "step": step, "executed_by": case["owner_role"], "value": step * (step + 1) // 2} for step in range(1, 7)]
        problems = ["incorrect ordered side effects: expected 13, got 6", "expected completed, engine=failed, df=running", "incorrect sequence result"]
        self.assertTrue(known_sequence_break(case, "01-0.2.5-phase2", problems))
        self.assertFalse(known_sequence_break(case, "02-0.2.5-phase1", problems))
        self.assertFalse(known_sequence_break(case, "01-0.2.5-phase2", problems + ["persisted graph changed"]))
        self.assertFalse(known_sequence_break(dict(case, engine_output="connection lost"), "01-0.2.5-phase2", problems))
        case["marks"][0]["value"] = 100
        self.assertFalse(known_sequence_break(case, "01-0.2.5-phase2", problems))

    def test_prior_failure_does_not_hide_new_graph_damage(self):
        case = {"name": "broken", "instance_id": "id", "owner_role": "owner", "allowed_step": 13,
                "engine_status": "failed", "df_status": "running", "result": None}
        cluster = Mock()
        cluster.rows.side_effect = [[case], []]
        cluster.probe.return_value = {"ok": True, "output": "25"}
        with tempfile.TemporaryDirectory() as directory, patch("upgrade_replay.sequence_graph", return_value={"root_node": "missing", "nodes": []}):
            outcomes = check_sequences(cluster, "duroxide", "later", 1, {}, {"broken": {"phase": "first"}}, Path(directory))
        self.assertEqual(outcomes[0]["outcome"], "failure")
        self.assertIn("missing or repeated graph node", outcomes[0]["problems"])

    def graph(self):
        nodes = [{"id": "sql1", "node_type": "SQL", "left_node": None, "right_node": None}]
        root = "sql1"
        for step in range(2, 14):
            nodes.append({"id": f"sql{step}", "node_type": "SQL", "left_node": None, "right_node": None})
            nodes.append({"id": f"then{step}", "node_type": "THEN", "left_node": root, "right_node": f"sql{step}"})
            root = f"then{step}"
        return {"root_node": root, "nodes": nodes}

    def test_left_deep_shape_and_expression(self):
        self.assertEqual(sequence_shape(self.graph()), {"nodes": 25, "depth": 12, "sql_leaves": 13})
        self.assertEqual(sequence_expression().count(" ~> "), 12)
        self.assertEqual(sequence_expression().count("replay_sequence_step"), 13)

    def test_invalid_topologies_are_rejected(self):
        for mutation in ("missing", "cycle", "extra", "wrong_type"):
            with self.subTest(mutation=mutation):
                graph = self.graph()
                if mutation == "missing":
                    graph["nodes"].pop(0)
                elif mutation == "cycle":
                    graph["nodes"][-1]["left_node"] = graph["root_node"]
                elif mutation == "extra":
                    graph["nodes"].append(dict(graph["nodes"][0], id="orphan"))
                else:
                    graph["nodes"][0]["node_type"] = "SLEEP"
                with self.assertRaises(ValueError):
                    sequence_shape(graph)


class PermissionTests(unittest.TestCase):
    def test_distinguishes_lost_access_from_new_ungranted_functions(self):
        before = [{"signature": "existing()", "execute": True}, {"signature": "private()", "execute": False}]
        after = [{"signature": "existing()", "execute": False}, {"signature": "private()", "execute": False},
                 {"signature": "new()", "execute": False}, {"signature": "public()", "execute": True}]
        self.assertEqual(permission_changes(before, after), [
            {"signature": "existing()", "execute": False, "change": "lost"},
            {"signature": "new()", "execute": False, "change": "new_ungranted"},
        ])

    def test_sql_connects_as_the_role_without_superuser_session(self):
        cluster = Cluster(Path("/private"), Path("/data"))
        with patch("upgrade_replay.subprocess.run", return_value=Mock(stdout="ok")) as execute:
            self.assertEqual(cluster.sql("SELECT current_user", role='test"role'), "ok")
        self.assertEqual(execute.call_args.kwargs["input"], "SELECT current_user")
        self.assertIn('test"role', execute.call_args.args[0])
        self.assertNotIn("postgres", execute.call_args.args[0][execute.call_args.args[0].index("-U") + 1:execute.call_args.args[0].index("-d")])

    def test_admin_refresh_does_not_imply_user_refresh(self):
        snapshot = {"name": "04-0.2.7-phase1", "extension_version": "0.2.7"}
        value = {"missing": [MULTIPART], "missing_grantable": [], "changes": []}
        self.assertEqual(permission_outcome(snapshot, "replay_managed_user", value), "known_break")
        self.assertEqual(permission_outcome(snapshot, "replay_regranted_user", value), "failure")
        self.assertEqual(permission_outcome(snapshot, "replay_managed_admin", dict(value, missing_grantable=[MULTIPART])), "failure")
        self.assertEqual(permission_outcome(snapshot, "replay_never_user", dict(value, changes=[{"change": "lost"}])), "failure")

    def test_endpoint_refresh_is_exact_and_delegation_errors_are_not_blanket_ignored(self):
        snapshot = {"name": "catalog-0.2.9-before-refresh", "extension_version": "0.2.9"}
        value = {"missing": list(ENDPOINT_FUNCTIONS), "missing_grantable": list(ENDPOINT_FUNCTIONS), "changes": []}
        self.assertEqual(permission_outcome(snapshot, "replay_managed_admin", value), "known_break")
        snapshot["name"] = "06-0.2.9-phase1"
        result = {"ok": False, "error": "ERROR:  permission denied for function http\n", "missing": ["df.http(text,text,text,jsonb,integer)", MULTIPART, *ENDPOINT_FUNCTIONS]}
        self.assertEqual(operation_outcome(snapshot, "replay_never_admin", "delegate", result), "known_break")
        self.assertEqual(operation_outcome(snapshot, "replay_managed_admin", "delegate", result), "failure")
        self.assertEqual(operation_outcome(snapshot, "replay_never_admin", "delegate", dict(result, error="connection lost")), "failure")


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.prefix = root / "postgres"
        self.library_dir = self.prefix / "lib"
        self.extension_dir = self.prefix / "share" / "extension"
        self.library_dir.mkdir(parents=True)
        self.extension_dir.mkdir(parents=True)
        self.package = root / "package"
        self.package.mkdir()
        (self.package / "pg_durable.so").write_bytes(b"candidate")
        (self.package / "pg_durable.control").write_text("default_version = '0.2.9'")
        (self.package / "pg_durable--0.2.8--0.2.9.sql").write_text("SELECT 1;")

    def test_install_retains_old_sql_and_replaces_binary(self):
        old_sql = self.extension_dir / "pg_durable--0.2.2.sql"
        old_sql.write_text("old fixture")
        (self.library_dir / "pg_durable.so").write_bytes(b"old")
        with patch("upgrade_replay.run", side_effect=[str(self.library_dir), str(self.extension_dir.parent)]):
            install_package(self.package, self.prefix)
        self.assertEqual((self.library_dir / "pg_durable.so").read_bytes(), b"candidate")
        self.assertEqual(old_sql.read_text(), "old fixture")
        self.assertTrue((self.extension_dir / "pg_durable--0.2.8--0.2.9.sql").exists())

    def test_refuses_nonisolated_installation(self):
        with patch("upgrade_replay.run", side_effect=["/usr/lib/postgresql", "/usr/share/postgresql"]):
            with self.assertRaisesRegex(RuntimeError, "did not relocate"):
                install_package(self.package, self.prefix)

    def test_rejects_missing_library(self):
        (self.package / "pg_durable.so").unlink()
        with patch("upgrade_replay.run", side_effect=[str(self.library_dir), str(self.extension_dir.parent)]):
            with self.assertRaisesRegex(RuntimeError, "Incomplete"):
                install_package(self.package, self.prefix)

    def test_version_check_does_not_accept_wrong_schema(self):
        require_version("0.2.2", "0.2.2")
        with self.assertRaisesRegex(RuntimeError, "Expected extension"):
            require_version("0.2.9", "0.2.2")


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.case = {"name": "finite", "engine_status": "completed", "df_status": "completed", "result": '{"rows":[{"value":"done"}],"row_count":1}'}

    def test_matching_completion(self):
        self.assertEqual(check_finite(self.case, 1), [])

    def test_engine_failure_is_not_hidden_by_df_mirror(self):
        case = dict(self.case, engine_status="failed", df_status="running")
        self.assertTrue(check_finite(case, 1))

    def test_repeated_successful_activity_is_rejected(self):
        self.assertTrue(check_finite(self.case, 2))

    def test_wrong_result_is_rejected(self):
        case = dict(self.case, result="wrong")
        self.assertTrue(check_finite(case, 1))

    def test_completed_result_is_unchanged(self):
        self.assertEqual(check_finite(self.case, 1, self.case["result"]), [])
        self.assertIn("completed result changed", check_finite(self.case, 1, "previous"))

    def test_first_failure_is_preserved(self):
        failures = {}
        record_failure(failures, "live", "first", ["replay mismatch"])
        record_failure(failures, "live", "later", ["still failed"])
        self.assertEqual(failures["live"]["phase"], "first")

    def test_chain_alternates_b1_b2(self):
        steps = list(phases())
        self.assertEqual([step["scenario"] for step in steps], ["baseline", "B1", "B2", "B1", "B2", "B1", "B2"])
        self.assertEqual([(step["binary"], step["schema"]) for step in steps], [
            ("0.2.2", "0.2.2"), ("0.2.5", "0.2.2"), ("0.2.5", "0.2.5"),
            ("0.2.7", "0.2.5"), ("0.2.7", "0.2.7"), ("0.2.9", "0.2.7"), ("0.2.9", "0.2.9"),
        ])

    def test_signal_names_are_quoted(self):
        self.assertEqual(sql_literal("an'event"), "'an''event'")


class LiveProgressTests(unittest.TestCase):
    def setUp(self):
        self.case = {"engine_status": "running", "df_status": "running"}

    def test_any_positive_progress_passes(self):
        for previous, current in ((0, 1), (3, 4), (3, 17), (100, 107)):
            with self.subTest(previous=previous, current=current):
                self.assertEqual(check_live_progress(self.case, previous, current), [])

    def test_stalled_or_regressed_counter_fails(self):
        for current in (2, 3):
            self.assertTrue(check_live_progress(self.case, 3, current))

    def test_progress_does_not_hide_engine_failure(self):
        self.assertTrue(check_live_progress(dict(self.case, engine_status="failed"), 3, 4))


class OutcomeTests(unittest.TestCase):
    def test_expanded_results_and_missing_coverage_affect_exit_status(self):
        report = {"errors": [], "permissions": [], "outcomes": []}
        for index, phase in enumerate(phases()):
            report["outcomes"].append({"cases": [{"outcome": "passed"}],
                                       "sequences": [{"outcome": "passed"} for count in range(4 * (index + 1))],
                                       "resumed_sequences": [{"outcome": "passed"} for count in range(4 * index + 2)]})
            report["permissions"].append({"roles": {role: {"outcome": "passed"} for role in PERMISSION_ROLES},
                                          "operations": {role: {"start": {"outcome": "passed"}} for role in PERMISSION_ROLES}})
        self.assertEqual(exit_status(report), 0)
        report["outcomes"][1]["resumed_sequences"][0]["outcome"] = "known_break"
        self.assertEqual(exit_status(report), 1)
        self.assertEqual(exit_status(report, True), 0)
        report["permissions"][0]["operations"][PERMISSION_ROLES[0]]["start"]["outcome"] = "failure"
        self.assertEqual(exit_status(report, True), 1)
        report["outcomes"][0]["sequences"].pop()
        self.assertEqual(exit_status(report, True), 2)

    def test_only_documented_transition_and_error_are_known(self):
        case = {"name": "00-0.2.2-phase1-live", "engine_status": "failed", "df_status": "running",
                "engine_output": 'nondeterministic: schedule mismatch: name: "pg_durable::activity::update-node-status"'}
        problems = check_live_progress(case, 3, 3)
        self.assertTrue(known_break(case, "01-0.2.5-phase2", problems))
        self.assertFalse(known_break(case, "02-0.2.5-phase1", problems))
        self.assertFalse(known_break(dict(case, engine_output="connection lost"), "01-0.2.5-phase2", problems))
        self.assertFalse(known_break(case, "01-0.2.5-phase2", problems + ["inspection failed"]))
        self.assertFalse(known_break(dict(case, name="01-0.2.5-phase2-live"), "01-0.2.5-phase2", problems))

    def test_exit_status_does_not_hide_missing_coverage_or_unexpected_failures(self):
        report = {"errors": [], "outcomes": [{"cases": [{"outcome": "passed"}]} for phase in phases()]}
        self.assertEqual(exit_status(report), 0)
        report["outcomes"][1]["cases"][0]["outcome"] = "known_break"
        self.assertEqual(exit_status(report), 1)
        self.assertEqual(exit_status(report, allow_known_breaks=True), 0)
        report["outcomes"][2]["cases"][0]["outcome"] = "failure"
        self.assertEqual(exit_status(report, allow_known_breaks=True), 1)
        report["outcomes"].pop()
        self.assertEqual(exit_status(report, allow_known_breaks=True), 2)
        report["errors"].append({"error": "setup failed"})
        self.assertEqual(exit_status(report), 2)


class FailureHandlingTests(unittest.TestCase):
    def test_setup_errors_and_timeout_bytes_produce_json_report(self):
        for error, expected in (
            (FileNotFoundError("missing pg_config"), "missing pg_config"),
            (subprocess.TimeoutExpired("psql", 30, stderr=b"connection timed out\xff"), "connection timed out"),
        ):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                arguments = ["upgrade_replay.py", "--pg-config", "/missing/pg_config", "--output-dir", directory]
                with patch.object(sys, "argv", arguments), patch("upgrade_replay.run", side_effect=error):
                    self.assertEqual(main(), 2)
                report = json.loads((Path(directory) / "report.json").read_text())
                self.assertEqual(report["exit_status"], 2)
                self.assertIn(expected, report["errors"][0]["error"])

    def test_fixture_failure_collects_diagnostics_and_stops_cluster(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "postmaster.pid").touch()
            cluster = Mock(data=root)
            cluster.ready.return_value = "duroxide"
            cluster.sql.side_effect = ["", "", "0.2.2", RuntimeError("fixture failed")]
            with patch("upgrade_replay.Cluster", return_value=cluster), patch("upgrade_replay.install_package"), patch("upgrade_replay.setup_permission_roles"), patch("upgrade_replay.permission_snapshot", return_value={}), patch("upgrade_replay.check_role_operations"):
                with self.assertRaisesRegex(RuntimeError, "fixture failed"):
                    exercise_chain(root, root, root, 45, 3, {"errors": []}, root / "report.json")
            cluster.diagnostics.assert_called_once_with("duroxide", root / "00-0.2.2-phase1")
            self.assertEqual(cluster.stop.call_count, 2)

    def test_invalid_shell_options_fail_before_starting_tests(self):
        script = Path(__file__).with_name("test-upgrade.sh")
        for arguments in (
            ["--replay-chain"],
            ["--replay-chain", "--verbose"],
            ["--allow-known-replay-breaks"],
            ["--replay-chain", "unused", "--keep"],
            ["--replay-chain", "unused", "--pg-version", "18"],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run(["bash", str(script), *arguments], text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Error:", result.stdout)
                self.assertNotIn("Building", result.stdout)


if __name__ == "__main__":
    unittest.main()