-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- df.start() must fail fast when the durable engine cannot accept the start.
--
-- df.start() writes its df.instances/df.nodes rows in the caller's transaction
-- but hands the workflow to the engine over a separate connection. If that
-- hand-off fails, df.start() must abort the whole transaction rather than
-- commit an instance row that would never run (a "stuck" instance nothing
-- recovers). This test forces the hand-off to fail by marking the background
-- worker not-ready, then asserts df.start() raises and leaves no row behind.
--
-- Readiness is toggled via <duroxide>._worker_ready.schema_version (the same
-- signal the client's readiness probe reads). The original value is saved and
-- restored inside one DO block so a mid-test failure never leaves the server
-- wedged for later tests.

DO $$
DECLARE
    dx_schema TEXT := df.duroxide_schema();
    orig      INT;
    raised    BOOLEAN := FALSE;
    leftover  BOOLEAN;
BEGIN
    -- Save the real readiness version, then break it so the client's readiness
    -- probe reports "worker not ready" and the engine hand-off fails.
    EXECUTE format('SELECT schema_version FROM %I._worker_ready LIMIT 1', dx_schema) INTO orig;
    EXECUTE format('UPDATE %I._worker_ready SET schema_version = -1', dx_schema);

    -- df.start() should raise. The graph rows it inserted are rolled back with
    -- the surrounding subtransaction when the exception is caught.
    BEGIN
        PERFORM df.start('SELECT 1', 'fail-fast-probe');
    EXCEPTION WHEN OTHERS THEN
        raised := TRUE;
    END;

    leftover := EXISTS (SELECT 1 FROM df.instances WHERE label = 'fail-fast-probe');

    -- Restore readiness BEFORE asserting so a failed assertion never leaves the
    -- worker marked not-ready for subsequent tests.
    EXECUTE format('UPDATE %I._worker_ready SET schema_version = %L', dx_schema, orig);

    IF NOT raised THEN
        RAISE EXCEPTION 'TEST FAILED [fail_fast]: df.start() did not raise when the engine could not accept the start';
    END IF;
    IF leftover THEN
        RAISE EXCEPTION 'TEST FAILED [fail_fast]: df.start() left a committed instance row after a failed start';
    END IF;

    RAISE NOTICE 'PASSED [fail_fast]: df.start() aborted and committed no instance row';
END $$;

-- Sanity: with readiness restored, a normal df.start() still works end-to-end.
SELECT public._e2e_wait_for_worker_ready(30);

CREATE TEMP TABLE _ff_state (instance_id TEXT);
INSERT INTO _ff_state SELECT df.start('SELECT 1', 'fail-fast-ok');

DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _ff_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(status, 'pending')) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [normal_start]: df.start() did not complete after readiness restored (status=%)', status;
    END IF;
    RAISE NOTICE 'PASSED [normal_start]: df.start() completes normally when the worker is ready';
END $$;

-- A compatibility transition must gate an already-cached Duroxide client in
-- this same backend session, not only newly constructed clients.
DO $$
DECLARE
    original_version TEXT;
    compatibility_error TEXT;
    cached_instance_id TEXT;
BEGIN
    SELECT instance_id INTO cached_instance_id FROM _ff_state;
    SELECT extversion INTO original_version
    FROM pg_catalog.pg_extension
    WHERE extname = 'pg_durable';

    UPDATE pg_catalog.pg_extension
    SET extversion = '0.2.2-rc1'
    WHERE extname = 'pg_durable';

    BEGIN
        PERFORM df.signal(cached_instance_id, 'cached-client-probe', '{}');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS compatibility_error = MESSAGE_TEXT;
    END;

    UPDATE pg_catalog.pg_extension
    SET extversion = original_version
    WHERE extname = 'pg_durable';

    IF compatibility_error NOT LIKE '%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED [cached_client]: cached client bypassed compatibility rejection: %',
            compatibility_error;
    END IF;
END $$;

DROP TABLE _ff_state;

SELECT 'TEST PASSED: start fail-fast' AS result;
