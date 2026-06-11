-- =============================================================================
-- SCENARIO 3 – WRAPAROUND RISK
-- =============================================================================
-- PostgreSQL uses 32-bit transaction IDs (XIDs). When a database approaches
-- the ~2 billion XID limit without freezing old rows, it risks entering
-- emergency shutdown mode. This scenario helps identify and mitigate
-- wraparound risk proactively.
-- =============================================================================

-- STEP 1: Identify database transaction age
-- Check which databases are closest to the wraparound limit.
SELECT
    datname,
    age(datfrozenxid) AS dat_xid_age,
    2000000000 - age(datfrozenxid) AS txids_remaining
FROM pg_database
WHERE datallowconn
ORDER BY dat_xid_age DESC;

-- STEP 2: Identify databases with remaining transactions < 1 billion
-- Any database with txids_remaining < 1,000,000,000 needs attention.
SELECT
    datname,
    age(datfrozenxid) AS dat_xid_age,
    2000000000 - age(datfrozenxid) AS txids_remaining
FROM pg_database
WHERE datallowconn
  AND 2000000000 - age(datfrozenxid) < 1000000000
ORDER BY txids_remaining ASC;

-- STEP 3: Identify tables that need freezing
-- Lists tables sorted by how close they are to the wraparound threshold.
SELECT
    c.relnamespace::regnamespace AS schema_name,
    c.relname AS table_name,
    greatest(age(c.relfrozenxid), age(t.relfrozenxid)) AS txid_age,
    2^31 - 3000000 - greatest(age(c.relfrozenxid), age(t.relfrozenxid)) AS txid_remaining
FROM pg_class c
LEFT JOIN pg_class t ON c.reltoastrelid = t.oid
WHERE c.relkind IN ('r', 'm')
ORDER BY txid_remaining ASC;

-- STEP 4: Vacuum freeze the most at-risk tables
-- Replace schema.table with the actual schema and table name from Step 3.
-- VACUUM (VERBOSE, FREEZE, ANALYZE) schema.table;


-- =============================================================================
-- PG_DURABLE VERSION – Wraparound Risk Mitigation as a Durable Function
-- =============================================================================
-- This version chains wraparound detection, at-risk table identification,
-- blocker remediation, and targeted VACUUM FREEZE into a durable function
-- graph. Uses ~> (sequence) to ensure each step completes before the next.
-- If the workflow fails (e.g., vacuum killed by OOM), duroxide resumes from
-- the last completed step on retry.
-- =============================================================================

-- Track wraparound diagnostics
DROP TABLE IF EXISTS wraparound_db_log;
CREATE TABLE wraparound_db_log (
    id              SERIAL PRIMARY KEY,
    datname         TEXT,
    dat_xid_age     BIGINT,
    txids_remaining BIGINT,
    detected_at     TIMESTAMPTZ DEFAULT now()
);

DROP TABLE IF EXISTS wraparound_table_log;
CREATE TABLE wraparound_table_log (
    id              SERIAL PRIMARY KEY,
    schema_name     TEXT,
    table_name      TEXT,
    txid_age        BIGINT,
    txid_remaining  BIGINT,
    detected_at     TIMESTAMPTZ DEFAULT now()
);

