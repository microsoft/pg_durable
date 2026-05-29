-- =============================================================================
-- SCENARIO 2 – DATABASE BLOAT > 80%
-- =============================================================================
-- When table bloat exceeds 80%, performance degrades significantly due to
-- wasted disk space and inefficient sequential scans. This scenario addresses
-- excessive bloat by resolving vacuum blockers and running vacuum.
-- =============================================================================
-- =============================================================================
-- PG_DURABLE VERSION – Database Bloat Remediation as a Durable Function
-- =============================================================================
-- This version chains bloat estimation, blocker detection, remediation, and
-- targeted vacuum into a durable function graph. Uses ~> (sequence) and ?>
-- (conditional) to only vacuum tables that actually exceed the bloat threshold.
-- If the workflow fails mid-way, duroxide resumes from the last completed step.
-- =============================================================================

-- Track bloated tables and remediation actions
DROP TABLE IF EXISTS bloat_detection_log;
CREATE TABLE bloat_detection_log (
    id              SERIAL PRIMARY KEY,
    schema_name     TEXT,
    table_name      TEXT,
    table_size      TEXT,
    dead_tup        BIGINT,
    live_tup        BIGINT,
    bloat_ratio     NUMERIC,
    detected_at     TIMESTAMPTZ DEFAULT now()
);

DROP TABLE IF EXISTS bloat_remediation_log;
CREATE TABLE bloat_remediation_log (
    id          SERIAL PRIMARY KEY,
    action      TEXT,
    result      TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

-- Start the durable function: detect bloat → log blockers → branch → remediate or vacuum
CREATE TEMP TABLE _scenario2_state (instance_id TEXT);
INSERT INTO _scenario2_state SELECT df.start(

    -- Step 1: Identify bloated tables (dead tuple ratio > 20% as proxy for bloat)
    'INSERT INTO bloat_detection_log (schema_name, table_name, table_size, dead_tup, live_tup, bloat_ratio)
     SELECT
         schemaname,
         relname,
         pg_size_pretty(pg_total_relation_size(schemaname || ''.'' || relname)),
         n_dead_tup,
         n_live_tup,
         CASE WHEN n_live_tup > 0
              THEN round(n_dead_tup::numeric / n_live_tup * 100, 2)
              ELSE 0 END
     FROM pg_stat_user_tables
     WHERE n_dead_tup > 0
     ORDER BY n_dead_tup DESC'

    ~>

    -- Step 2: Log autovacuum blockers
    'INSERT INTO bloat_remediation_log (action, result)
     SELECT
         ''blocker_detected'',
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
         SELECT 1 FROM bloat_remediation_log WHERE action = ''blocker_detected''
     )'
    ?>
        (
            -- Blockers found: pause for user approval before remediation
            df.wait_for_signal('approve-bloat-remediation')

            ~>

            -- Terminate idle-in-transaction backends older than 30 minutes
            'INSERT INTO bloat_remediation_log (action, result)
             SELECT
                 format(''terminated pid=%s (%s)'', pid, usename),
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
    'INSERT INTO bloat_remediation_log (action, result)
     SELECT ''bloat_remediation_complete'',
            format(''Detected %s bloated tables, largest dead_tup=%s (%s.%s)'',
                   (SELECT count(*) FROM bloat_detection_log),
                   (SELECT max(dead_tup) FROM bloat_detection_log),
                   (SELECT schema_name FROM bloat_detection_log ORDER BY dead_tup DESC LIMIT 1),
                   (SELECT table_name FROM bloat_detection_log ORDER BY dead_tup DESC LIMIT 1))',

    'scenario2-database-bloat'
);

-- Poll until the durable function completes (timeout ~60s)
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _scenario2_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'SCENARIO 2 FAILED: durable function status = %', status;
    END IF;

    RAISE NOTICE 'SCENARIO 2 COMPLETED: database bloat detection and remediation finished';
END $$;

-- Review results
SELECT * FROM bloat_detection_log ORDER BY dead_tup DESC;
SELECT * FROM bloat_remediation_log ORDER BY id;

-- Cleanup
DROP TABLE _scenario2_state;
-- DROP TABLE bloat_detection_log;
-- DROP TABLE bloat_remediation_log;
