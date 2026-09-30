#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

"""Adapt the fixed manifest to the existing per-file SQL E2E harness."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re


MANIFEST = Path(__file__).with_name("manifest.json")


@dataclass(frozen=True)
class Case:
    id: str
    dsl: str
    expected: dict[str, int]


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_manifest(path: Path) -> list[Case]:
    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1:
        raise ValueError("manifest version must be 1")
    shapes = data.get("shapes")
    if not isinstance(shapes, list) or not shapes:
        raise ValueError("manifest shapes must be a nonempty array")
    if type(data.get("shape_count")) is not int or data["shape_count"] != len(shapes):
        raise ValueError("manifest shape_count does not match shapes")

    cases = []
    ids = set()
    for shape in shapes:
        if not isinstance(shape, dict):
            raise ValueError("each shape must be an object")
        shape_id = shape.get("id")
        if not isinstance(shape_id, str) or not re.fullmatch(r"gen-[0-9]{4,}", shape_id):
            raise ValueError(f"invalid shape id: {shape_id!r}")
        if shape_id in ids:
            raise ValueError(f"duplicate shape id: {shape_id}")
        ids.add(shape_id)
        dsl = shape.get("dsl")
        if not isinstance(dsl, str) or not dsl.strip():
            raise ValueError(f"{shape_id}: dsl must be a nonempty string")
        if shape.get("oracle") != "exact-marker-counts":
            raise ValueError(f"{shape_id}: unsupported oracle")
        expected = shape.get("expected")
        if not isinstance(expected, dict):
            raise ValueError(f"{shape_id}: expected must be an object")
        for node_path, count in expected.items():
            if not re.fullmatch(r"r(?:\.[a-z0-9]+)*", node_path):
                raise ValueError(f"{shape_id}: invalid marker path: {node_path!r}")
            if type(count) is not int or not 0 <= count <= 2**63 - 1:
                raise ValueError(f"{shape_id}: {node_path}: count must be a nonnegative bigint")
        cases.append(Case(shape_id, dsl, expected))
    return cases


def sql_test(case: Case) -> str:
    checks = []
    for path, count in sorted(case.expected.items()):
        observed = (
            "SELECT COUNT(*) FROM public.df_gen_trace "
            f"WHERE shape_id = '{case.id}' AND node_path = '{path}'"
        )
        checks.append(
            f"    IF ({observed}) <> {count} THEN\n"
            f"        RAISE EXCEPTION 'TEST FAILED [{case.id}]: path {path} "
            f"expected {count}, got %', ({observed});\n"
            "    END IF;"
        )
    unexpected_filter = ""
    if case.expected:
        paths = ", ".join(f"'{path}'" for path in sorted(case.expected))
        unexpected_filter = f" AND (node_path IS NULL OR node_path NOT IN ({paths}))"

    return f"""-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.
-- Fixed manifest case {case.id}; temporary E2E wrapper.

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TABLE IF NOT EXISTS public.df_gen_trace (shape_id TEXT, node_path TEXT, iteration INT);
ALTER TABLE public.df_gen_trace ADD COLUMN IF NOT EXISTS shape_id TEXT;
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
DELETE FROM public.df_gen_trace WHERE shape_id = '{case.id}';

CREATE TEMP TABLE _gen_state (instance_id TEXT);
INSERT INTO _gen_state SELECT df.start(
    {case.dsl},
    '{case.id}'
);

DO $GEN$
DECLARE
    inst_id TEXT;
    status TEXT;
    unexpected TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _gen_state;
    SELECT df.wait_for_completion(inst_id, 60) INTO status;
    IF status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: status = %', status;
    END IF;

{chr(10).join(checks)}

    SELECT string_agg(DISTINCT COALESCE(node_path, '<NULL>'), ', ') INTO unexpected
      FROM public.df_gen_trace
     WHERE shape_id = '{case.id}'{unexpected_filter};
    IF unexpected IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED [{case.id}]: unexpected path(s): %', unexpected;
    END IF;
END $GEN$;

DROP TABLE _gen_state;
SELECT 'TEST PASSED' AS result;
"""


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
