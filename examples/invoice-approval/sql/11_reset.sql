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

-- 3. Clean up duroxide engine state
TRUNCATE TABLE
    duroxide.history,
    duroxide.executions,
    duroxide.instances,
    duroxide.instance_locks,
    duroxide.orchestrator_queue,
    duroxide.worker_queue,
    duroxide.kv_delta,
    duroxide.kv_store,
    duroxide.sessions;

-- 4. Reset demo tables
TRUNCATE TABLE demo.invoice_audit, demo.invoices RESTART IDENTITY;

SELECT 'Reset complete. Run 03_seed_data.sql (or feed_invoices.sh) then 05_start_workflow.sql.' AS result;
