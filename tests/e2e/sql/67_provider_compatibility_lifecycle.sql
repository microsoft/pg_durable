-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Give the BGW several one-second stand-down polls before checking that the
-- rejected state remains unchanged.
SELECT pg_catalog.pg_sleep(4);

DO $$
DECLARE
    start_error TEXT;
    signal_error TEXT;
    cancel_result TEXT;
    monitored_status TEXT;
    monitored_result TEXT;
    awaited_status TEXT;
    provider_tables TEXT[];
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_durable') <> '0.2.2-rc1' THEN
        RAISE EXCEPTION 'TEST FAILED: compatibility fixture version changed unexpectedly';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM _duroxide._worker_ready
        WHERE sentinel
          AND schema_version = 73
          AND initialized_at = TIMESTAMPTZ '2000-01-01 00:00:00+00'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: stale readiness was rewritten while compatibility was rejected';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM _duroxide.unit4_provider_sentinel
        WHERE marker = 'must-survive-rejection'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: provider sentinel changed while compatibility was rejected';
    END IF;

    SELECT pg_catalog.array_agg(c.relname ORDER BY c.relname)
    INTO provider_tables
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '_duroxide'
      AND c.relkind IN ('r', 'p')
      AND c.relname IN (
          '_duroxide_migrations', 'instances', 'executions', 'history',
          'orchestrator_queue', 'worker_queue', 'instance_locks'
      );
    IF provider_tables IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: provider objects were created before compatibility acceptance: %', provider_tables;
    END IF;

    BEGIN
        PERFORM df.start('SELECT 99', 'unit4-rejected-start');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS start_error = MESSAGE_TEXT;
    END;
    IF start_error NOT LIKE '%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.start() did not return the compatibility rejection: %', start_error;
    END IF;
    IF EXISTS (SELECT 1 FROM df.instances WHERE label = 'unit4-rejected-start') THEN
        RAISE EXCEPTION 'TEST FAILED: rejected df.start() committed an instance';
    END IF;

    BEGIN
        PERFORM df.signal('a0000001', 'unit4-signal', '{}');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS signal_error = MESSAGE_TEXT;
    END;
    IF signal_error NOT LIKE '%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.signal() did not return the compatibility rejection: %', signal_error;
    END IF;

    cancel_result := df.cancel('a0000002', 'unit4-cancel');
    IF cancel_result NOT LIKE 'Failed to cancel:%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.cancel() did not preserve its rejection contract: %', cancel_result;
    END IF;
    IF (SELECT status FROM df.instances WHERE id = 'a0000002') <> 'running' THEN
        RAISE EXCEPTION 'TEST FAILED: rejected df.cancel() changed instance status';
    END IF;

    monitored_status := df.status('a0000003');
    SELECT r INTO monitored_result FROM df.result('a0000003') r;
    awaited_status := df.await_instance('a0000003', 1);
    IF monitored_status <> 'completed' OR monitored_result NOT LIKE '%42%' OR awaited_status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: table-only monitoring unavailable (status=%, result=%, await=%)',
            monitored_status, monitored_result, awaited_status;
    END IF;
END $$;

-- Correcting the installed version while PostgreSQL remains running must wake
-- the stood-down worker and initialize the provider without a server restart.
UPDATE pg_catalog.pg_extension
SET extversion = '0.2.6'
WHERE extname = 'pg_durable';

DO $$
DECLARE
    attempts INT := 0;
    ready BOOLEAN := FALSE;
BEGIN
    WHILE attempts < 100 LOOP
        SELECT EXISTS (
            SELECT 1 FROM _duroxide._worker_ready
            WHERE sentinel AND schema_version = 1
        ) INTO ready;
        EXIT WHEN ready;
        PERFORM pg_catalog.pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT ready THEN
        RAISE EXCEPTION 'TEST FAILED: worker did not leave compatibility stand-down after version correction';
    END IF;
END $$;

CREATE TEMP TABLE unit4_live_recovery (instance_id TEXT);
INSERT INTO unit4_live_recovery
SELECT df.start('SELECT 606 AS recovered', 'unit4-live-version-recovery');

DO $$
DECLARE
    recovered_id TEXT;
    recovered_status TEXT;
BEGIN
    SELECT instance_id INTO recovered_id FROM unit4_live_recovery;
    recovered_status := df.await_instance(recovered_id, 30);
    IF recovered_status <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: live version correction did not restore execution (status=%)',
            recovered_status;
    END IF;
END $$;

SELECT 'TEST PASSED: provider compatibility lifecycle rejection' AS result;