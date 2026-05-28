-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: Startup validation rejects invalid GUC values
-- Requires: pg_durable.max_duroxide_connections = 1 (below minimum of 2)
-- Verifies that the background worker refuses to start when duroxide
-- connections are below the required minimum for the LISTEN/NOTIFY slot.

-- The worker should have logged the error message and exited.
-- The duroxide._worker_ready table should never appear (or have a valid row).
DO $$
DECLARE
    ready        BOOLEAN;
    table_exists BOOLEAN;
    attempts     INT := 0;
BEGIN
    -- Poll duroxide._worker_ready for up to 15 seconds — the worker should never become ready.
    LOOP
        SELECT EXISTS(
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'duroxide' AND table_name = '_worker_ready'
        ) INTO table_exists;

        IF table_exists THEN
            SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1) INTO ready;
        ELSE
            ready := FALSE;
        END IF;

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
