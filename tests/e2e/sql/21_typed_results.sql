-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: Typed column result serialization (numeric, uuid, timestamptz, timestamp, date, jsonb,
--        int2, float4, float8, NULL handling, unsupported-type error, NaN/Inf error).
--
-- Each SELECT query runs through execute_sql, which must encode each PostgreSQL type
-- into the result JSON correctly.  Tests verify the encoded JSON by reading the
-- raw result JSONB from df.nodes.
--
-- Pattern: df.start() must be called in a standalone statement (auto-committed) so the
-- background worker can read the new instance.  A DO block then polls for completion.

SET SESSION AUTHORIZATION df_e2e_user;

-- ===========================================================================
-- Test 1: numeric/decimal → JSON string (preserves scale)
-- ===========================================================================

CREATE TEMP TABLE _t1 (instance_id TEXT);
INSERT INTO _t1 SELECT df.start(
    df.as('SELECT 123456.78900000::numeric AS val', 'r'),
    'test-typed-numeric'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_str TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t1;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-numeric]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    -- numeric must be a JSON string, not null and not a bare number
    val_str := raw_res->'rows'->0->>'val';

    IF val_str IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-numeric]: numeric encoded as null. raw=%', raw_res;
    END IF;
    -- Must start with "123456"
    IF val_str NOT LIKE '123456%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-numeric]: unexpected value %. raw=%', val_str, raw_res;
    END IF;
    -- Must be a JSON string (i.e., NOT a bare JSON number) — raw JSON must quote it
    -- A JSON string looks like: "val":"123456..." whereas a number looks like "val":123456
    IF raw_res::text LIKE '%"val":1%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-numeric]: numeric stored as JSON number, expected string. raw=%', raw_res;
    END IF;

    RAISE NOTICE 'PASSED: numeric → JSON string (%)', val_str;
END $$;

DROP TABLE _t1;

-- ===========================================================================
-- Test 2: uuid → JSON string (canonical form)
-- ===========================================================================

CREATE TEMP TABLE _t2 (instance_id TEXT);
INSERT INTO _t2 SELECT df.start(
    df.as($$SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS val$$, 'r'),
    'test-typed-uuid'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_str TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t2;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-uuid]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    val_str := raw_res->'rows'->0->>'val';

    IF val_str IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-uuid]: uuid encoded as null. raw=%', raw_res;
    END IF;
    IF val_str != 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-uuid]: expected canonical uuid, got %. raw=%', val_str, raw_res;
    END IF;

    RAISE NOTICE 'PASSED: uuid → JSON string (%)', val_str;
END $$;

DROP TABLE _t2;

-- ===========================================================================
-- Test 3: timestamptz → JSON string (RFC3339)
-- ===========================================================================

CREATE TEMP TABLE _t3 (instance_id TEXT);
INSERT INTO _t3 SELECT df.start(
    df.as($$SELECT '2024-06-15 12:30:00+00'::timestamptz AS val$$, 'r'),
    'test-typed-tstz'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_str TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t3;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-tstz]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    val_str := raw_res->'rows'->0->>'val';

    IF val_str IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-tstz]: timestamptz encoded as null. raw=%', raw_res;
    END IF;
    -- RFC3339: must contain 'T' separator and start with expected date
    IF val_str NOT LIKE '2024-06-15T%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-tstz]: expected RFC3339 starting 2024-06-15T, got %. raw=%', val_str, raw_res;
    END IF;

    RAISE NOTICE 'PASSED: timestamptz → RFC3339 string (%)', val_str;
END $$;

DROP TABLE _t3;

-- ===========================================================================
-- Test 4: timestamp (no timezone) → JSON string
-- ===========================================================================

CREATE TEMP TABLE _t4 (instance_id TEXT);
INSERT INTO _t4 SELECT df.start(
    df.as($$SELECT '2024-06-15 12:30:00'::timestamp AS val$$, 'r'),
    'test-typed-ts'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_str TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t4;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-ts]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    val_str := raw_res->'rows'->0->>'val';

    IF val_str IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-ts]: timestamp encoded as null. raw=%', raw_res;
    END IF;
    IF val_str NOT LIKE '2024-06-15T%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-ts]: expected timestamp string starting 2024-06-15T, got %. raw=%', val_str, raw_res;
    END IF;

    RAISE NOTICE 'PASSED: timestamp → JSON string (%)', val_str;
END $$;

DROP TABLE _t4;

-- ===========================================================================
-- Test 5: date → JSON string (YYYY-MM-DD)
-- ===========================================================================

