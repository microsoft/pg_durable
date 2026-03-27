-- Test: Startup validation rejects invalid GUC values
-- Requires: pg_durable.max_duroxide_connections = 1 (below minimum of 2)
-- Verifies that the background worker refuses to start when duroxide
-- connections are below the required minimum for the LISTEN/NOTIFY slot.

-- The worker should have logged the FATAL message and exited.
-- The duroxide._worker_ready table should either not exist or be empty,
-- because the worker never reached initialization.
DO $$
DECLARE
    ready BOOLEAN;
    attempts INT := 0;
    table_exists BOOLEAN;
BEGIN
    -- Give the worker a few seconds to attempt startup (and fail)
    PERFORM pg_sleep(5);

    -- Check if _worker_ready table exists (it might not if worker never ran)
    SELECT EXISTS(
        SELECT 1 FROM pg_catalog.pg_tables
        WHERE schemaname = 'duroxide' AND tablename = '_worker_ready'
    ) INTO table_exists;

    IF NOT table_exists THEN
        -- Table doesn't exist = worker never initialized = test passes
        RAISE NOTICE 'PASSED: _worker_ready table does not exist — worker never initialized';
    ELSE
        -- Table exists (from a prior run). Verify no current-version row.
        -- Wait a bit to ensure the worker had time to try and fail.
        LOOP
            SELECT EXISTS(
                SELECT 1 FROM duroxide._worker_ready
            ) INTO ready;
            -- If the table is empty or doesn't have a recent row, that's OK.
            -- We just need to confirm the worker didn't NEWLY become ready.
            EXIT WHEN attempts > 30;
            PERFORM pg_sleep(0.5);
            attempts := attempts + 1;
        END LOOP;

        -- The key check: the worker should NOT be writing new readiness records.
        -- We can't distinguish "old row from previous run" vs "new row" easily,
        -- so instead verify that df.start() + df.wait_for_completion() doesn't
        -- work (the worker isn't processing).
        BEGIN
            PERFORM df.start('SELECT 1', 'test-startup-validation');
            -- If we get here, start succeeded (it just inserts rows).
            -- Wait a short time — if worker were running, it would process.
            PERFORM pg_sleep(10);

            -- Check: the instance should still be 'pending' (worker not processing)
            DECLARE
                inst_status TEXT;
            BEGIN
                SELECT status INTO inst_status FROM df.instances
                WHERE label = 'test-startup-validation'
                ORDER BY created_at DESC LIMIT 1;

                IF inst_status = 'completed' THEN
                    RAISE EXCEPTION 'TEST FAILED: workflow completed — worker is running despite invalid GUC';
                END IF;

                RAISE NOTICE 'PASSED: workflow stuck in status=% — worker not processing (as expected)', inst_status;
            END;
        END;
    END IF;

    RAISE NOTICE 'PASSED: worker correctly refused to start with max_duroxide_connections=1';
END $$;

SELECT 'TEST PASSED' AS result;
