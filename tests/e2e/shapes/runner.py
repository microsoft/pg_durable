#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Adapt the fixed manifest to the existing per-file SQL E2E harness."""

import argparse
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import re
from typing import Optional, Union


MANIFEST = Path(__file__).with_name("manifest.json")


@dataclass(frozen=True)
class Case:
    id: str
    dsl: str
    expected: dict[str, int]
    order: list = field(default_factory=list)


@dataclass(frozen=True)
class SemanticCase:
    id: str
    name: str
    dsl: str
    vars: dict[str, str]
    post_start_vars: dict[str, str]
    status: str
    expected: list
    result: object = None
    has_result: bool = False
    error: Optional[str] = None
    release_signal: Optional[str] = None


@dataclass(frozen=True)
class RelationCase:
    id: str
    name: str
    rationale: str
    dsl_a: str
    dsl_b: str
    expected: dict[str, int]


Record = Union[Case, SemanticCase, RelationCase]


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def validate_json(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("nonfinite JSON number")
    if isinstance(value, str) and (
        "\0" in value or any(0xD800 <= ord(char) <= 0xDFFF for char in value)
    ):
        raise ValueError("JSON strings must be valid PostgreSQL text")
    if isinstance(value, dict):
        for key, item in value.items():
            validate_json(key)
            validate_json(item)
    elif isinstance(value, list):
        for item in value:
            validate_json(item)


def fields(record, required, optional, context):
    missing = required - record.keys()
    unknown = record.keys() - required - optional
    if missing:
        raise ValueError(f"{context}: missing fields: {', '.join(sorted(missing))}")
    if unknown:
        raise ValueError(f"{context}: unknown fields: {', '.join(sorted(unknown))}")


def text(value, context):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context}: must be a nonempty string")


def marker_path(value, context):
    if not isinstance(value, str) or not re.fullmatch(r"r(?:\.[a-z0-9]+)*", value):
        raise ValueError(f"{context}: invalid marker path: {value!r}")


def integer(value, minimum, maximum, context):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{context}: must be an integer in [{minimum}, {maximum}]")


def counts(expected, context, positive=False):
    if not isinstance(expected, dict):
        raise ValueError(f"{context}: expected must be an object")
    for path, count in expected.items():
        marker_path(path, context)
        integer(count, 1 if positive else 0, 2**63 - 1, f"{context}: {path} count")
    if positive and not expected:
        raise ValueError(f"{context}: ground truth must be nonempty and positive")


