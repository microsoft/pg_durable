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

from runner import Case, MANIFEST, load_manifest, sql_test


RUNNER = Path(__file__).with_name("runner.py")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        self.data = {
            "version": 1,
            "shape_count": 1,
            "shapes": [{
                "id": "gen-0001",
                "dsl": "df.sql('SELECT 1')",
                "expected": {"r": 0},
                "oracle": "exact-marker-counts",
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
        cases = load_manifest(MANIFEST)
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

    def test_loads_expectations_without_recomputing_them(self):
        self.data["shapes"][0]["expected"]["r"] = 123
        case, = load_manifest(self.write_manifest())
        self.assertEqual(case.dsl, "df.sql('SELECT 1')")
        self.assertIn("node_path = 'r') <> 123", sql_test(case))

    def test_corpus_uses_qualified_helper_for_every_marker(self):
        total = 0
        for case in load_manifest(MANIFEST):
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
            [], {}, {**self.data, "version": True}, {**self.data, "version": 2},
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
