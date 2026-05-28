-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Test: pg_durable requires shared_preload_libraries
--
-- This test verifies that pg_durable refuses to initialize unless it is loaded
-- via shared_preload_libraries. It must be run against a PostgreSQL instance
-- that does NOT have pg_durable in shared_preload_libraries.
--
-- Usage: ./scripts/test-e2e-local.sh 00_requires_shared_preload

DO $$
BEGIN
    CREATE EXTENSION pg_durable;
    RAISE EXCEPTION 'Should have failed to load pg_durable without shared_preload_libraries';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%must be loaded via shared_preload_libraries%' THEN
        RAISE NOTICE 'TEST PASSED: pg_durable correctly requires shared_preload_libraries';
    ELSE
        RAISE EXCEPTION 'Failed with unknown error: %', SQLERRM;
    END IF;
END;
$$;

SELECT 'TEST PASSED' AS result;