def load_manifest(path: Path) -> list[Record]:
    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)
    validate_json(data)
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 2:
        raise ValueError("manifest version must be 2 (version 1 is unsupported)")
    fields(data, {"version", "shape_count", "shapes", "semantic_count", "semantic_cases",
                  "relation_count", "relations"},
           {"generator", "max_depth", "combinators", "loop_iters", "include_seeds"}, "manifest")
    if "generator" in data:
        text(data["generator"], "generator")
    for key in ("max_depth", "loop_iters"):
        if key in data:
            integer(data[key], 0 if key == "max_depth" else 1, 2**63 - 1, key)
    if "include_seeds" in data and type(data["include_seeds"]) is not bool:
        raise ValueError("include_seeds must be a boolean")
    if "combinators" in data:
        values = data["combinators"]
        if (not isinstance(values, list) or
                any(not isinstance(value, str) or value not in
                    {"seq", "if", "loop", "join", "race"} for value in values) or
                len(values) != len(set(values))):
            raise ValueError("combinators must contain distinct supported names")
    cases = []
    ids = set()
    for section, count_key, prefix, oracle in (
        ("shapes", "shape_count", "gen", "exact-marker-counts"),
        ("semantic_cases", "semantic_count", "sem", "exact-observations"),
        ("relations", "relation_count", "meta", "equivalent-marker-counts"),
    ):
        records = data[section]
        if not isinstance(records, list) or (section == "shapes" and not records):
            raise ValueError(f"manifest {section} must be an array (shapes nonempty)")
        if type(data[count_key]) is not int or data[count_key] != len(records):
            raise ValueError(f"manifest {count_key} does not match {section}")
        for record in records:
            if not isinstance(record, dict):
                raise ValueError(f"each {section} record must be an object")
            case_id = record.get("id")
            if not isinstance(case_id, str) or not re.fullmatch(prefix + r"-[0-9]{4,}", case_id):
                raise ValueError(f"invalid {section} id: {case_id!r}")
            if case_id in ids:
                raise ValueError(f"duplicate {'shape' if prefix == 'gen' else 'case'} id: {case_id}")
            ids.add(case_id)
            required = {"id", "oracle", "expected"}
            optional = set()
            if prefix == "gen":
                required |= {"dsl", "order"}
                optional = {"signature", "depth"}
            elif prefix == "sem":
                required |= {"name", "dsl", "vars", "post_start_vars", "status"}
                optional = {"result", "error", "release_signal"}
            else:
                required |= {"name", "rationale", "dsl_a", "dsl_b"}
            fields(record, required, optional, case_id)
            if record["oracle"] != oracle:
                raise ValueError(f"{case_id}: unsupported oracle")
            for key in ("dsl", "name", "rationale", "dsl_a", "dsl_b", "signature"):
                if key in record:
                    text(record[key], f"{case_id}: {key}")
            expected = record["expected"]
            if prefix == "gen":
                counts(expected, case_id)
                if "depth" in record:
                    integer(record["depth"], 0, 2**63 - 1, f"{case_id}: depth")
                edges = record["order"]
                if not isinstance(edges, list):
                    raise ValueError(f"{case_id}: order must be an array")
                seen = set()
                for edge in edges:
                    if not isinstance(edge, list) or len(edge) != 4:
                        raise ValueError(f"{case_id}: order edges need four entries")
                    for path, iteration in (edge[:2], edge[2:]):
                        marker_path(path, case_id)
                        integer(iteration, 1, expected.get(path, 0), f"{case_id}: order endpoint")
                    key = tuple(edge)
                    if key in seen or edge[:2] == edge[2:]:
                        raise ValueError(f"{case_id}: duplicate or self order edge: {edge}")
                    seen.add(key)
                cases.append(Case(case_id, record["dsl"], expected, edges))
            elif prefix == "sem":
                for key in ("vars", "post_start_vars"):
                    values = record[key]
                    if not isinstance(values, dict):
                        raise ValueError(f"{case_id}: {key} must be a string map")
                    for name, value in values.items():
                        text(name, f"{case_id}: variable name")
                        if not isinstance(value, str):
                            raise ValueError(f"{case_id}: {key} values must be strings")
                if record["status"] not in ("completed", "failed"):
                    raise ValueError(f"{case_id}: unsupported status")
                if record["status"] == "failed":
                    text(record.get("error"), f"{case_id}: failed cases require error substring")
                    if not expected:
                        raise ValueError(f"{case_id}: failed cases require prefix observations")
                elif "error" in record:
                    raise ValueError(f"{case_id}: error is only valid for failed cases")
                if "release_signal" in record:
                    signal = record["release_signal"]
                    if not isinstance(signal, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", signal):
                        raise ValueError(f"{case_id}: release_signal must be an identifier string")
                if not isinstance(expected, list):
                    raise ValueError(f"{case_id}: expected observations must be an array")
                seen = set()
                for observation in expected:
                    if not isinstance(observation, dict):
                        raise ValueError(f"{case_id}: each observation must be an object")
                    fields(observation, {"path", "iteration", "value"}, set(), case_id)
                    marker_path(observation["path"], case_id)
                    integer(observation["iteration"], 1, 2**31 - 1, f"{case_id}: iteration")
                    key = (observation["path"], observation["iteration"])
                    if key in seen:
                        raise ValueError(f"{case_id}: duplicate observation: {key}")
                    seen.add(key)
                cases.append(SemanticCase(
                    case_id, record["name"], record["dsl"], record["vars"],
                    record["post_start_vars"], record["status"], expected,
                    record.get("result"), "result" in record, record.get("error"),
                    record.get("release_signal"),
                ))
            else:
                counts(expected, case_id, positive=True)
                cases.append(RelationCase(case_id, record["name"], record["rationale"],
                                          record["dsl_a"], record["dsl_b"], expected))
    return cases


def literal(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("'", "''")
    return ("E" if "\\" in value else "") + "'" + escaped + "'"


def json_literal(value) -> str:
    return literal(json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False)) + "::jsonb"


def block(body: str) -> str:
    # Assertions can contain arbitrary JSON strings, including dollar delimiters.
    delimiter = "$GEN$"
    while delimiter in body:
        delimiter = delimiter[:-1] + "_$"
    return f"DO {delimiter}\n{body}\nEND {delimiter};"


FIXTURE = """CREATE TABLE IF NOT EXISTS public.df_gen_trace (shape_id TEXT, node_path TEXT, iteration INT);
ALTER TABLE public.df_gen_trace ADD COLUMN IF NOT EXISTS shape_id TEXT;
ALTER TABLE public.df_gen_trace ADD COLUMN IF NOT EXISTS event_id BIGINT
    GENERATED BY DEFAULT AS IDENTITY (CACHE 1);
ALTER TABLE public.df_gen_trace ADD COLUMN IF NOT EXISTS observation JSONB;
CREATE OR REPLACE FUNCTION public.df_gen_mark(p_shape_id TEXT, p_path TEXT)
RETURNS INT
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog
AS $MARK$
    INSERT INTO public.df_gen_trace (shape_id, node_path, iteration)
    VALUES (p_shape_id, p_path,
        (SELECT COALESCE(MAX(iteration), 0) + 1 FROM public.df_gen_trace
         WHERE shape_id = p_shape_id AND node_path = p_path))
    RETURNING iteration;
$MARK$;
CREATE OR REPLACE FUNCTION public.df_gen_observe(p_shape_id TEXT, p_path TEXT, p_value JSONB)
RETURNS INT
LANGUAGE sql VOLATILE SECURITY INVOKER
SET search_path = pg_catalog
AS $OBSERVE$
    INSERT INTO public.df_gen_trace (shape_id, node_path, iteration, observation)
    VALUES (p_shape_id, p_path,
        (SELECT COALESCE(MAX(iteration), 0) + 1 FROM public.df_gen_trace
         WHERE shape_id = p_shape_id AND node_path = p_path), p_value)
    RETURNING iteration;
$OBSERVE$;
"""


def count_checks(case_id, expected, ground_truth=False):
    checks = []
    for path, count in sorted(expected.items()):
        observed = (
            "SELECT COUNT(*) FROM public.df_gen_trace "
            f"WHERE shape_id = '{case_id}' AND node_path = '{path}'"
        )
        checks.append(
            f"    IF ({observed}) <> {count} THEN\n"
            f"        RAISE EXCEPTION 'TEST FAILED [{case_id}]: "
            f"{'ground truth ' if ground_truth else ''}path {path} "
            f"expected {count}, got %', ({observed});\n"
            "    END IF;"
        )
    unexpected_filter = ""
    if expected:
        paths = ", ".join(f"'{path}'" for path in sorted(expected))
        unexpected_filter = f" AND (node_path IS NULL OR node_path NOT IN ({paths}))"
    checks.append(f"""
    SELECT string_agg(DISTINCT COALESCE(node_path, '<NULL>'), ', ') INTO unexpected
      FROM public.df_gen_trace
     WHERE shape_id = '{case_id}'{unexpected_filter};
    IF unexpected IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED [{case_id}]: unexpected path(s): %', unexpected;
    END IF;""")
    return "\n".join(checks)


def order_checks(case):
    checks = []
    for before, before_iter, after, after_iter in sorted(case.order):
        endpoints = [
            "SELECT COUNT(*) AS n, MIN(event_id) AS ordinal FROM public.df_gen_trace "
            f"WHERE shape_id = '{case.id}' AND node_path = '{path}' AND iteration = {iteration}"
            for path, iteration in ((before, before_iter), (after, after_iter))
        ]
        checks.append(f"""
    IF (SELECT a.n = 1 AND b.n = 1 AND a.ordinal < b.ordinal
        FROM ({endpoints[0]}) a CROSS JOIN ({endpoints[1]}) b) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: causal edge {before}[{before_iter}] -> {after}[{after_iter}]';
    END IF;""")
    return "\n".join(checks)


def observation_checks(case):
    checks = []
    keys = []
    for observation in sorted(case.expected, key=lambda value: (value["path"], value["iteration"])):
        path, iteration = observation["path"], observation["iteration"]
        predicate = f"node_path = '{path}' AND iteration = {iteration}"
        observed = f"FROM public.df_gen_trace WHERE shape_id = '{case.id}' AND {predicate}"
        keys.append(f"({predicate})")
        checks.append(f"""
    IF (SELECT COUNT(*) {observed}) <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: observation cardinality {path}[{iteration}]';
    END IF;
    IF (SELECT observation {observed}) IS DISTINCT FROM {json_literal(observation['value'])} THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: observation value {path}[{iteration}]';
    END IF;""")
    allowed = " OR ".join(keys) if keys else "FALSE"
    checks.append(f"""
    IF EXISTS (SELECT 1 FROM public.df_gen_trace WHERE shape_id = '{case.id}'
               AND ({allowed}) IS NOT TRUE) THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: unexpected observation';
    END IF;""")
    if case.has_result:
        checks.append(f"""
    IF df.result(inst_id)::jsonb IS DISTINCT FROM {json_literal(case.result)} THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: final result mismatch';
    END IF;""")
    if case.error is not None:
        # The worker can publish failed status before the runtime stores its output.
        checks.append(f"""
    FOR attempt IN 1..100 LOOP
        SELECT output INTO failure_output FROM df.instance_info(inst_id);
        EXIT WHEN failure_output IS NOT NULL;
        PERFORM pg_sleep(0.1);
    END LOOP;
    IF (strpos(failure_output, {literal(case.error)}) > 0) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: expected error substring missing: %', failure_output;
    END IF;""")
    return "\n".join(checks)


def start(dsl, tag):
    return f"""INSERT INTO _gen_state SELECT df.start(
    {dsl},
    '{tag}'
);
"""


def variables(values):
    return "".join(f"SELECT df.setvar({literal(name)}, {literal(value)});\n"
                   for name, value in sorted(values.items()))


def sql_test(case: Record) -> str:
    sql = f"""-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.
-- Fixed manifest case {case.id}; temporary E2E wrapper.

SET SESSION AUTHORIZATION df_e2e_user;

{FIXTURE}"""
    relation = isinstance(case, RelationCase)
    semantic = isinstance(case, SemanticCase)
    tags = [case.id + "-a", case.id + "-b"] if relation else [case.id]
    for tag in tags:
        sql += f"DELETE FROM public.df_gen_trace WHERE shape_id = '{tag}';\n"
    if semantic:
        sql += "SELECT df.clearvars();\n" + variables(case.vars)
    sql += "\nCREATE TEMP TABLE _gen_state (instance_id TEXT);\n"
    if relation:
        sql += start(case.dsl_a, tags[0]) + start(case.dsl_b, tags[1])
    else:
        sql += start(case.dsl, case.id)
    if semantic:
        sql += variables(case.post_start_vars) + "SELECT df.clearvars();\n"
        if case.release_signal is not None:
            sql += (
                f"SELECT df.signal(instance_id, {literal(case.release_signal)}, '{{}}') "
                "FROM _gen_state;\n"
            )
            # Early events can precede subscription registration (07_signals.sql).
            sql += f"""
DO $RELEASE$
DECLARE
    inst_id TEXT;
    release_deadline TIMESTAMPTZ := clock_timestamp() + INTERVAL '60 seconds';
BEGIN
    SELECT instance_id INTO inst_id FROM _gen_state;
    LOOP
        EXIT WHEN df.status(inst_id) IN ('completed', 'failed', 'cancelled');
        IF clock_timestamp() >= release_deadline THEN
            RAISE EXCEPTION 'TEST FAILED [{case.id}]: release signal timed out';
        END IF;
        PERFORM df.signal(inst_id, {literal(case.release_signal)}, '{{}}');
        PERFORM pg_sleep(LEAST(0.1, GREATEST(0,
            EXTRACT(EPOCH FROM release_deadline - clock_timestamp()))));
    END LOOP;
END $RELEASE$;
"""
    status = case.status if semantic else "completed"
    body = f"""DECLARE
    inst_id TEXT;
    status TEXT;
    statuses TEXT[] := ARRAY[]::TEXT[];
    unexpected TEXT;
    failure_output TEXT;
BEGIN
    FOR inst_id IN SELECT instance_id FROM _gen_state LOOP
        SELECT df.wait_for_completion(inst_id, 60) INTO status;
        statuses := array_append(statuses, status);
    END LOOP;
    FOREACH status IN ARRAY statuses LOOP
        IF status IS DISTINCT FROM '{status}' THEN
            RAISE EXCEPTION 'TEST FAILED [{case.id}]: status = %', status;
        END IF;
    END LOOP;
"""
    if relation:
        body += "\n".join(count_checks(tag, case.expected, ground_truth=True) for tag in tags)
        grouped = [
            "SELECT node_path, COUNT(*) FROM public.df_gen_trace "
            f"WHERE shape_id = '{tag}' GROUP BY node_path" for tag in tags
        ]
        body += f"""
    IF EXISTS (({grouped[0]}) EXCEPT ({grouped[1]}))
       OR EXISTS (({grouped[1]}) EXCEPT ({grouped[0]})) THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: relation multiset mismatch';
    END IF;
"""
    elif semantic:
        body += observation_checks(case)
    else:
        body += count_checks(case.id, case.expected) + order_checks(case)
    sql += "\n" + block(body) + "\n\n"
    if semantic:
        sql += "SELECT df.clearvars();\n"
    return sql + "DROP TABLE _gen_state;\nSELECT 'TEST PASSED' AS result;\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate the fixed corpus without PostgreSQL")
    mode.add_argument("--out", type=Path, help="write SQL wrappers into an existing empty directory")
    args = parser.parse_args()
    try:
        cases = load_manifest(args.manifest)
        if args.out is not None:
            if any(args.out.iterdir()):
                raise ValueError(f"output directory must be empty: {args.out}")
            for case in cases:
                with (args.out / f"{case.id}.sql").open("x", encoding="utf-8", newline="\n") as output:
                    output.write(sql_test(case))
        print(f"{'Validated' if args.check else 'Prepared'} {len(cases)} fixed manifest cases")
    except (OSError, ValueError) as error:
        parser.exit(1, f"matrix runner: {error}\n")


if __name__ == "__main__":
    main()
