-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- The documented recovery from a below-floor schema is to drop and recreate the
-- extension. Do it in one transaction, the pattern this repo uses everywhere: a
-- gap lets the BGW's migration runner create the provider schema independently
-- and break CREATE EXTENSION.
--
-- Transactionally, the worker never observes the extension as absent. It sees a
-- version change, and the recreated install resolves a different provider schema
-- ('_duroxide') than the legacy one it stood down against ('duroxide'), so the
-- stand-down exit must re-resolve rather than reuse the name it started with.

BEGIN;
DROP EXTENSION pg_durable CASCADE;
DROP SCHEMA IF EXISTS duroxide CASCADE;
CREATE EXTENSION pg_durable;
COMMIT;

DO $$
DECLARE
    attempts INT := 0;
    ready BOOLEAN := FALSE;
BEGIN
    IF df.duroxide_schema() <> '_duroxide' THEN
        RAISE EXCEPTION 'TEST FAILED: recreated install did not switch to the fresh provider schema (got %)',
            df.duroxide_schema();
    END IF;

    WHILE attempts < 300 LOOP
        SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_tables
            WHERE schemaname = '_duroxide' AND tablename = '_worker_ready'
        ) INTO ready;
        IF ready THEN
            SELECT EXISTS (
                SELECT 1 FROM _duroxide._worker_ready
                WHERE sentinel AND schema_version >= 1
            ) INTO ready;
        END IF;
        EXIT WHEN ready;
        PERFORM pg_catalog.pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT ready THEN
        RAISE EXCEPTION 'TEST FAILED: worker did not leave compatibility stand-down after drop/recreate';
    END IF;
END $$;

CREATE TEMP TABLE compat_recovery_state (instance_id TEXT);
INSERT INTO compat_recovery_state
SELECT df.start('SELECT 606 AS recovered', 'compat-recreate-recovery');

DO $$
DECLARE
    recovered_id TEXT;
    recovered_status TEXT;
BEGIN
    SELECT instance_id INTO recovered_id FROM compat_recovery_state;
    recovered_status := df.await_instance(recovered_id, 30);
    IF recovered_status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: drop/recreate did not restore execution (status=%)',
            recovered_status;
    END IF;
END $$;

DROP TABLE compat_recovery_state;

SELECT 'TEST PASSED: provider compatibility drop/recreate recovery' AS result;
