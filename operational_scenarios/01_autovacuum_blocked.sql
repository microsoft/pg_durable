-- =============================================================================
-- SCENARIO 1 – AUTOVACUUM IS BLOCKED
-- =============================================================================
-- When autovacuum cannot proceed, dead tuples accumulate and table bloat grows.
-- This scenario identifies blockers and resolves them so vacuum can run.
-- =============================================================================

-- STEP 1: Identify autovacuum blockers
-- Run the common prerequisite query first:
--   \i operational_scenarios/00_common_prerequisite.sql

-- STEP 2: Resolve blockers
-- Based on the blocker source, take the appropriate action:

-- 2a. Terminate long-running backend sessions (if safe):
-- SELECT pg_terminate_backend(<pid>);

-- 2b. Drop unused replication slots:
-- SELECT pg_drop_replication_slot('<slot_name>');

-- 2c. Resolve prepared transactions:
-- COMMIT PREPARED '<gid>';
--   or
-- ROLLBACK PREPARED '<gid>';

-- STEP 3: Run vacuum after blockers are resolved
-- VACUUM (ANALYZE);


-- =============================================================================
-- PG_DURABLE VERSION – Autovacuum Blocked Remediation as a Durable Function
-- =============================================================================
-- This version chains the blocker detection, remediation, and vacuum steps
-- into a durable function graph using pg_durable's ~> (sequence) and ?>
-- (conditional) operators. If the workflow fails mid-way, duroxide will
-- resume from the last completed step on retry.
-- =============================================================================

-- Results table to capture blocker diagnostics
DROP TABLE IF EXISTS autovacuum_blockers_log;
CREATE TABLE autovacuum_blockers_log (
    id          SERIAL PRIMARY KEY,
    source      TEXT,
    xmin_val    TEXT,
    xmin_age    BIGINT,
    details     TEXT,
    detected_at TIMESTAMPTZ DEFAULT now()
);

-- Track remediation actions taken
DROP TABLE IF EXISTS autovacuum_remediation_log;
CREATE TABLE autovacuum_remediation_log (
    id          SERIAL PRIMARY KEY,
    action      TEXT,
    result      TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

-- Start the durable function: detect → branch on blockers → remediate or vacuum directly
CREATE TEMP TABLE _scenario1_state (instance_id TEXT);
INSERT INTO _scenario1_state SELECT df.start(

    -- Step 1: Log all autovacuum blockers into the diagnostics table
    'INSERT INTO autovacuum_blockers_log (source, xmin_val, xmin_age, details)
     SELECT source, xmin::text, xmin_age, details
     FROM (
         SELECT ''pg_stat_activity'' AS source, backend_xid AS xmin,
                age(backend_xid) AS xmin_age,
                format(''pid=%s, db=%s, app=%s, user=%s, state=%s'',
                       pid, datname, application_name, usename, state) AS details
         FROM pg_stat_activity WHERE backend_xid IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots (catalog_xmin)'', catalog_xmin,
                age(catalog_xmin),
                format(''slot=%s, type=%s, active=%s'', slot_name, slot_type, active)
         FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots (xmin)'', xmin, age(xmin),
                format(''slot=%s, type=%s, active=%s'', slot_name, slot_type, active)
         FROM pg_replication_slots WHERE xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_prepared_xacts'', transaction::xid, age(transaction::xid),
                format(''gid=%s, db=%s, owner=%s'', gid, database, owner)
         FROM pg_prepared_xacts WHERE transaction IS NOT NULL
         UNION ALL
         SELECT ''pg_stat_replication'', backend_xmin, age(backend_xmin),
                format(''pid=%s, app=%s'', pid, application_name)
         FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
     ) blockers ORDER BY xmin_age DESC'

    ~>

    -- Step 2: Branch — are there blockers?
    --   YES → wait for user approval, remediate, then vacuum
    --   NO  → vacuum immediately (no user interaction needed)
    'SELECT EXISTS(SELECT 1 FROM autovacuum_blockers_log)'
    ?>
        (
            -- Blockers found: pause for user approval before remediation
            df.wait_for_signal('approve-remediation')

            ~>

            -- Terminate idle-in-transaction backends older than 30 minutes
            'INSERT INTO autovacuum_remediation_log (action, result)
             SELECT
                 format(''pg_terminate_backend(%s) -- %s idle %s'', pid, usename, state),
                 pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND backend_xid IS NOT NULL
               AND state_change < now() - interval ''30 minutes'''

            ~>

            -- Log remediation summary
            'INSERT INTO autovacuum_remediation_log (action, result)
             SELECT ''blocker_summary'',
                    format(''Found %s blockers, terminated %s idle sessions'',
                           (SELECT count(*) FROM autovacuum_blockers_log),
                           (SELECT count(*) FROM autovacuum_remediation_log
                            WHERE action LIKE ''pg_terminate_backend%''))'

            ~>

            -- Run VACUUM ANALYZE after blockers are cleared
            'VACUUM (ANALYZE)'
        )
    !>
        -- No blockers: vacuum immediately
        'VACUUM (ANALYZE)'

    ~>

    -- Step 3: Record completion
    'INSERT INTO autovacuum_remediation_log (action, result)
     VALUES (''vacuum_complete'', ''VACUUM (ANALYZE) finished successfully'')',

    'scenario1-autovacuum-blocked'
);

-- Poll until the durable function completes (timeout ~60s)
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _scenario1_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'SCENARIO 1 FAILED: durable function status = %', status;
    END IF;

    RAISE NOTICE 'SCENARIO 1 COMPLETED: autovacuum blockers detected and remediated';
END $$;

-- Review results
SELECT * FROM autovacuum_blockers_log ORDER BY xmin_age DESC;
SELECT * FROM autovacuum_remediation_log ORDER BY id;

-- Cleanup
DROP TABLE _scenario1_state;
-- DROP TABLE autovacuum_blockers_log;
-- DROP TABLE autovacuum_remediation_log;
