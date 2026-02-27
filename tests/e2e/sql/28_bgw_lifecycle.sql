-- Test: Background worker lifecycle (wait for extension + detect drop)
--
-- Validates MVP behavior:
-- 1) With pg_durable preloaded but extension not created, BGW should not create duroxide schema.
-- 2) After CREATE EXTENSION, workflows execute.
-- 3) After DROP EXTENSION, duroxide schema is removed and BGW returns to waiting.
-- 4) After re-create, workflows execute again.

-- Ensure a clean starting point
DROP EXTENSION IF EXISTS pg_durable CASCADE;

-- 1) Verify BGW does not create duroxide schema pre-extension
DO $$
DECLARE
    exists_before BOOLEAN;
    exists_after BOOLEAN;
BEGIN
    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO exists_before;
    IF exists_before THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema exists before CREATE EXTENSION';
    END IF;

    -- Give BGW time to do the wrong thing (it should remain idle)
    PERFORM pg_sleep(6);

    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO exists_after;
    IF exists_after THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema was created before CREATE EXTENSION';
    END IF;

    RAISE NOTICE 'PASSED: BGW did not create duroxide schema pre-extension';
END $$;

-- 2) Create extension and run a simple workflow
CREATE EXTENSION pg_durable;

CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state
SELECT df.start('SELECT 42 as answer', 'test-bgw-lifecycle-1');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
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
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%42%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 42, got %', result;
    END IF;

    RAISE NOTICE 'PASSED: workflow completed after CREATE EXTENSION';
END $$;

DROP TABLE _test_state;

-- 3) Drop extension and verify schema removed
DROP EXTENSION pg_durable CASCADE;

DO $$
DECLARE
    schema_exists BOOLEAN;
BEGIN
    -- DDL is synchronous; schema should be gone immediately
    SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide') INTO schema_exists;
    IF schema_exists THEN
        RAISE EXCEPTION 'TEST FAILED: duroxide schema still exists after DROP EXTENSION';
    END IF;

    RAISE NOTICE 'PASSED: DROP EXTENSION removed duroxide schema';
END $$;

-- 4) Re-create extension and run another workflow
CREATE EXTENSION pg_durable;

CREATE TEMP TABLE _test_state2 (instance_id TEXT);
INSERT INTO _test_state2
SELECT df.start('SELECT 43 as answer', 'test-bgw-lifecycle-2');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state2;

    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed after recreate, got %', status;
    END IF;

    SELECT r INTO result FROM df.result(inst_id) r;
    IF result NOT LIKE '%43%' THEN
        RAISE EXCEPTION 'TEST FAILED: result should contain 43, got %', result;
    END IF;

    RAISE NOTICE 'PASSED: workflow completed after re-create';
END $$;

DROP TABLE _test_state2;
SELECT 'TEST PASSED' AS result;