CREATE TEMP TABLE _t5 (instance_id TEXT);
INSERT INTO _t5 SELECT df.start(
    df.as($$SELECT '2024-06-15'::date AS val$$, 'r'),
    'test-typed-date'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_str TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t5;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-date]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    val_str := raw_res->'rows'->0->>'val';

    IF val_str IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-date]: date encoded as null. raw=%', raw_res;
    END IF;
    IF val_str != '2024-06-15' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-date]: expected 2024-06-15, got %. raw=%', val_str, raw_res;
    END IF;

    RAISE NOTICE 'PASSED: date → JSON string (%)', val_str;
END $$;

DROP TABLE _t5;

-- ===========================================================================
-- Test 6: jsonb → native JSON value (not double-encoded as string)
-- ===========================================================================

CREATE TEMP TABLE _t6 (instance_id TEXT);
INSERT INTO _t6 SELECT df.start(
    df.as($$SELECT '{"key":"world","count":42}'::jsonb AS val$$, 'r'),
    'test-typed-jsonb'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_obj JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t6;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-jsonb]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    -- jsonb should be a nested JSON object, not a JSON string (double-encoded)
    val_obj := raw_res->'rows'->0->'val';

    IF val_obj IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-jsonb]: jsonb encoded as null. raw=%', raw_res;
    END IF;
    -- Must be a JSON object (jsonb_typeof returns 'object'), not a string
    IF jsonb_typeof(val_obj) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-jsonb]: expected object type, got %. raw=%', jsonb_typeof(val_obj), raw_res;
    END IF;
    IF val_obj->>'key' != 'world' OR (val_obj->>'count')::int != 42 THEN
        RAISE EXCEPTION 'TEST FAILED [typed-jsonb]: unexpected object contents. raw=%', raw_res;
    END IF;

    RAISE NOTICE 'PASSED: jsonb → native JSON object';
END $$;

DROP TABLE _t6;

-- ===========================================================================
-- Test 7: int2 (smallint) → JSON integer
-- ===========================================================================

CREATE TEMP TABLE _t7 (instance_id TEXT);
INSERT INTO _t7 SELECT df.start(
    df.as($$SELECT 32767::smallint AS val$$, 'r'),
    'test-typed-int2'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    val_n   JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t7;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-int2]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    val_n := raw_res->'rows'->0->'val';

    IF val_n IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-int2]: int2 encoded as null. raw=%', raw_res;
    END IF;
    IF jsonb_typeof(val_n) != 'number' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-int2]: expected number type, got %. raw=%', jsonb_typeof(val_n), raw_res;
    END IF;
    IF (val_n::text)::int != 32767 THEN
        RAISE EXCEPTION 'TEST FAILED [typed-int2]: expected 32767, got %. raw=%', val_n, raw_res;
    END IF;

    RAISE NOTICE 'PASSED: int2 → JSON integer (%)', val_n;
END $$;

DROP TABLE _t7;

-- ===========================================================================
-- Test 8: float4 / float8 → JSON number
-- ===========================================================================

CREATE TEMP TABLE _t8 (instance_id TEXT);
INSERT INTO _t8 SELECT df.start(
    df.as($$SELECT 3.14::float4 AS f4, 2.718281828::float8 AS f8$$, 'r'),
    'test-typed-float'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    f4_val  JSONB;
    f8_val  JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t8;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-float]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    f4_val := raw_res->'rows'->0->'f4';
    f8_val := raw_res->'rows'->0->'f8';

    IF f4_val IS NULL OR f8_val IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [typed-float]: float encoded as null. raw=%', raw_res;
    END IF;
    IF jsonb_typeof(f4_val) != 'number' OR jsonb_typeof(f8_val) != 'number' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-float]: expected number type, got f4=%, f8=%. raw=%',
            jsonb_typeof(f4_val), jsonb_typeof(f8_val), raw_res;
    END IF;

    RAISE NOTICE 'PASSED: float4/float8 → JSON number (f4=%, f8=%)', f4_val, f8_val;
END $$;

DROP TABLE _t8;

-- ===========================================================================
-- Test 9: SQL NULL → JSON null for typed columns
-- ===========================================================================

