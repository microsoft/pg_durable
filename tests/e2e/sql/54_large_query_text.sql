-- Test: Very large SQL query text (A6)
-- Demonstrates: execute_sql activity can handle a very long query string
--               without truncation or serialization errors.
-- Expected: Instance completes successfully.

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
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

    inst_id := df.start(df.sql(long_sql), 'test-large-query-text');

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [A6]: large query text expected completed, got %', status;
    END IF;

    RAISE NOTICE 'PASSED [A6]: ~10KB query text executed without error';
END $$;

SELECT 'TEST PASSED' AS result;
