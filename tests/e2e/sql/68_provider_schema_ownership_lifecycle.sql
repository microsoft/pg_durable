-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

SELECT pg_catalog.pg_sleep(3);

DO $$
DECLARE
    provider_tables TEXT[];
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_depend d
          ON d.objid = n.oid
         AND d.classid = 'pg_catalog.pg_namespace'::pg_catalog.regclass
         AND d.deptype = 'e'
        JOIN pg_catalog.pg_extension e
          ON e.oid = d.refobjid
         AND e.extname = 'pg_durable'
        WHERE n.nspname = '_duroxide'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: provider schema is still extension-owned';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM _duroxide.unit4_ownership_sentinel
        WHERE marker = 'must-survive-ownership-refusal'
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: ownership sentinel changed before refusal';
    END IF;

    SELECT pg_catalog.array_agg(c.relname ORDER BY c.relname)
    INTO provider_tables
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '_duroxide'
      AND c.relkind IN ('r', 'p')
      AND c.relname IN (
          '_worker_ready', '_duroxide_migrations', 'instances', 'executions',
          'history', 'orchestrator_queue', 'worker_queue', 'instance_locks'
      );
    IF provider_tables IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED: provider objects were created before ownership acceptance: %', provider_tables;
    END IF;
END $$;

SELECT 'TEST PASSED: unowned provider schema rejected before mutation' AS result;