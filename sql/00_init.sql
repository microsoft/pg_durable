-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Initialize pg_durable extension
-- This must run first before any other tests
CREATE EXTENSION IF NOT EXISTS pg_durable;

-- Verify the extension was created
SELECT extname FROM pg_extension WHERE extname = 'pg_durable';

-- Verify the df schema exists
SELECT nspname FROM pg_namespace WHERE nspname = 'df';

-- Wait for the background worker to apply duroxide migrations.
-- The BGW populates the duroxide schema asynchronously after CREATE EXTENSION;
-- subsequent tests that call df.start() will fail if this isn't done first.
-- We poll duroxide._worker_ready directly (is_worker_ready is internal Rust,
-- not exposed as a SQL function).
DO $$
DECLARE
    attempts     INT := 0;
    table_exists BOOLEAN;
    ready        BOOLEAN;
BEGIN
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

        EXIT WHEN ready OR attempts >= 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF NOT ready THEN
        RAISE EXCEPTION 'Background worker not ready after 30s';
    END IF;
    RAISE NOTICE 'Background worker ready';
END $$;

-- Create a non-superuser role for testing so that pg_regress passes
-- without pg_durable.enable_superuser_instances = on.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_regress_user') THEN
        CREATE ROLE df_regress_user LOGIN;
    END IF;
END $$;
SELECT df.grant_usage('df_regress_user');
GRANT CREATE ON SCHEMA public TO df_regress_user;
