-- Test: Many concurrent instances (A1)
-- Demonstrates: Background worker handles a burst of simultaneous instances
-- Expected: All 20 instances complete within 60 seconds; none stuck in pending/running

DROP TABLE IF EXISTS test_burst_instances;
CREATE TABLE test_burst_instances (id SERIAL, instance_id TEXT);

DO $$
DECLARE
    i INT;
    inst_id TEXT;
    total INT := 20;
BEGIN
    FOR i IN 1..total LOOP
        inst_id := df.start(df.sql('SELECT 1'), 'burst-' || i);
        INSERT INTO test_burst_instances (instance_id) VALUES (inst_id);
    END LOOP;
    RAISE NOTICE 'Started % instances', total;
END $$;

-- Wait for all burst instances to complete
DO $$
DECLARE
    completed_count INT;
    attempts INT := 0;
    total INT := 20;
BEGIN
    LOOP
        SELECT COUNT(*) INTO completed_count
        FROM test_burst_instances b
        JOIN df.instances i ON i.id = b.instance_id
        WHERE lower(i.status) IN ('completed', 'failed', 'canceled');

        EXIT WHEN completed_count >= total OR attempts > 600;  -- 60s timeout
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF completed_count < total THEN
        RAISE EXCEPTION 'TEST FAILED [A1]: only %/% instances completed within timeout', completed_count, total;
    END IF;

    RAISE NOTICE 'PASSED [A1]: all % concurrent instances completed', total;
END $$;

-- Verify no instances are stuck in pending or running
DO $$
DECLARE
    stuck_count INT;
BEGIN
    SELECT COUNT(*) INTO stuck_count
    FROM test_burst_instances b
    JOIN df.instances i ON i.id = b.instance_id
    WHERE lower(i.status) IN ('pending', 'running');

    IF stuck_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [A1]: % instances stuck in pending/running', stuck_count;
    END IF;

    RAISE NOTICE 'PASSED [A1]: no instances stuck after burst';
END $$;

DROP TABLE test_burst_instances;
SELECT 'TEST PASSED' AS result;
