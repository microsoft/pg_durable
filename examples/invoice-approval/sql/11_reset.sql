-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Full reset: cancel all pipeline instances, clean duroxide state, reset demo tables.
-- After running this, go back to 03_seed_data.sql (or feed_invoices.sh) then 05_start_workflow.sql.
--
-- Requires superuser (for duroxide schema cleanup).

-- 1. Cancel all running pipeline instances
DO $$
DECLARE
    r RECORD;
    cnt INT := 0;
BEGIN
    FOR r IN
        SELECT i.id
        FROM df.instances i
        JOIN df.list_instances() li ON li.instance_id = i.id
        WHERE li.label = 'invoice-approval-pipeline'
          AND li.status = 'Running'
        ORDER BY i.created_at DESC
    LOOP
        PERFORM df.cancel(r.id, 'reset');
        cnt := cnt + 1;
    END LOOP;
    RAISE NOTICE 'Cancelled % running instance(s).', cnt;
END $$;

-- 2. Clean up df extension tables (instances + nodes)
TRUNCATE TABLE df.nodes, df.instances;

-- 3. Clean up duroxide engine state.
-- The provider schema is '_duroxide' on fresh installs and 'duroxide' on
-- installs upgraded from <= 0.2.2; resolve it via df.duroxide_schema().
DO $$
DECLARE
    dx_schema TEXT := df.duroxide_schema();
BEGIN
    EXECUTE format(
        'TRUNCATE TABLE %1$I.history, %1$I.executions, %1$I.instances, '
        '%1$I.instance_locks, %1$I.orchestrator_queue, %1$I.worker_queue, '
        '%1$I.kv_delta, %1$I.kv_store, %1$I.sessions',
        dx_schema
    );
END $$;

-- 4. Reset demo tables
TRUNCATE TABLE demo.invoice_audit, demo.invoices RESTART IDENTITY;

SELECT 'Reset complete. Run 03_seed_data.sql (or feed_invoices.sh) then 05_start_workflow.sql.' AS result;
