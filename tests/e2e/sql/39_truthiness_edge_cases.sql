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

-- Store test cases and instance IDs
CREATE TEMP TABLE _truth_cases (
    variant TEXT,
    condition_sql TEXT,
    expected TEXT,
    instance_id TEXT
);

INSERT INTO _truth_cases (variant, condition_sql, expected) VALUES
    ('null_val',    'SELECT NULL',          'falsy'),
    ('int_zero',    'SELECT 0',             'falsy'),
    ('int_one',     'SELECT 1',             'truthy'),
    ('bool_false',  'SELECT false',         'falsy'),
    ('bool_true',   'SELECT true',          'truthy'),
    -- [KNOWN QUIRK] Non-empty strings that are not "true"/"t"/"yes"/"1" and
    -- not parseable as non-zero integers: actual behavior is falsy.
    ('str_false',   'SELECT ''false''',     'falsy'),
    ('str_no',      'SELECT ''no''',        'falsy'),
    ('empty_str',   'SELECT ''''',          'falsy'),
    ('float_zero',  'SELECT 0.0',           'falsy'),
    ('empty_array', 'SELECT ''[]''::jsonb', 'falsy'),
    ('empty_obj',   'SELECT ''{}''::jsonb', 'falsy');

-- Start all loop instances at top level (auto-commits so background worker can see them)
UPDATE _truth_cases SET instance_id = df.start(
    df.loop(
        format('INSERT INTO test_truth_log (variant) VALUES (%L)', variant),
        condition_sql
    ),
    format('truth-%s', variant)
);

-- NOTE on known behavior quirks:
-- String "false" and "no" are treated as FALSY by is_truthy() — they are
-- recognized as falsy string values. The correct way to return a falsy condition
-- is `SELECT false` (boolean), `SELECT 0`, or string "false"/"no".

-- Poll each instance and determine truthy/falsy
DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
    got TEXT;
    attempts INT;
    failures INT := 0;
BEGIN
    FOR rec IN SELECT * FROM _truth_cases LOOP
        attempts := 0;

        -- Wait up to 10s for the loop to either stop on its own or run 2 iterations
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            SELECT COUNT(*) INTO cnt FROM test_truth_log WHERE variant = rec.variant;
            EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled')
                   OR cnt >= 2
                   OR attempts > 100;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;

        IF lower(status) IN ('completed', 'failed', 'canceled', 'cancelled') THEN
            -- Loop stopped by itself → condition was falsy
            got := 'falsy';
        ELSIF cnt >= 2 THEN
            -- Loop kept running beyond 1 iteration → condition is truthy; cancel it
            PERFORM df.cancel(rec.instance_id, 'truth-test-done');
            -- Wait for cancel to land
            attempts := 0;
            LOOP
                SELECT s INTO status FROM df.status(rec.instance_id) s;
                EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled', 'cancelled')
                       OR attempts > 50;
                PERFORM pg_sleep(0.1);
                attempts := attempts + 1;
            END LOOP;
            got := 'truthy';
        ELSE
            -- Timeout: instance did not start within 10s (worker busy or dead)
            PERFORM df.cancel(rec.instance_id, 'truth-test-timeout');
            RAISE EXCEPTION 'Timeout waiting for truth test [%] (status=%, cnt=%)', rec.variant, status, cnt;
        END IF;

        RAISE NOTICE 'Truthiness [%]: condition=% → %', rec.variant, rec.condition_sql, got;
        IF got != rec.expected THEN
            RAISE WARNING 'REGRESSION [%]: got % expected %', rec.variant, got, rec.expected;
            failures := failures + 1;
        END IF;
    END LOOP;

    -- Emit a clear notice about the known quirks so they are visible in test output
    RAISE NOTICE 'NOTE: SELECT ''false'' and SELECT ''no'' are falsy in loop conditions.';

    IF failures > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % truthiness regression(s) — see WARNINGs above', failures;
    END IF;
END $$;

DROP TABLE _truth_cases;
DROP TABLE test_truth_log;
SELECT 'TEST PASSED' AS result;
