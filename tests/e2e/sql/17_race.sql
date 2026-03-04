-- Test: Race execution with df.race() and | operator
-- Tests function and operator variants
-- Expected: First to complete wins

DROP TABLE IF EXISTS test_race_log;
CREATE TABLE test_race_log (id SERIAL, branch TEXT, variant TEXT, ts TIMESTAMP DEFAULT now());

CREATE TEMP TABLE _test_state (instance_id TEXT, variant TEXT);

-- Test A: df.race() function - fast vs slow
INSERT INTO _test_state SELECT df.start(
    df.race(
        'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''func'') RETURNING ''fast''',
        df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''func'') RETURNING ''slow'''
    ),
    'test-race-func'
), 'func';

-- Test B: | operator - fast vs slow
INSERT INTO _test_state SELECT df.start(
    'INSERT INTO test_race_log (branch, variant) VALUES (''fast'', ''op'') RETURNING ''fast'''
    | (df.sleep(10) ~> 'INSERT INTO test_race_log (branch, variant) VALUES (''slow'', ''op'') RETURNING ''slow'''),
    'test-race-op'
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

        -- Only the fast branch should have completed
        SELECT COUNT(*) INTO cnt FROM test_race_log WHERE variant = rec.variant AND branch = 'fast';
        IF cnt < 1 THEN
            RAISE EXCEPTION 'TEST FAILED [%]: fast branch should have completed', rec.variant;
        END IF;
    END LOOP;

    RAISE NOTICE 'PASSED: race [func + | operator]';
END $$;

DROP TABLE _test_state;
DROP TABLE test_race_log;
SELECT 'TEST PASSED' AS result;

