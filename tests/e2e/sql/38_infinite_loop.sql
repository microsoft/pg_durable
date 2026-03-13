-- Test: Infinite loop cancellation (B1 / B2)
-- Demonstrates: df.loop() with always-true condition and unconditional loop
-- Expected:
--   - Loops run indefinitely; df.cancel() successfully stops them
--   - Instance ends in canceled/failed state, not stuck in running

DROP TABLE IF EXISTS test_infinite_log;
CREATE TABLE test_infinite_log (id SERIAL, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _inf_state (instance_id TEXT, variant TEXT);

-- B1: always-true while-condition loop
INSERT INTO _inf_state
SELECT df.start(
    df.loop(
        'INSERT INTO test_infinite_log (variant) VALUES (''while_true'')',
        'SELECT true'   -- condition never becomes false
    ),
    'test-infinite-while-true'
), 'while_true';

-- B2: unconditional loop (no condition argument)
INSERT INTO _inf_state
SELECT df.start(
    df.loop(
        'INSERT INTO test_infinite_log (variant) VALUES (''unconditional'')'
    ),
    'test-infinite-unconditional'
), 'unconditional';

DO $$
DECLARE
    rec RECORD;
    cnt INT;
    status TEXT;
    attempts INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _inf_state LOOP
        RAISE NOTICE 'Testing infinite loop [%]: %', rec.variant, rec.instance_id;

        -- Wait for at least 2 iterations to prove the loop is actually running
        attempts := 0;
        LOOP
            SELECT COUNT(*) INTO cnt FROM test_infinite_log WHERE variant = rec.variant;
            EXIT WHEN cnt >= 2 OR attempts > 200;
            PERFORM pg_sleep(0.1);
            attempts := attempts + 1;
        END LOOP;

        IF cnt < 2 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected >= 2 iterations before cancel, got %',
                rec.variant, cnt;
        END IF;

        -- Cancel the running loop
        PERFORM df.cancel(rec.instance_id, 'test-cancel');

        -- Wait for cancellation to take effect
        attempts := 0;
        LOOP
            SELECT s INTO status FROM df.status(rec.instance_id) s;
            EXIT WHEN lower(status) IN ('canceled', 'cancelled', 'failed') OR attempts > 100;
            PERFORM pg_sleep(0.2);
            attempts := attempts + 1;
        END LOOP;

        IF lower(status) NOT IN ('canceled', 'cancelled', 'failed') THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected canceled/failed after cancel, got %',
                rec.variant, status;
        END IF;

        RAISE NOTICE 'PASSED [%]: ran % iterations, then canceled (status=%)',
            rec.variant, cnt, status;
    END LOOP;
END $$;

DROP TABLE _inf_state;
DROP TABLE test_infinite_log;
SELECT 'TEST PASSED' AS result;
