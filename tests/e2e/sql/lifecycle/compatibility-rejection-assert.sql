-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Asserts behaviour while the background worker is stood down against a
-- below-floor schema. Runs before the shell phase stops the server to prove
-- the stand-down loop honours shutdown, so this file must not correct the
-- installed version -- see compatibility-rejection-recovery.sql.

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
        SELECT 1 FROM _duroxide.compat_rejection_sentinel
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
        PERFORM df.start('SELECT 99', 'compat-rejected-start');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS start_error = MESSAGE_TEXT;
    END;
    IF start_error NOT LIKE '%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.start() did not return the compatibility rejection: %', start_error;
    END IF;
    IF EXISTS (SELECT 1 FROM df.instances WHERE label = 'compat-rejected-start') THEN
        RAISE EXCEPTION 'TEST FAILED: rejected df.start() committed an instance';
    END IF;

    BEGIN
        PERFORM df.signal('a0000001', 'compat-signal', '{}');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS signal_error = MESSAGE_TEXT;
    END;
    IF signal_error NOT LIKE '%supports 0.2.2 and later only%' THEN
        RAISE EXCEPTION 'TEST FAILED: df.signal() did not return the compatibility rejection: %', signal_error;
    END IF;

    cancel_result := df.cancel('a0000002', 'compat-cancel');
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

SELECT 'TEST PASSED: provider compatibility rejection' AS result;
