-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.join / df.join3 return a proper JSON array of objects, not an array of
-- escaped JSON strings (double-encoding bug regression test).
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: df.join (2-branch) result is a JSON array of objects ===

CREATE TEMP TABLE _t_join2 (instance_id TEXT);
INSERT INTO _t_join2 SELECT df.start(
    'SELECT 1 AS a' & 'SELECT 2 AS b',
    'test-join2-result-shape'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    raw_res  JSONB;
    elem0    JSONB;
    elem1    JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_join2;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: status = %', status;
    END IF;

    -- df.result returns the root node result as text; cast to JSONB to navigate it
    raw_res := (df.result(inst_id))::jsonb;

    -- Must be a JSON array
    IF jsonb_typeof(raw_res) != 'array' THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: expected array, got % — raw=%',
            jsonb_typeof(raw_res), raw_res;
    END IF;

    -- Array must have 2 elements
    IF jsonb_array_length(raw_res) != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: expected 2 elements, got % — raw=%',
            jsonb_array_length(raw_res), raw_res;
    END IF;

    -- Each element must be an object (not a string i.e. not double-encoded)
    elem0 := raw_res->0;
    elem1 := raw_res->1;

    IF jsonb_typeof(elem0) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: element 0 is %, expected object — raw=%',
            jsonb_typeof(elem0), raw_res;
    END IF;

    IF jsonb_typeof(elem1) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: element 1 is %, expected object — raw=%',
            jsonb_typeof(elem1), raw_res;
    END IF;

    -- Verify actual content (guards against regression producing empty objects)
    IF (elem0->>'a')::int != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: element 0.a expected 1, got % — raw=%',
            elem0->>'a', raw_res;
    END IF;

    IF (elem1->>'b')::int != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join2-shape]: element 1.b expected 2, got % — raw=%',
            elem1->>'b', raw_res;
    END IF;

    RAISE NOTICE 'PASSED: df.join result is a JSON array of objects';
END $$;

DROP TABLE _t_join2;

-- === Test 2: df.join3 (3-branch) result is a JSON array of objects ===

CREATE TEMP TABLE _t_join3 (instance_id TEXT);
INSERT INTO _t_join3 SELECT df.start(
    df.join3('SELECT 10 AS x', 'SELECT 20 AS y', 'SELECT 30 AS z'),
    'test-join3-result-shape'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    raw_res  JSONB;
    elem0    JSONB;
    elem1    JSONB;
    elem2    JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_join3;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: status = %', status;
    END IF;

    raw_res := (df.result(inst_id))::jsonb;

    -- Must be a JSON array
    IF jsonb_typeof(raw_res) != 'array' THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: expected array, got % — raw=%',
            jsonb_typeof(raw_res), raw_res;
    END IF;

    -- Array must have 3 elements
    IF jsonb_array_length(raw_res) != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: expected 3 elements, got % — raw=%',
            jsonb_array_length(raw_res), raw_res;
    END IF;

    -- Each element must be an object (not a string)
    elem0 := raw_res->0;
    elem1 := raw_res->1;
    elem2 := raw_res->2;

    IF jsonb_typeof(elem0) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: element 0 is %, expected object — raw=%',
            jsonb_typeof(elem0), raw_res;
    END IF;

    IF jsonb_typeof(elem1) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: element 1 is %, expected object — raw=%',
            jsonb_typeof(elem1), raw_res;
    END IF;

    IF jsonb_typeof(elem2) != 'object' THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: element 2 is %, expected object — raw=%',
            jsonb_typeof(elem2), raw_res;
    END IF;

    -- Verify actual content
    IF (elem0->>'x')::int != 10 OR (elem1->>'y')::int != 20 OR (elem2->>'z')::int != 30 THEN
        RAISE EXCEPTION 'TEST FAILED [join3-shape]: values mismatch — raw=%', raw_res;
    END IF;

    RAISE NOTICE 'PASSED: df.join3 result is a JSON array of objects';
END $$;

DROP TABLE _t_join3;

-- === Test 3: nested join — (a & b) & c — inner array must nest inside outer ===

CREATE TEMP TABLE _t_nested (instance_id TEXT);
INSERT INTO _t_nested SELECT df.start(
    ('SELECT 1 AS a' & 'SELECT 2 AS b') & 'SELECT 3 AS c',
    'test-join-nested-shape'
);

DO $$
DECLARE
    inst_id  TEXT;
    status   TEXT;
    raw_res  JSONB;
    inner_arr JSONB;
    outer_c  JSONB;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_nested;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: status = %', status;
    END IF;

    raw_res := (df.result(inst_id))::jsonb;

    -- Outer must be a 2-element array: [ [inner_a, inner_b], c_obj ]
    IF jsonb_typeof(raw_res) != 'array' OR jsonb_array_length(raw_res) != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: expected 2-element array, got % len=% — raw=%',
            jsonb_typeof(raw_res), jsonb_array_length(raw_res), raw_res;
    END IF;

    -- First element is the inner join result: must itself be an array, not a string
    inner_arr := raw_res->0;
    IF jsonb_typeof(inner_arr) != 'array' THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: inner element type is %, expected array (double-encoding regression) — raw=%',
            jsonb_typeof(inner_arr), raw_res;
    END IF;

    IF jsonb_array_length(inner_arr) != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: inner array length expected 2, got % — raw=%',
            jsonb_array_length(inner_arr), raw_res;
    END IF;

    IF (inner_arr->0->>'a')::int != 1 OR (inner_arr->1->>'b')::int != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: inner values mismatch — raw=%', raw_res;
    END IF;

    -- Second element is the c branch result (an object)
    outer_c := raw_res->1;
    IF jsonb_typeof(outer_c) != 'object' OR (outer_c->>'c')::int != 3 THEN
        RAISE EXCEPTION 'TEST FAILED [join-nested-shape]: outer.c element wrong — raw=%', raw_res;
    END IF;

    RAISE NOTICE 'PASSED: nested join result preserves array nesting (no double-encoding)';
END $$;

DROP TABLE _t_nested;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