CREATE TEMP TABLE _t9 (instance_id TEXT);
INSERT INTO _t9 SELECT df.start(
    df.as($$SELECT NULL::numeric AS n, NULL::uuid AS u,
                  NULL::timestamptz AS ts, NULL::jsonb AS j$$, 'r'),
    'test-typed-null'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    raw_res JSONB;
    row0    JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t9;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-null]: status=%', status;
    END IF;

    SELECT result INTO raw_res FROM df.nodes
    WHERE instance_id = inst_id AND result_name = 'r' AND node_type = 'SQL';

    row0 := raw_res->'rows'->0;

    -- Each NULL column must appear as JSON null (key present, value null)
    IF NOT (row0 ? 'n' AND row0->'n' = 'null'::jsonb) THEN
        RAISE EXCEPTION 'TEST FAILED [typed-null]: NULL numeric not null in JSON: row=%', row0;
    END IF;
    IF NOT (row0 ? 'u' AND row0->'u' = 'null'::jsonb) THEN
        RAISE EXCEPTION 'TEST FAILED [typed-null]: NULL uuid not null in JSON: row=%', row0;
    END IF;
    IF NOT (row0 ? 'ts' AND row0->'ts' = 'null'::jsonb) THEN
        RAISE EXCEPTION 'TEST FAILED [typed-null]: NULL timestamptz not null in JSON: row=%', row0;
    END IF;
    IF NOT (row0 ? 'j' AND row0->'j' = 'null'::jsonb) THEN
        RAISE EXCEPTION 'TEST FAILED [typed-null]: NULL jsonb not null in JSON: row=%', row0;
    END IF;

    RAISE NOTICE 'PASSED: SQL NULL → JSON null';
END $$;

DROP TABLE _t9;

-- ===========================================================================
-- Test 10: unsupported type (bytea) → workflow fails loudly (no silent null)
-- ===========================================================================

CREATE TEMP TABLE _t10 (instance_id TEXT);
INSERT INTO _t10 SELECT df.start(
    $$SELECT 'hello'::bytea AS b$$,
    'test-typed-unsupported'
);

DO $$
DECLARE
    inst_id    TEXT;
    wf_status  TEXT;
    node_error TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t10;
    SELECT df.wait_for_completion(inst_id) INTO wf_status;

    IF wf_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-unsupported]: expected failed, got %', wf_status;
    END IF;

    SELECT error INTO node_error FROM df.nodes
    WHERE instance_id = inst_id AND df.nodes.status = 'failed' LIMIT 1;

    IF node_error NOT LIKE '%Unsupported column type%' AND node_error NOT LIKE '%unsupported%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-unsupported]: expected unsupported-type error, got: %', node_error;
    END IF;

    RAISE NOTICE 'PASSED: unsupported type (bytea) → explicit error';
END $$;

DROP TABLE _t10;

-- ===========================================================================
-- Test 11: NaN float → workflow fails loudly
-- ===========================================================================

CREATE TEMP TABLE _t11 (instance_id TEXT);
INSERT INTO _t11 SELECT df.start(
    $$SELECT 'NaN'::float8 AS v$$,
    'test-typed-nan'
);

DO $$
DECLARE
    inst_id    TEXT;
    wf_status  TEXT;
    node_error TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t11;
    SELECT df.wait_for_completion(inst_id) INTO wf_status;

    IF wf_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-nan]: expected failed, got %', wf_status;
    END IF;

    SELECT error INTO node_error FROM df.nodes
    WHERE instance_id = inst_id AND df.nodes.status = 'failed' LIMIT 1;

    IF node_error NOT LIKE '%non-finite%' AND node_error NOT LIKE '%NaN%' AND node_error NOT LIKE '%Inf%' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-nan]: expected NaN/Inf error, got: %', node_error;
    END IF;

    RAISE NOTICE 'PASSED: NaN float → explicit error';
END $$;

DROP TABLE _t11;

-- ===========================================================================
-- Test 12: End-to-end — numeric round-trip through variable substitution
-- Confirms: SELECT → result JSON (as string) → $var substitution → INSERT
-- ===========================================================================

DROP TABLE IF EXISTS test_typed_roundtrip;
CREATE TABLE test_typed_roundtrip (id SERIAL, val NUMERIC(20, 8));
INSERT INTO test_typed_roundtrip (val) VALUES (9876543.12345678);

CREATE TEMP TABLE _t12 (instance_id TEXT);
INSERT INTO _t12 SELECT df.start(
    $$SELECT val FROM test_typed_roundtrip ORDER BY id LIMIT 1$$ |=> 'n'
    ~> $$INSERT INTO test_typed_roundtrip (val) SELECT $n::numeric$$,
    'test-typed-roundtrip'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    stored  NUMERIC;
BEGIN
    SELECT instance_id INTO inst_id FROM _t12;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [typed-roundtrip]: status=%', status;
    END IF;

    SELECT val INTO stored FROM test_typed_roundtrip ORDER BY id DESC LIMIT 1;

    IF stored IS NULL OR stored != 9876543.12345678 THEN
        RAISE EXCEPTION 'TEST FAILED [typed-roundtrip]: expected 9876543.12345678, got %', stored;
    END IF;

    RAISE NOTICE 'PASSED: numeric end-to-end round-trip (%)', stored;
END $$;

DROP TABLE _t12;
DROP TABLE test_typed_roundtrip;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
