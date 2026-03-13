-- Test: df.break() outside a loop is rejected at graph construction time (df.start()).
-- Expected: df.start raises an error when df.break() appears outside df.loop().

DO $body$
BEGIN
    -- 1. Bare df.break() at the top level
    BEGIN
        PERFORM df.start(df.break());
        RAISE EXCEPTION 'TEST FAILED: bare df.break() at top level should have been rejected';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Case 1 OK - caught expected error: %', SQLERRM;
    END;

    -- 2. df.break() inside a sequence, outside any loop
    BEGIN
        PERFORM df.start('SELECT 1' ~> df.break() ~> 'SELECT 2');
        RAISE EXCEPTION 'TEST FAILED: df.break() in sequence without loop should have been rejected';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Case 2 OK - caught expected error: %', SQLERRM;
    END;

    -- 3. df.break() in the then-branch of a conditional, outside any loop
    BEGIN
        PERFORM df.start('SELECT true' ?> df.break() !> 'SELECT 1');
        RAISE EXCEPTION 'TEST FAILED: df.break() in conditional outside loop should have been rejected';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Case 3 OK - caught expected error: %', SQLERRM;
    END;

    RAISE NOTICE 'Cases 1-3 passed: df.break() outside loop correctly rejected';
END $body$;

-- 4. df.break() inside a df.loop() body is valid — should NOT raise.
--    Must be outside the DO block so df.start() commits and the background
--    worker can see the instance.
CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state SELECT df.start(
    df.loop(
        'SELECT 1' ~> df.break('{"done": true}')
    ),
    'break-in-loop-test'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: df.break() inside loop did not complete, status = %', status;
    END IF;

    RAISE NOTICE 'Case 4 OK - df.break() inside loop is valid and completed';
END $$;

DROP TABLE _test_state;

SELECT 'TEST PASSED' AS result;
