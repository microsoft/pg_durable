#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from runner import (
    Case, MANIFEST, RelationCase, SemanticCase, json_literal, literal, load_manifest, sql_test,
)


RUNNER = Path(__file__).with_name("runner.py")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=RUNNER.parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        self.data = {
            "version": 2,
            "shape_count": 1,
            "semantic_count": 0,
            "semantic_cases": [],
            "relation_count": 0,
            "relations": [],
            "shapes": [{
                "id": "gen-0001",
                "dsl": "df.sql('SELECT 1')",
                "expected": {"r": 0},
                "oracle": "exact-marker-counts",
                "order": [],
            }],
        }

    def write_manifest(self, data=None):
        self.manifest.write_text(json.dumps(self.data if data is None else data), encoding="utf-8")
        return self.manifest

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, str(RUNNER), "--manifest", str(self.manifest), *map(str, args)],
            capture_output=True, text=True,
        )

    def test_fixed_corpus(self):
        cases = [case for case in load_manifest(MANIFEST) if isinstance(case, Case)]
        self.assertEqual(len(cases), 154)
        nested = next(case for case in cases if case.id == "gen-0076")
        self.assertEqual(nested.expected, {"r.b.b": 4, "r.b.c": 4, "r.c": 2})
        for case in cases:
            with self.subTest(case=case.id):
                sql = sql_test(case)
                self.assertIn(f"df.start(\n    {case.dsl},\n    '{case.id}'", sql)
                for path, count in case.expected.items():
                    self.assertIn(
                        f"WHERE shape_id = '{case.id}' AND node_path = '{path}') <> {count}",
                        sql,
                    )

    def test_fixed_corpus_family_and_order_totals(self):
        cases = load_manifest(MANIFEST)
        shapes = [case for case in cases if isinstance(case, Case)]
        semantic = [case for case in cases if isinstance(case, SemanticCase)]
        relations = [case for case in cases if isinstance(case, RelationCase)]
        self.assertEqual(len(cases), 185)
        self.assertEqual((len(shapes), len(semantic), len(relations)), (154, 24, 7))
        self.assertEqual(sum(len(case.order) for case in shapes), 225)
        self.assertEqual(sum(bool(case.order) for case in shapes), 88)
        for family, prefix, count in ((shapes, "gen", 154), (semantic, "sem", 24),
                                      (relations, "meta", 7)):
            with self.subTest(family=prefix):
                self.assertEqual([case.id for case in family],
                                 [f"{prefix}-{number:04d}" for number in range(1, count + 1)])

    def test_loads_expectations_without_recomputing_them(self):
        self.data["shapes"][0]["expected"]["r"] = 123
        case, = load_manifest(self.write_manifest())
        self.assertEqual(case.dsl, "df.sql('SELECT 1')")
        self.assertIn("node_path = 'r') <> 123", sql_test(case))

    def test_corpus_uses_qualified_helper_for_every_marker(self):
        total = 0
        for case in load_manifest(MANIFEST):
            if not isinstance(case, Case):
                continue
            calls = re.findall(
                r"SELECT public\.df_gen_mark\('([^']+)', '([^']+)'\)", case.dsl
            )
            with self.subTest(case=case.id):
                self.assertEqual(len(calls), len(case.expected))
                self.assertEqual({path for _, path in calls}, set(case.expected))
                self.assertTrue(all(shape_id == case.id for shape_id, _ in calls))
                self.assertNotIn("INSERT INTO", case.dsl)
                self.assertNotIn("FROM df_gen_trace", case.dsl)
            total += len(calls)
        self.assertEqual(total, 552)

    def test_wrapper_defines_invoker_helper_before_start(self):
        sql = sql_test(Case("gen-0001", "df.sql('SELECT 1')", {}))
        self.assertLess(sql.index("CREATE TABLE"), sql.index("CREATE OR REPLACE FUNCTION"))
        self.assertLess(sql.index("$MARK$;"), sql.index("df.start("))
        self.assertIn("LANGUAGE sql VOLATILE SECURITY INVOKER", sql)
        self.assertIn("SET search_path = pg_catalog", sql)
        self.assertIn("RETURNS INT", sql)
        self.assertIn("RETURNING iteration;", sql)
        self.assertIn("MAX(iteration), 0) + 1 FROM public.df_gen_trace", sql)

    def test_invalid_manifest_structure(self):
        for data in (
            [], {}, {**self.data, "version": True}, {**self.data, "version": 1},
            {**self.data, "shapes": []}, {**self.data, "shapes": {}},
            {**self.data, "shapes": [None]}, {**self.data, "shape_count": 2},
            {**self.data, "shape_count": True},
        ):
            with self.subTest(data=data), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))

    def test_invalid_case_fields(self):
        for field, value in (
            ("id", "../escape"), ("id", "gen-0001\n"), ("dsl", ""), ("dsl", None),
            ("oracle", "other"), ("expected", None), ("expected", {"r": -1}),
            ("expected", {"r": True}), ("expected", {"r": 1.5}),
            ("expected", {"r": "1"}), ("expected", {"r": 2**63}),
            ("expected", {"r'; SELECT 1": 0}),
        ):
            data = copy.deepcopy(self.data)
            data["shapes"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))

    def test_duplicate_ids_and_json_keys(self):
        self.data["shapes"] *= 2
        self.data["shape_count"] = 2
        with self.assertRaisesRegex(ValueError, "duplicate shape id"):
            load_manifest(self.write_manifest())
        self.manifest.write_text('{"version": 1, "version": 1}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            load_manifest(self.manifest)

    def add_families(self):
        self.data["semantic_count"] = 1
        self.data["semantic_cases"] = [{
            "id": "sem-0001", "name": "Typed observation",
            "dsl": "df.sql('SELECT 1')", "vars": {"x": "before"},
            "post_start_vars": {"x": "after"}, "status": "completed",
            "oracle": "exact-observations",
            "expected": [{"path": "r.x", "iteration": 1, "value": None}],
            "result": {"rows": [{"value": None}], "row_count": 1},
        }]
        self.data["relation_count"] = 1
        self.data["relations"] = [{
            "id": "meta-0001", "name": "Identity", "rationale": "Same observable work",
            "dsl_a": "df.sql('SELECT 1')", "dsl_b": "df.sql('SELECT 1')",
            "oracle": "equivalent-marker-counts", "expected": {"r.a": 1},
        }]

    def test_loads_all_families(self):
        self.add_families()
        cases = load_manifest(self.write_manifest())
        self.assertEqual([case.id for case in cases], ["gen-0001", "sem-0001", "meta-0001"])
        self.assertEqual(cases[1].expected[0]["value"], None)
        self.assertEqual(cases[2].expected, {"r.a": 1})

    def test_rejects_unknown_assertions_and_invalid_order(self):
        self.data["shapes"][0]["expected"] = {"r.a": 2, "r.b": 1}
        for edges in (None, [["r.a", 0, "r.b", 1]], [["r.a", True, "r.b", 1]],
                      [["r.a", 3, "r.b", 1]], [["r.unknown", 1, "r.b", 1]],
                      [["r.a", 1, "r.a", 1]], [["r.a", 1, "r.b"]],
                      [["r.a", 1, "r.b", 1]] * 2):
            data = copy.deepcopy(self.data)
            data["shapes"][0]["order"] = edges
            with self.subTest(edges=edges), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))
        self.data["shapes"][0]["ordr"] = []
        with self.assertRaisesRegex(ValueError, "unknown"):
            load_manifest(self.write_manifest())

    def test_invalid_semantic_fields(self):
        self.add_families()
        for field, value in (
            ("id", "gen-0001"), ("name", ""), ("dsl", " "),
            ("vars", {"x": 1}), ("post_start_vars", []), ("status", "cancelled"),
            ("oracle", "exact-marker-counts"), ("expected", {}),
            ("expected", [{"path": "r", "iteration": True, "value": 1}]),
            ("expected", [{"path": "r", "iteration": 0, "value": 1}]),
            ("expected", [{"path": "r", "iteration": 1}]),
            ("expected", [{"path": "r", "iteration": 1, "value": 1, "extra": 1}]),
            ("expected", [{"path": "r", "iteration": 1, "value": 1}] * 2),
            ("expected", [{"path": "bad", "iteration": 1, "value": 1}]),
            ("result", float("inf")), ("result", {"nested": float("nan")}),
            ("error", ""), ("results", {}), ("status", "failed"),
        ):
            data = copy.deepcopy(self.data)
            data["semantic_cases"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))
        self.data["semantic_cases"][0].update(status="failed", error="division by zero")
        self.data["semantic_cases"][0].pop("result")
        self.assertEqual(load_manifest(self.write_manifest())[1].error, "division by zero")

    def test_invalid_relation_fields_and_counts(self):
        self.add_families()
        for field, value in (
            ("name", ""), ("rationale", ""), ("dsl_a", ""), ("dsl_b", None),
            ("expected", {}), ("expected", {"r.a": 0}), ("expected", {"r.a": True}),
            ("expected", {"bad": 1}), ("oracle", "other"), ("order", []),
        ):
            data = copy.deepcopy(self.data)
            data["relations"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))
        for field in ("semantic_count", "relation_count"):
            for value in (True, 0, -1, "1"):
                data = {**self.data, field: value}
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    load_manifest(self.write_manifest(data))

    def test_required_fields_nonfinite_json_and_duplicate_family_ids(self):
        self.add_families()
        for section in ("shapes", "semantic_cases", "relations"):
            for key in self.data[section][0]:
                if key == "result":
                    continue
                data = copy.deepcopy(self.data)
                del data[section][0][key]
                with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                    load_manifest(self.write_manifest(data))
        for section, count_key in (("semantic_cases", "semantic_count"),
                                   ("relations", "relation_count")):
            data = copy.deepcopy(self.data)
            data[section] *= 2
            data[count_key] = 2
            with self.assertRaisesRegex(ValueError, "duplicate"):
                load_manifest(self.write_manifest(data))
        for value in (float("nan"), float("-inf"), 1e309, "\0", "\ud800"):
            data = copy.deepcopy(self.data)
            data["semantic_cases"][0]["expected"][0]["value"] = {"nested": [value]}
            with self.subTest(value=value), self.assertRaises(ValueError):
                load_manifest(self.write_manifest(data))
        self.data["semantic_cases"][0].update(status="failed", error="expected", expected=[])
        with self.assertRaisesRegex(ValueError, "prefix observations"):
            load_manifest(self.write_manifest())

    def test_json_null_result_is_not_an_absent_result(self):
        self.add_families()
        semantic = self.data["semantic_cases"][0]
        semantic["result"] = None
        self.assertIn("df.result(inst_id)::jsonb IS DISTINCT FROM 'null'::jsonb",
                      sql_test(load_manifest(self.write_manifest())[1]))
        del semantic["result"]
        self.assertNotIn("df.result(inst_id)", sql_test(load_manifest(self.write_manifest())[1]))

    def test_check_all_families_does_not_write_and_invalid_case_writes_nothing(self):
        self.add_families()
        self.write_manifest()
        before = self.manifest.read_bytes()
        result = self.cli("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated 3 fixed manifest cases", result.stdout)
        self.assertEqual(self.manifest.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [self.manifest])
        out = self.root / "invalid"
        out.mkdir()
        self.data["relations"][0]["expected"] = {}
        self.write_manifest()
        self.assertNotEqual(self.cli("--out", out).returncode, 0)
        self.assertEqual(list(out.iterdir()), [])
    def test_shared_fixture_and_fail_closed_order(self):
        case = Case("gen-0001", "df.sql('SELECT 1')", {"r": 2},
                    [("r", 1, "r", 2)])
        sql = sql_test(case)
        self.assertEqual(sql, sql_test(case))
        self.assertIn("ADD COLUMN IF NOT EXISTS event_id BIGINT", sql)
        self.assertIn("CACHE 1", sql)
        self.assertIn("ADD COLUMN IF NOT EXISTS observation JSONB", sql)
        self.assertNotIn("UNIQUE", sql)
        self.assertIn("public.df_gen_observe", sql)
        self.assertIn("iteration = 1", sql)
        self.assertIn("iteration = 2", sql)
        self.assertIn("causal edge", sql)
        self.assertIn("IS NOT TRUE", sql)
        reordered = Case(case.id, case.dsl, case.expected, list(reversed(case.order)))
        self.assertEqual(sql, sql_test(reordered))

    def test_semantic_rendering_cleanup_exact_values_and_error(self):
        self.add_families()
        semantic = self.data["semantic_cases"][0]
        semantic["vars"] = {"x": "O'Reilly\\$GEN$"}
        semantic["expected"][0]["value"] = {"text": "O'Reilly\\$GEN$"}
        case = load_manifest(self.write_manifest())[1]
        sql = sql_test(case)
        self.assertEqual(sql.count("SELECT df.clearvars();"), 3)
        self.assertLess(sql.index("df.clearvars()"), sql.index("df.setvar("))
        self.assertLess(sql.index("df.start("), sql.index("'after'"))
        self.assertLess(sql.index("df.clearvars()", sql.index("df.start(")),
                        sql.index("df.wait_for_completion"))
        self.assertIn("IS DISTINCT FROM", sql)
        self.assertIn("df.result(inst_id)::jsonb", sql)
        self.assertIn("unexpected observation", sql)
        self.assertIn("O''Reilly\\\\$GEN$", sql)
        self.assertNotIn("DO $GEN$", sql)
        semantic.update(status="failed", error="division by zero")
        semantic.pop("result")
        sql = sql_test(load_manifest(self.write_manifest())[1])
        self.assertIn("df.instance_info(inst_id)", sql)
        self.assertIn("EXIT WHEN failure_output IS NOT NULL;", sql)
        self.assertIn("division by zero", sql)

    def test_semantic_release_signal_validation_and_emission(self):
        self.add_families()
        semantic = self.data["semantic_cases"][0]
        semantic["release_signal"] = "snapshot_ready"
        case = load_manifest(self.write_manifest())[1]
        self.assertEqual(case.release_signal, "snapshot_ready")
        sql = sql_test(case)
        signal = "SELECT df.signal(instance_id, 'snapshot_ready', '{}') FROM _gen_state;"
        self.assertIn(signal, sql)
        start_at = sql.index("df.start(")
        cleanup_at = sql.index("SELECT df.clearvars();", start_at)
        self.assertLess(sql.index("'after'", start_at), cleanup_at)
        self.assertLess(cleanup_at, sql.index(signal))
        self.assertLess(sql.index(signal), sql.index("df.wait_for_completion"))
        self.assertIn("release_deadline TIMESTAMPTZ := clock_timestamp() + INTERVAL '60 seconds'", sql)
        self.assertIn("clock_timestamp() >= release_deadline", sql)
        self.assertIn("release signal timed out", sql)
        self.assertIn("df.status(inst_id)", sql)
        self.assertIn("PERFORM df.signal(inst_id, 'snapshot_ready', '{}');", sql)
        self.assertIn("EXIT WHEN df.status(inst_id) IN ('completed', 'failed', 'cancelled');", sql)
        self.assertLess(sql.index(signal), sql.index("pg_sleep("))
        self.assertIn("EXTRACT(EPOCH FROM release_deadline - clock_timestamp())", sql)
        reordered = copy.deepcopy(self.data)
        reordered["semantic_cases"][0] = dict(reversed(list(semantic.items())))
        self.assertEqual(sql, sql_test(load_manifest(self.write_manifest(reordered))[1]))
        del semantic["release_signal"]
        self.assertNotIn("df.signal(", sql_test(load_manifest(self.write_manifest())[1]))
        for value in (None, "", "two words", "x'; SELECT 1", "snapshot\n", True, 1, [], {}):
            semantic["release_signal"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "release_signal"):
                load_manifest(self.write_manifest())

    def test_relation_rendering_and_deterministic_all_family_cli(self):
        self.add_families()
        self.data["semantic_cases"][0]["vars"]["another"] = "value"
        self.data["semantic_cases"][0]["expected"][0]["value"] = {"z": 1, "a": {"z": 2, "a": 3}}
        self.data["relations"][0]["expected"]["r.b"] = 2
        cases = load_manifest(self.write_manifest())
        sql = sql_test(cases[2])
        self.assertEqual(sql.count("SELECT df.start("), 2)
        self.assertIn("'meta-0001-a'", sql)
        self.assertIn("'meta-0001-b'", sql)
        self.assertEqual(sql.count(" EXCEPT "), 2)
        self.assertEqual(sql.count("GROUP BY node_path"), 4)
        self.assertIn("ground truth", sql)
        before = self.manifest.read_bytes()
        out = self.root / "all"
        out.mkdir()
        result = self.cli("--out", out)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(path.stem for path in out.iterdir()), sorted(case.id for case in cases))
        self.assertEqual(self.manifest.read_bytes(), before)

        def reverse(obj):
            if isinstance(obj, dict):
                return {key: reverse(value) for key, value in reversed(list(obj.items()))}
            if isinstance(obj, list):
                return [reverse(value) for value in obj]
            return obj
        reordered = load_manifest(self.write_manifest(reverse(self.data)))
        self.assertEqual([sql_test(case) for case in cases],
                         [sql_test(case) for case in reordered])

    def test_dollar_delimiters_and_assertion_order_are_deterministic(self):
        observations = [
            {"path": "r.z", "iteration": 2, "value": "$GEN$ $GEN_$ $GEN__$"},
            {"path": "r.a", "iteration": 1, "value": "a'b\\c\n"},
        ]
        case = SemanticCase("sem-0001", "Quoted observations", "df.sql('SELECT 1')",
                            {}, {}, "completed", observations)
        reordered = SemanticCase(case.id, case.name, case.dsl, {}, {}, case.status,
                                 list(reversed(observations)))
        sql = sql_test(case)
        self.assertEqual(sql, sql_test(reordered))
        self.assertIn("DO $GEN___$", sql)
        self.assertIn("END $GEN___$;", sql)
        shape = Case("gen-0001", "df.sql('SELECT 1')", {"r": 3},
                     [("r", 2, "r", 3), ("r", 1, "r", 2)])
        self.assertEqual(sql_test(shape), sql_test(
            Case(shape.id, shape.dsl, shape.expected, list(reversed(shape.order)))))

    def test_wrapper_checks_completion_zero_counts_and_unknown_paths(self):
        case = Case("gen-0001", "df.sql('SELECT 1')", {"r.t": 1, "r.e": 0})
        sql = sql_test(case)
        self.assertIn("SET SESSION AUTHORIZATION df_e2e_user;", sql)
        self.assertIn("DELETE FROM public.df_gen_trace WHERE shape_id = 'gen-0001';", sql)
        self.assertIn("df.wait_for_completion(inst_id, 60)", sql)
        self.assertIn("status IS DISTINCT FROM 'completed'", sql)
        self.assertIn("node_path = 'r.e') <> 0", sql)
        self.assertIn("node_path IS NULL OR node_path NOT IN ('r.e', 'r.t')", sql)
        self.assertTrue(sql.endswith("DROP TABLE _gen_state;\nSELECT 'TEST PASSED' AS result;\n"))
        reordered = Case(case.id, case.dsl, dict(reversed(list(case.expected.items()))))
        self.assertEqual(sql, sql_test(reordered))

    def test_empty_expected_map_rejects_any_trace(self):
        sql = sql_test(Case("gen-0001", "df.sql('SELECT 1')", {}))
        self.assertNotIn("NOT IN", sql)
        self.assertIn("WHERE shape_id = 'gen-0001';\n    IF unexpected IS NOT NULL", sql)

    def test_cli_prepares_repeatable_wrappers_without_changing_manifest(self):
        self.write_manifest()
        before = self.manifest.read_bytes()
        outputs = []
        for name in ("first", "second"):
            out = self.root / name
            out.mkdir()
            result = self.cli("--out", out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Prepared 1 fixed manifest cases", result.stdout)
            self.assertEqual([path.name for path in out.iterdir()], ["gen-0001.sql"])
            outputs.append((out / "gen-0001.sql").read_bytes())
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(self.manifest.read_bytes(), before)

    def test_cli_check_does_not_write_files(self):
        self.write_manifest()
        before = self.manifest.read_bytes()
        result = self.cli("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated 1 fixed manifest cases", result.stdout)
        self.assertEqual(list(self.root.iterdir()), [self.manifest])
        self.assertEqual(self.manifest.read_bytes(), before)

    def test_cli_reports_input_and_output_errors(self):
        result = self.cli("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matrix runner:", result.stderr)
        self.manifest.write_text("{", encoding="utf-8")
        result = self.cli("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matrix runner:", result.stderr)
        self.write_manifest()
        result = self.cli("--out", self.root / "missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("matrix runner:", result.stderr)
        result = self.cli("--out", self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output directory must be empty", result.stderr)
        self.assertTrue(self.manifest.exists())
        self.assertNotEqual(self.cli("--max-depth", "3").returncode, 0)


@unittest.skipUnless(os.environ.get("MATRIX_TEST_PSQL"), "requires a running E2E database")
class LiveRunnerTests(unittest.TestCase):
    def psql(self, sql):
        return subprocess.run(
            [os.environ["MATRIX_TEST_PSQL"], "-X", "-h", "localhost",
             "-p", os.environ.get("PGPORT", "28817"), "-U", "postgres", "-d", "postgres",
             "-v", "ON_ERROR_STOP=1"],
            input=sql, capture_output=True, text=True,
        )

    def assert_wrapper(self, case, error=None, inject=""):
        sql = sql_test(case)
        if inject:
            # Tamper only after execution, so a negative test exercises the oracle.
            inject = (
                "SELECT df.wait_for_completion(instance_id, 60) FROM _gen_state;\n" + inject
            )
            sql = sql.replace("\nDO $GEN$\n", "\n" + inject + "\nDO $GEN$\n", 1)
        result = self.psql(sql)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("TEST PASSED", result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        return result

    def semantic(self, dsl, expected, **kwargs):
        return SemanticCase("sem-9001", "Live oracle probe", dsl, {}, {},
                            "completed", expected, **kwargs)

    def test_live_order_oracles(self):
        marker = "df.sql($mk$SELECT public.df_gen_mark('gen-9010', 'r')$mk$)"
        case = Case("gen-9010", f"df.seq({marker}, {marker})", {"r": 2},
                    [("r", 1, "r", 2)])
        self.assert_wrapper(case)
        reversed_case = Case(case.id, case.dsl, case.expected, [("r", 2, "r", 1)])
        self.assert_wrapper(reversed_case, "causal edge r[2] -> r[1]")
        for update in (
            "UPDATE public.df_gen_trace SET iteration = 3 WHERE shape_id = 'gen-9010' AND iteration = 1;",
            "UPDATE public.df_gen_trace SET iteration = 3 WHERE shape_id = 'gen-9010' AND iteration = 2;",
            "UPDATE public.df_gen_trace SET iteration = 1 WHERE shape_id = 'gen-9010';",
            "UPDATE public.df_gen_trace SET event_id = 1 WHERE shape_id = 'gen-9010';",
        ):
            with self.subTest(update=update):
                self.assert_wrapper(case, "causal edge r[1] -> r[2]", update)
        # Parallel siblings deliberately carry no order edge.
        other = marker.replace("'r'", "'r.b'")
        self.assert_wrapper(Case(case.id, f"df.join({marker}, {other})",
                                 {"r": 1, "r.b": 1}))

    def test_live_exact_observations(self):
        values = [7, "7", True, {"a": [1, None]}, [False, "x"], None,
                  "O'Reilly\\$GEN$"]
        for value in values:
            expression = json_literal(value)
            dsl = f"df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.x', {expression})$node$)"
            expected = [{"path": "r.x", "iteration": 1, "value": value}]
            with self.subTest(value=value):
                self.assert_wrapper(self.semantic(dsl, expected))
        dsl = "df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.x', '1'::jsonb)$node$)"
        expected = [{"path": "r.x", "iteration": 1, "value": 1}]
        case = self.semantic(dsl, expected)
        for update, error in (
            ("DELETE FROM public.df_gen_trace WHERE shape_id = 'sem-9001';", "observation cardinality"),
            ("UPDATE public.df_gen_trace SET observation = '\"1\"'::jsonb WHERE shape_id = 'sem-9001';",
             "observation value"),
            ("INSERT INTO public.df_gen_trace(shape_id,node_path,iteration,observation) "
             "SELECT shape_id,node_path,iteration,observation FROM public.df_gen_trace "
             "WHERE shape_id = 'sem-9001';", "observation cardinality"),
            ("SELECT public.df_gen_observe('sem-9001', 'r.extra', '2'::jsonb);", "unexpected observation"),
            ("SELECT public.df_gen_observe('sem-9001', NULL, '2'::jsonb);", "unexpected observation"),
            ("INSERT INTO public.df_gen_trace(shape_id,node_path,iteration,observation) "
             "VALUES ('sem-9001','r.x',NULL,'1');", "unexpected observation"),
        ):
            with self.subTest(error=error, update=update):
                self.assert_wrapper(case, error, update)
        null_dsl = dsl.replace("'1'::jsonb", "NULL::jsonb")
        self.assert_wrapper(self.semantic(null_dsl, [{"path": "r.x", "iteration": 1, "value": None}]),
                            "observation value")

    def test_live_result_and_failed_semantic_cleanup(self):
        observe = "df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.prefix', 'true'::jsonb)$node$)"
        expected = [{"path": "r.prefix", "iteration": 1, "value": True}]
        result = {"rows": [{"df_gen_observe": 1}], "row_count": 1}
        self.assert_wrapper(self.semantic(observe, expected, result=result, has_result=True))
        self.assert_wrapper(self.semantic(observe, expected, result={}, has_result=True),
                            "final result mismatch")
        self.assert_wrapper(self.semantic(observe, expected, result=None, has_result=True),
                            "final result mismatch")
        failed_dsl = f"df.seq({observe}, df.seq(df.sql('SELECT 1/0'), {observe.replace('r.prefix', 'r.suffix')}))"
        case = SemanticCase("sem-9001", "Expected failure", failed_dsl,
                            {"oracle_cleanup": "before"}, {"oracle_cleanup": "after"},
                            "failed", expected, error="division by zero")
        self.assert_wrapper(case)
        self.assert_wrapper(
            SemanticCase(case.id, case.name, case.dsl, case.vars, case.post_start_vars,
                         case.status, case.expected, error="wrong failure"), "expected error substring")
        # Cleanup happens before a failing assertion, in its own committed statement.
        result = self.psql("""
SET SESSION AUTHORIZATION df_e2e_user;
DO $CHECK$ BEGIN
    IF EXISTS (SELECT 1 FROM df.vars WHERE name = 'oracle_cleanup') THEN
        RAISE EXCEPTION 'semantic variables leaked';
    END IF;
END $CHECK$;
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_snapshot_and_quoted_variable_values(self):
        dsl = "df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.x', to_jsonb('{x}'::text))$node$)"
        case = SemanticCase("sem-9001", "Snapshot", dsl, {"x": "before"},
                            {"x": "after"}, "completed",
                            [{"path": "r.x", "iteration": 1, "value": "before"}])
        self.assert_wrapper(case)
        # A quoted/backslash value is SQL source for raw substitution.
        value = "O'Reilly\\$GEN$"
        dsl = dsl.replace("'{x}'::text", "{x}::text")
        case = SemanticCase(case.id, case.name, dsl, {"x": literal(value)}, {},
                            "completed", [{"path": "r.x", "iteration": 1, "value": value}])
        self.assert_wrapper(case)

    def test_live_snapshot_signal_gate_and_timeout(self):
        gate = "df.as(df.wait_for_signal('snapshot_ready', 60), 'gate')"
        observe_gate = (
            "df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.gate', "
            "to_jsonb($gate.timed_out::boolean))$node$)"
        )
        observe_value = (
            "df.sql($node$SELECT public.df_gen_observe('sem-9001', 'r.value', "
            "to_jsonb('{x}'::text))$node$)"
        )
        dsl = f"df.seq({gate}, df.seq({observe_gate}, {observe_value}))"
        expected = [
            {"path": "r.gate", "iteration": 1, "value": False},
            {"path": "r.value", "iteration": 1, "value": "before"},
        ]
        case = SemanticCase("sem-9001", "Gated snapshot", dsl, {"x": "before"},
                            {"x": "after"}, "completed", expected,
                            release_signal="snapshot_ready")
        self.assert_wrapper(case)
        without_signal = SemanticCase(case.id, case.name, case.dsl.replace("60)", "1)"), case.vars,
                                      case.post_start_vars, case.status, case.expected)
        self.assert_wrapper(without_signal, "observation value r.gate[1]")

    def test_live_release_deadline_fails_without_another_wait(self):
        case = SemanticCase("sem-9002", "Unconsumed release", "df.sleep(60)", {}, {},
                            "completed", [], release_signal="snapshot_ready")
        sql = sql_test(case).replace("INTERVAL '60 seconds'", "INTERVAL '0 seconds'")
        try:
            result = self.psql(sql)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("release signal timed out", result.stderr)
            self.assertNotIn("df.wait_for_completion() is deprecated", result.stderr)
        finally:
            result = self.psql("""
SET SESSION AUTHORIZATION df_e2e_user;
SELECT df.cancel(id) FROM df.instances
WHERE label = 'sem-9002' AND status NOT IN ('completed', 'failed', 'cancelled');
""")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_relations_nonvacuous_and_multiset(self):
        a = "df.sql($mk$SELECT public.df_gen_mark('meta-9001-a', 'r.a')$mk$)"
        b = a.replace("meta-9001-a", "meta-9001-b")
        case = RelationCase("meta-9001", "Identity", "Matching work", a, b, {"r.a": 1})
        self.assert_wrapper(case)
        for left, right in (("df.sql('SELECT 1')", "df.sql('SELECT 1')"),
                            (a, "df.sql('SELECT 1')"), ("df.sql('SELECT 1')", b)):
            self.assert_wrapper(RelationCase(case.id, case.name, case.rationale,
                                             left, right, case.expected), "ground truth")
        self.assert_wrapper(RelationCase(case.id, case.name, case.rationale, a,
                                         "df.sql('SELECT 1/0')", case.expected), "status = failed")
        for tag in ("meta-9001-a", "meta-9001-b"):
            for path in ("'r.unknown'", "NULL"):
                self.assert_wrapper(case, "unexpected path(s)",
                                    f"SELECT public.df_gen_mark('{tag}', {path});")

    def test_live_fixture_migrates_v1_and_global_sequence(self):
        table = "public.df_gen_trace_v1_probe"
        setup = f"""
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TABLE {table} (shape_id TEXT, node_path TEXT, iteration INT);
INSERT INTO {table} VALUES ('old-case', 'r', 1);
"""
        marker = "df.sql($mk$SELECT public.df_gen_mark('gen-9011', 'r')$mk$)"
        sql = sql_test(Case("gen-9011", marker, {"r": 1}))
        sql = sql.replace("public.df_gen_trace", table)
        sql = sql.replace("public.df_gen_mark", "public.df_gen_mark_v1_probe")
        sql = sql.replace("public.df_gen_observe", "public.df_gen_observe_v1_probe")
        check = f"""
SET SESSION AUTHORIZATION df_e2e_user;
DO $CHECK$ BEGIN
    IF (SELECT COUNT(event_id) FROM {table}) <> 2 THEN
        RAISE EXCEPTION 'migration failed to backfill old events';
    END IF;
    IF (SELECT cache_size FROM pg_sequences
        WHERE schemaname = 'public' AND sequencename = 'df_gen_trace_v1_probe_event_id_seq') <> 1 THEN
        RAISE EXCEPTION 'event sequence must not use session caches';
    END IF;
END $CHECK$;
"""
        try:
            result = self.psql(setup + sql + check)
            self.assertEqual(result.returncode, 0, result.stderr)
            # A separate backend gets a later ordinal; the default cannot cache ranges.
            result = self.psql("""
SET SESSION AUTHORIZATION df_e2e_user;
SELECT public.df_gen_mark_v1_probe('next-backend', 'r');
""")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.psql(f"""
SET SESSION AUTHORIZATION df_e2e_user;
DO $CHECK$ BEGIN
    IF (SELECT event_id FROM {table} WHERE shape_id = 'next-backend') <=
       (SELECT MAX(event_id) FROM {table} WHERE shape_id <> 'next-backend') THEN
        RAISE EXCEPTION 'global event sequence reversed';
    END IF;
END $CHECK$;
""")
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            result = self.psql(f"""
SET SESSION AUTHORIZATION df_e2e_user;
DROP FUNCTION IF EXISTS public.df_gen_mark_v1_probe(TEXT,TEXT);
DROP FUNCTION IF EXISTS public.df_gen_observe_v1_probe(TEXT,TEXT,JSONB);
DROP TABLE IF EXISTS {table};
""")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_assertions(self):
        marker = "df.sql($mk$SELECT public.df_gen_mark('gen-9001', 'r')$mk$)"
        scenarios = [
            (marker, {"r": 1}, None),
            (marker, {"r": 2}, "path r expected 2, got 1"),
            (marker, {"r": 0}, "path r expected 0, got 1"),
            ("df.sql('SELECT 1')", {"r": 0}, None),
            (marker, {}, "unexpected path(s): r"),
            (marker.replace("'r')", "NULL)"), {"r": 0}, "unexpected path(s): <NULL>"),
            ("df.sql('SELECT 1/0')", {}, "status = failed"),
        ]
        try:
            for dsl, expected, error in scenarios:
                with self.subTest(expected=expected, error=error):
                    result = self.psql(sql_test(Case("gen-9001", dsl, expected)))
                    if error is None:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("TEST PASSED", result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(error, result.stderr)
        finally:
            result = self.psql(
                "SET SESSION AUTHORIZATION df_e2e_user; "
                "DELETE FROM public.df_gen_trace WHERE shape_id = 'gen-9001';"
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_helper_ordinals_and_activity_result(self):
        marker = "df.sql($mk$SELECT public.df_gen_mark('gen-9002', 'r')$mk$)"
        sql = sql_test(Case("gen-9002", f"df.seq({marker}, {marker})", {"r": 2}))
        sql = sql.replace("DROP TABLE _gen_state;", """
DO $CHECK$
DECLARE
    output JSONB;
BEGIN
    SELECT df.result(instance_id)::jsonb INTO output FROM _gen_state;
    IF output IS DISTINCT FROM '{"rows":[{"df_gen_mark":2}],"row_count":1}'::jsonb THEN
        RAISE EXCEPTION 'Unexpected helper activity output: %', output;
    END IF;
    IF (SELECT array_agg(iteration ORDER BY iteration) FROM public.df_gen_trace
        WHERE shape_id = 'gen-9002' AND node_path = 'r') IS DISTINCT FROM ARRAY[1,2] THEN
        RAISE EXCEPTION 'Incorrect per-marker ordinals';
    END IF;
END $CHECK$;
DROP TABLE _gen_state;
-- Neither the caller's search path nor a shadow table may redirect the helper.
CREATE TEMP TABLE df_gen_trace (shape_id TEXT, node_path TEXT, iteration INT);
SET search_path = pg_temp, pg_catalog;
DO $CHECK$
BEGIN
    IF public.df_gen_mark('gen-9002', 'r') <> 3
       OR public.df_gen_mark('gen-9002', 'r.other') <> 1
       OR public.df_gen_mark('gen-9003', 'r') <> 1 THEN
        RAISE EXCEPTION 'Helper counters are not scoped to shape and path';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_temp.df_gen_trace) THEN
        RAISE EXCEPTION 'Helper wrote to shadow table';
    END IF;
    IF (SELECT prosecdef FROM pg_proc
        WHERE oid = 'public.df_gen_mark(text,text)'::regprocedure) THEN
        RAISE EXCEPTION 'Helper must use invoker privileges';
    END IF;
END $CHECK$;
""")
        try:
            result = self.psql(sql)
            self.assertEqual(result.returncode, 0, result.stderr)
        finally:
            result = self.psql(
                "SET SESSION AUTHORIZATION df_e2e_user; "
                "DELETE FROM public.df_gen_trace WHERE shape_id IN ('gen-9002', 'gen-9003');"
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
