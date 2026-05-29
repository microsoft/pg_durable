-- =============================================================================
-- SCENARIO 4 – TABLES NOT VACUUMED FOR X DAYS
-- =============================================================================
-- Tables that have not been vacuumed (manually or by autovacuum) for an
-- extended period accumulate dead tuples, leading to bloat and degraded
-- query performance. This scenario identifies stale tables and ensures
-- vacuum maintenance is current.
-- =============================================================================

-- STEP 1: Identify tables not vacuumed / auto-vacuumed for X days
-- Replace 'X' with the number of days threshold (e.g., 7, 30).
SELECT
    schemaname,
    relname,
    last_vacuum,
    last_autovacuum,
    n_dead_tup
FROM pg_stat_user_tables
WHERE last_autovacuum IS NULL
   OR last_autovacuum < now() - interval '7 days'
   OR last_vacuum IS NULL
   OR last_vacuum < now() - interval '7 days'
ORDER BY n_dead_tup DESC;

-- STEP 2: Identify autovacuum blockers
-- Run the common prerequisite query:
--   \i examples/operational-scenarios/00_common_prerequisite.sql

-- STEP 3: Resolve blockers
-- Based on the blocker source, take the appropriate action:

-- 3a. Terminate long-running backend sessions (if safe):
-- SELECT pg_terminate_backend(<pid>);

-- 3b. Drop unused replication slots:
-- SELECT pg_drop_replication_slot('<slot_name>');

-- 3c. Resolve prepared transactions:
-- COMMIT PREPARED '<gid>';
--   or
-- ROLLBACK PREPARED '<gid>';

-- STEP 4: Run vacuum after blockers are resolved
VACUUM (ANALYZE);


-- =============================================================================
-- PG_DURABLE VERSION – Stale Table Vacuum as a Durable Function
-- =============================================================================
-- This version chains stale-table detection, blocker identification,
-- remediation, and vacuum into a durable function graph. Uses ~> (sequence)
-- to ensure each step completes before the next. Configurable day threshold.
-- If the workflow fails mid-way, duroxide resumes from the last completed step.
-- =============================================================================

-- Track stale tables and remediation
DROP TABLE IF EXISTS stale_tables_log;
CREATE TABLE stale_tables_log (
    id              SERIAL PRIMARY KEY,
    schema_name     TEXT,
    table_name      TEXT,
    last_vacuum     TIMESTAMPTZ,
    last_autovacuum TIMESTAMPTZ,
    n_dead_tup      BIGINT,
    days_since_vacuum NUMERIC,
    detected_at     TIMESTAMPTZ DEFAULT now()
);

DROP TABLE IF EXISTS stale_vacuum_action_log;
CREATE TABLE stale_vacuum_action_log (
    id          SERIAL PRIMARY KEY,
    action      TEXT,
    result      TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

-- Start the durable function: find stale tables → detect blockers → branch → vacuum
CREATE TEMP TABLE _scenario4_state (instance_id TEXT);
INSERT INTO _scenario4_state SELECT df.start(

    -- Step 1: Identify tables not vacuumed in the last 7 days
    --         (change the interval to match your threshold)
    'INSERT INTO stale_tables_log (schema_name, table_name, last_vacuum, last_autovacuum, n_dead_tup, days_since_vacuum)
     SELECT
         schemaname,
         relname,
         last_vacuum,
         last_autovacuum,
         n_dead_tup,
         round(extract(epoch FROM now() - greatest(
             coalesce(last_vacuum, ''1970-01-01''::timestamptz),
             coalesce(last_autovacuum, ''1970-01-01''::timestamptz)
         )) / 86400, 1)
     FROM pg_stat_user_tables
     WHERE (last_autovacuum IS NULL OR last_autovacuum < now() - interval ''7 days'')
       AND (last_vacuum IS NULL OR last_vacuum < now() - interval ''7 days'')
     ORDER BY n_dead_tup DESC'

    ~>

    -- Step 2: Log autovacuum blockers
    'INSERT INTO stale_vacuum_action_log (action, result)
     SELECT ''blocker_detected'',
            format(''source=%s, xmin_age=%s, details=%s'', source, xmin_age, details)
     FROM (
         SELECT ''pg_stat_activity'' AS source, age(backend_xid) AS xmin_age,
                format(''pid=%s, state=%s, user=%s'', pid, state, usename) AS details
         FROM pg_stat_activity WHERE backend_xid IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots'', age(catalog_xmin),
                format(''slot=%s, active=%s'', slot_name, active)
         FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_prepared_xacts'', age(transaction::xid),
                format(''gid=%s, db=%s'', gid, database)
         FROM pg_prepared_xacts WHERE transaction IS NOT NULL
     ) blockers ORDER BY xmin_age DESC'

    ~>

    -- Step 3: Branch — are there blockers?
    --   YES → wait for user approval, remediate, then vacuum
    --   NO  → vacuum immediately (no user interaction needed)
    'SELECT EXISTS(
         SELECT 1 FROM stale_vacuum_action_log WHERE action = ''blocker_detected''
     )'
    ?>
        (
            -- Blockers found: pause for user approval before remediation
            df.wait_for_signal('approve-stale-vacuum')

            ~>

            -- Terminate idle-in-transaction backends older than 30 minutes
            'INSERT INTO stale_vacuum_action_log (action, result)
             SELECT format(''terminated pid=%s (%s)'', pid, usename),
                    pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND backend_xid IS NOT NULL
               AND state_change < now() - interval ''30 minutes'''

            ~>

            -- Run VACUUM ANALYZE after blockers are cleared
            'VACUUM (ANALYZE)'
        )
    !>
        -- No blockers: vacuum immediately
        'VACUUM (ANALYZE)'

    ~>

    -- Step 4: Record completion with summary
    'INSERT INTO stale_vacuum_action_log (action, result)
     SELECT ''stale_vacuum_complete'',
            format(''Found %s stale tables, worst: %s.%s (%s dead tuples, %s days since vacuum)'',
                   (SELECT count(*) FROM stale_tables_log),
                   (SELECT schema_name FROM stale_tables_log ORDER BY n_dead_tup DESC LIMIT 1),
                   (SELECT table_name FROM stale_tables_log ORDER BY n_dead_tup DESC LIMIT 1),
                   (SELECT max(n_dead_tup) FROM stale_tables_log),
                   (SELECT max(days_since_vacuum) FROM stale_tables_log))',

    'scenario4-tables-not-vacuumed'
);

-- Poll until the durable function completes (timeout ~60s)
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _scenario4_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'SCENARIO 4 FAILED: durable function status = %', status;
    END IF;

    RAISE NOTICE 'SCENARIO 4 COMPLETED: stale table vacuum finished';
END $$;

-- Review results
SELECT * FROM stale_tables_log ORDER BY n_dead_tup DESC;
SELECT * FROM stale_vacuum_action_log ORDER BY id;

-- Cleanup
DROP TABLE _scenario4_state;
-- DROP TABLE stale_tables_log;
-- DROP TABLE stale_vacuum_action_log;
