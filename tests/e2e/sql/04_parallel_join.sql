-- Test: Parallel execution with df.join() and & operator
-- Tests function and operator variants

DROP TABLE IF EXISTS test_parallel_log;
CREATE TABLE test_parallel_log (id SERIAL, branch TEXT, variant TEXT);

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Test A: df.join() function
INSERT INTO _test_state SELECT df.start(
    df.join(
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''func'')',
        'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''func'')'
    ),
    'test-parallel-func'
), 'func';

-- Test B: & operator
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_parallel_log (branch, variant) VALUES (''A'', ''op'')'
    & 'INSERT INTO test_parallel_log (branch, variant) VALUES (''B'', ''op'')',
    'test-parallel-op'
), 'op';

-- Wait and verify
DO $$
DECLARE
    rec RECORD;
    status TEXT;
    cnt INT;
BEGIN
    FOR rec IN SELECT instance_id, variant FROM _test_state LOOP
        SELECT df.wait_for_completion(rec.instance_id) INTO status;

        IF status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED [%]: status = %', rec.variant, status;
        END IF;

        SELECT COUNT(DISTINCT branch) INTO cnt FROM test_parallel_log WHERE variant = rec.variant;
        IF cnt != 2 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: expected 2 branches, got %', rec.variant, cnt;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASSED: parallel_join [func + & operator]';
END $$;

DROP TABLE _test_state;
DROP TABLE test_parallel_log;
SELECT 'TEST PASSED' AS result;
