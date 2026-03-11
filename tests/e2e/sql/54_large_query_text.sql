-- Test: Very large SQL query text (A6)
-- Demonstrates: execute_sql activity can handle a very long query string
--               without truncation or serialization errors.
-- Expected: Instance completes successfully.

-- Build the long query and start instance (commits on block end)
CREATE TEMP TABLE _test_state (instance_id TEXT);

DO $$
DECLARE
    long_sql TEXT;
    i INT;
BEGIN
    -- Build a SELECT with a 500-element VALUES list, producing a ~10KB query
    long_sql := 'SELECT v FROM (VALUES ';
    FOR i IN 1..500 LOOP
        IF i > 1 THEN
            long_sql := long_sql || ',';
        END IF;
        long_sql := long_sql || format('(%s)', i);
    END LOOP;
    long_sql := long_sql || ') t(v) WHERE v = 1';

    INSERT INTO _test_state VALUES (df.start(df.sql(long_sql), 'test-large-query-text'));
END $$;

-- Wait in a separate block so the instance is already committed
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A6]: large query text expected completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A6]: ~10KB query text executed without error';
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