DROP TABLE IF EXISTS wraparound_action_log;
CREATE TABLE wraparound_action_log (
    id          SERIAL PRIMARY KEY,
    action      TEXT,
    result      TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

-- Start the durable function: detect DB risk → find tables → branch on blockers → freeze
CREATE TEMP TABLE _scenario3_state (instance_id TEXT);
-- The DSL sequence (~>) and conditional (?> / !>) operators live in the df
-- schema. Add df to the session search_path so the unqualified syntax resolves.
SET search_path TO "$user", public, df;

INSERT INTO _scenario3_state SELECT df.start(

    -- Step 1: Log database-level transaction ages
    'INSERT INTO wraparound_db_log (datname, dat_xid_age, txids_remaining)
     SELECT datname, age(datfrozenxid),
            2000000000 - age(datfrozenxid)
     FROM pg_database
     WHERE datallowconn
     ORDER BY age(datfrozenxid) DESC'

    ~>

    -- Step 2: Log tables closest to wraparound (top 50 most at-risk)
    'INSERT INTO wraparound_table_log (schema_name, table_name, txid_age, txid_remaining)
     SELECT
         c.relnamespace::regnamespace::text,
         c.relname,
         greatest(age(c.relfrozenxid), age(t.relfrozenxid)),
         (2^31 - 3000000 - greatest(age(c.relfrozenxid), age(t.relfrozenxid)))::bigint
     FROM pg_class c
     LEFT JOIN pg_class t ON c.reltoastrelid = t.oid
     WHERE c.relkind IN (''r'', ''m'')
     ORDER BY greatest(age(c.relfrozenxid), age(t.relfrozenxid)) DESC
     LIMIT 50'

    ~>

    -- Step 3: Log autovacuum blockers
    'INSERT INTO wraparound_action_log (action, result)
     SELECT ''blocker_detected'',
            format(''source=%s, xmin_age=%s, details=%s'', source, xmin_age, details)
     FROM (
         SELECT ''pg_stat_activity'' AS source, age(backend_xid) AS xmin_age,
                format(''pid=%s, state=%s'', pid, state) AS details
         FROM pg_stat_activity WHERE backend_xid IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots'', age(catalog_xmin),
                format(''slot=%s, active=%s'', slot_name, active)
         FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_prepared_xacts'', age(transaction::xid),
                format(''gid=%s'', gid)
         FROM pg_prepared_xacts WHERE transaction IS NOT NULL
     ) blockers ORDER BY xmin_age DESC'

    ~>

    -- Step 4: Branch — are there blockers?
    --   YES → wait for user approval, remediate blockers, then VACUUM FREEZE
    --   NO  → VACUUM FREEZE immediately (no user interaction needed)
    'SELECT EXISTS(
         SELECT 1 FROM wraparound_action_log WHERE action = ''blocker_detected''
     )'
    ?>
        (
            -- Blockers found: pause for user approval before remediation.
            -- Demo uses a timeout so the workflow auto-continues; in production
            -- omit it and approve with df.signal(<instance_id>, 'approve-wraparound-remediation').
            df.wait_for_signal('approve-wraparound-remediation', 30)

            ~>

            -- Terminate idle-in-transaction backends blocking vacuum
            'INSERT INTO wraparound_action_log (action, result)
             SELECT format(''terminated pid=%s'', pid),
                    pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND backend_xid IS NOT NULL
               AND state_change < now() - interval ''30 minutes'''

            ~>

            -- VACUUM FREEZE after blockers are cleared
            'VACUUM (FREEZE, ANALYZE)'
        )
    !>
        -- No blockers: VACUUM FREEZE immediately
        'VACUUM (FREEZE, ANALYZE)'

    ~>

    -- Step 5: Record completion with risk summary
    'INSERT INTO wraparound_action_log (action, result)
     SELECT ''wraparound_remediation_complete'',
            format(''Databases at risk: %s, Most urgent table: %s.%s (remaining: %s txids)'',
                   (SELECT count(*) FROM wraparound_db_log WHERE txids_remaining < 1000000000),
                   (SELECT schema_name FROM wraparound_table_log ORDER BY txid_remaining ASC LIMIT 1),
                   (SELECT table_name FROM wraparound_table_log ORDER BY txid_remaining ASC LIMIT 1),
                   (SELECT txid_remaining FROM wraparound_table_log ORDER BY txid_remaining ASC LIMIT 1))',

    'scenario3-wraparound-risk'
);

-- Poll until the durable function completes (timeout ~60s)
DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _scenario3_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'SCENARIO 3 FAILED: durable function status = %', status;
    END IF;

    RAISE NOTICE 'SCENARIO 3 COMPLETED: wraparound risk assessed and mitigated';
END $$;

-- Review results
SELECT * FROM wraparound_db_log ORDER BY dat_xid_age DESC;
SELECT * FROM wraparound_table_log ORDER BY txid_remaining ASC LIMIT 20;
SELECT * FROM wraparound_action_log ORDER BY id;

-- Cleanup
DROP TABLE _scenario3_state;
-- DROP TABLE wraparound_db_log;
-- DROP TABLE wraparound_table_log;
-- DROP TABLE wraparound_action_log;
