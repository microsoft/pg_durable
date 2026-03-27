-- Test: Startup validation rejects invalid GUC values
-- Requires: pg_durable.max_duroxide_connections = 1 (below minimum of 2)
-- Verifies that the background worker refuses to start when duroxide
-- connections are below the required minimum for the LISTEN/NOTIFY slot.

-- The worker should have logged the error message and exited.
-- df.is_ready() should never return true.
DO $$
DECLARE
    ready BOOLEAN;
    attempts INT := 0;
BEGIN
    -- Poll df.is_ready() for up to 15 seconds — the worker should never become ready.
    LOOP
        SELECT df.is_ready() INTO ready;
        EXIT WHEN ready OR attempts >= 30;
        PERFORM pg_sleep(0.5);
        attempts := attempts + 1;
    END LOOP;

    IF ready THEN
        RAISE EXCEPTION 'TEST FAILED: worker became ready despite invalid max_duroxide_connections=1';
    END IF;

    RAISE NOTICE 'PASSED: worker did not become ready (refused to start as expected)';
END $$;

SELECT 'TEST PASSED' AS result;
