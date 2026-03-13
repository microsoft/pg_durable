-- Test: Loop condition truthiness edge cases (B3)
-- Demonstrates: evaluate_condition / is_truthy behavior for ambiguous values
-- Expected: Documents and verifies the actual truthiness semantics for:
--   NULL, integer 0, float 0.0, empty string, string "false", string "no",
--   empty JSON array, empty JSON object

-- Each sub-test starts a df.loop(body, condition) and checks whether the loop
-- stops (condition is falsy) or runs at least 2 iterations before cancel
-- (condition is truthy).

DROP TABLE IF EXISTS test_truth_log;
CREATE TABLE test_truth_log (id SERIAL, variant TEXT, ts TIMESTAMP DEFAULT now());

-- Helper: run a loop with the given condition SQL, return 'truthy' or 'falsy'
-- based on whether the loop keeps running (truthy) or stops on its own.
CREATE OR REPLACE FUNCTION _run_truth_test(
    p_variant TEXT,
    p_condition_sql TEXT
) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    inst_id TEXT;
    status TEXT;
    cnt INT;
    attempts INT := 0;
BEGIN
    inst_id := df.start(
        df.loop(
            format('INSERT INTO test_truth_log (variant) VALUES (%L)', p_variant),
            p_condition_sql
        ),
        format('truth-%s', p_variant)
    );

    -- Wait up to 3s for the loop to either stop on its own or run 2 iterations
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        SELECT COUNT(*) INTO cnt FROM test_truth_log WHERE variant = p_variant;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled')
               OR cnt >= 2
               OR attempts > 30;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) IN ('completed', 'failed', 'canceled', 'cancelled') THEN
        -- Loop stopped by itself → condition was falsy
        RETURN 'falsy';
    ELSE
        -- Loop kept running → condition is truthy; cancel it
        PERFORM df.cancel(inst_id, 'truth-test-done');
        -- Wait for cancel to land
        attempts := 0;
        LOOP
            SELECT s INTO status FROM df.status(inst_id) s;
            EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled')
                   OR attempts > 50;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;
        RETURN 'truthy';
    END IF;
END $$;

-- NOTE on known behavior quirks:
-- String "false" and "no" are treated as TRUTHY by is_truthy() because they are
-- non-empty strings that don't parse as integers. A user writing
-- `df.loop(..., 'SELECT ''false''')` may expect the loop to stop but it will not.
-- The correct way to return a falsy condition is `SELECT false` (boolean) or `SELECT 0`.

DO $$
DECLARE
    -- Each entry: (variant, condition_sql, expected_actual_result)
    -- expected values reflect the CURRENT implementation behavior.
    -- Entries marked with [KNOWN QUIRK] behave differently than users may expect.
    cases TEXT[][] := ARRAY[
        ARRAY['null_val',    'SELECT NULL',          'falsy'],
        ARRAY['int_zero',    'SELECT 0',             'falsy'],
        ARRAY['int_one',     'SELECT 1',             'truthy'],
        ARRAY['bool_false',  'SELECT false',         'falsy'],
        ARRAY['bool_true',   'SELECT true',          'truthy'],
        -- [KNOWN QUIRK] Non-empty strings that are not "true"/"t"/"yes"/"1" and
        -- not parseable as non-zero integers fall through to !s.is_empty() = true.
        ARRAY['str_false',   'SELECT ''false''',     'truthy'],
        ARRAY['str_no',      'SELECT ''no''',        'truthy'],
        ARRAY['empty_str',   'SELECT ''''',          'falsy'],
        ARRAY['float_zero',  'SELECT 0.0',           'falsy'],
        ARRAY['empty_array', 'SELECT ''[]''::jsonb', 'falsy'],
        ARRAY['empty_obj',   'SELECT ''{}''::jsonb', 'falsy']
    ];
    rec TEXT[];
    got TEXT;
    expected TEXT;
    failures INT := 0;
BEGIN
    FOREACH rec SLICE 1 IN ARRAY cases LOOP
        got := _run_truth_test(rec[1], rec[2]);
        expected := rec[3];
        RAISE NOTICE 'Truthiness [%]: condition=% → %', rec[1], rec[2], got;
        IF got != expected THEN
            RAISE WARNING 'REGRESSION [%]: got % expected %', rec[1], got, expected;
            failures := failures + 1;
        END IF;
    END LOOP;

    -- Emit a clear notice about the known quirks so they are visible in test output
    RAISE NOTICE 'KNOWN QUIRK: SELECT ''false'' and SELECT ''no'' are truthy in loop conditions. '
        'Use SELECT false (boolean) or SELECT 0 to stop a loop.';

    IF failures > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % truthiness regression(s) — see WARNINGs above', failures;
    END IF;
END $$;

DROP FUNCTION _run_truth_test(TEXT, TEXT);
DROP TABLE test_truth_log;
SELECT 'TEST PASSED' AS result;
