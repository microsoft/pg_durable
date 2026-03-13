-- Test: Rapid start/cancel cycles (A7)
-- Demonstrates: Race between worker pickup and cancel signal;
--               verifies no instances are stuck after repeated start+cancel.
-- Expected: All instances end up in a terminal state (canceled, failed, or completed).

DROP TABLE IF EXISTS test_rapid_cancel_instances;
CREATE TABLE test_rapid_cancel_instances (id SERIAL, instance_id TEXT);

DO $$
DECLARE
    i INT;
    inst_id TEXT;
    total INT := 20;
BEGIN
    FOR i IN 1..total LOOP
        -- Start a slow instance, then immediately cancel it
        inst_id := df.start(df.sleep(60), 'rapid-cancel-' || i);
        INSERT INTO test_rapid_cancel_instances (instance_id) VALUES (inst_id);
        PERFORM df.cancel(inst_id, 'rapid-cancel-test');
    END LOOP;
    RAISE NOTICE 'Started and canceled % instances', total;
END $$;

-- Wait for all to settle into a terminal state
DO $$
DECLARE
    settled INT;
    attempts INT := 0;
    total INT := 20;
BEGIN
    LOOP
        SELECT COUNT(*) INTO settled
        FROM test_rapid_cancel_instances r
        JOIN df.instances i ON i.id = r.instance_id
        WHERE lower(i.status) IN ('completed', 'failed', 'canceled', 'cancelled');

        EXIT WHEN settled >= total OR attempts > 300;  -- 30s timeout
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF settled < total THEN
        RAISE EXCEPTION 'TEST FAILED [A7]: only %/% instances settled within timeout', settled, total;
    END IF;

    RAISE NOTICE 'PASSED [A7]: all % rapid-cancel instances settled', total;
END $$;

-- Verify no instances stuck
DO $$
DECLARE
    stuck INT;
BEGIN
    SELECT COUNT(*) INTO stuck
    FROM test_rapid_cancel_instances r
    JOIN df.instances i ON i.id = r.instance_id
    WHERE lower(i.status) IN ('pending', 'running');

    IF stuck > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [A7]: % instances stuck after rapid cancel', stuck;
    END IF;

    RAISE NOTICE 'PASSED [A7]: no instances stuck after rapid start/cancel';
END $$;

DROP TABLE test_rapid_cancel_instances;
SELECT 'TEST PASSED' AS result;
