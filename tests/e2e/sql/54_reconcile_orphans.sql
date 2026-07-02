-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Reconciliation reclaims orphaned engine records: those the engine still holds
-- but pg_durable no longer has a df.instances row for.
--
-- A rolled-back df.start() is the canonical case: df.start() hands the workflow
-- to the engine over a separate connection (which commits), then the caller's
-- transaction rolls back — so the df rows vanish but the engine keeps an inert
-- instance that can never load its (rolled-back) graph and ends up Failed.
-- Reconciliation reclaims such df-less engine records once they age past the
-- retention window, and must leave df-backed instances alone.
--
-- Runs in the "reconcile" phase with pg_durable.reconcile_interval = 2 and
-- pg_durable.retention_days = 0 so a pass acts within the test window instead of
-- the conservative production defaults. Base connection is the superuser
-- (postgres); enable_superuser_instances is on.

-- Helper: does the engine still know this instance?
CREATE OR REPLACE FUNCTION pg_temp.duroxide_has(p_id TEXT)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    sch TEXT := df.duroxide_schema();
    n   INT;
BEGIN
    EXECUTE format('SELECT pg_catalog.count(*) FROM %I.get_instance_info($1)', sch)
        INTO n USING p_id;
    RETURN n > 0;
END $$;

-- ===========================================================================
-- Scenario 1: a rolled-back df.start() leaves a df-less engine record that
-- reconciliation reclaims.
-- ===========================================================================

-- Capture the id via \gset (a client variable survives the rollback), then stash
-- it in a temp table *after* the rollback so the DO block can read it (\gset
-- variables do not interpolate inside DO blocks).
BEGIN;
SELECT df.start('SELECT 1', 'orphan-probe') AS gid \gset
ROLLBACK;

DROP TABLE IF EXISTS _orphan;
CREATE TEMP TABLE _orphan (id TEXT);
INSERT INTO _orphan VALUES (:'gid');

DO $$
DECLARE
    gid       TEXT;
    appeared  BOOLEAN := FALSE;
    gone      BOOLEAN := FALSE;
    attempts  INT := 0;
BEGIN
    SELECT id INTO gid FROM _orphan;

    -- The engine record materializes once the worker fails to load the
    -- rolled-back graph (~5s). Confirm it exists so the reclaim assertion is real.
    LOOP
        IF pg_temp.duroxide_has(gid) THEN appeared := TRUE; EXIT; END IF;
        EXIT WHEN attempts > 300;  -- 30s
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF NOT appeared THEN
        RAISE EXCEPTION 'TEST FAILED [orphan_reclaimed]: orphan % never materialized in the engine (cannot test reclaiming)', gid;
    END IF;

    -- Reconciliation (reconcile_interval=2s, retention_days=0) must then reclaim it.
    attempts := 0;
    LOOP
        IF NOT pg_temp.duroxide_has(gid) THEN gone := TRUE; EXIT; END IF;
        EXIT WHEN attempts > 300;  -- 30s
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF NOT gone THEN
        RAISE EXCEPTION 'TEST FAILED [orphan_reclaimed]: reconciliation did not reclaim the df-less engine record %', gid;
    END IF;

    RAISE NOTICE 'PASSED [orphan_reclaimed]: reconciliation reclaimed the df-less (orphan) engine record';
END $$;

DROP TABLE _orphan;

-- ===========================================================================
-- Scenario 2: a live, df-backed instance is left alone (reconciliation is not so
-- aggressive that it touches instances pg_durable still tracks). A signal wait
-- keeps it Running — hence neither terminal (removal skips it) nor Failed
-- (reclamation skips it) — so it stays a live, df-backed instance across passes.
-- ===========================================================================

DROP TABLE IF EXISTS _keep;
CREATE TEMP TABLE _keep (id TEXT);
INSERT INTO _keep SELECT df.start(df.wait_for_signal('keep-go'), 'keep');

DO $$
DECLARE
    kid      TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT id INTO kid FROM _keep;

    -- Wait until the engine is actually running it, so duroxide_has is meaningful.
    LOOP
        SELECT s INTO status FROM df.status(kid) s;
        EXIT WHEN lower(COALESCE(status, '')) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(COALESCE(status, 'pending')) <> 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [live_kept]: instance % did not reach running (status=%)', kid, status;
    END IF;

    -- Give reconciliation several passes; a live df-backed instance must survive.
    PERFORM pg_sleep(6);
    IF NOT pg_temp.duroxide_has(kid) THEN
        RAISE EXCEPTION 'TEST FAILED [live_kept]: reconciliation reclaimed a df-backed engine record % (too aggressive)', kid;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM df.instances WHERE id OPERATOR(pg_catalog.=) kid) THEN
        RAISE EXCEPTION 'TEST FAILED [live_kept]: reconciliation removed the live df row for %', kid;
    END IF;

    RAISE NOTICE 'PASSED [live_kept]: reconciliation left the live df-backed instance intact';
END $$;

-- Release the survivor and wait until it leaves the Running state, so no live
-- engine orchestration lingers past this phase. A Running orchestration left in
-- the shared data directory would be resumed by the next server started against
-- it (e.g. the upgrade tests) and run activities against that server's schema.
SELECT df.signal((SELECT id FROM _keep), 'keep-go');

DO $$
DECLARE
    kid      TEXT;
    status   TEXT;
    attempts INT := 0;
BEGIN
    SELECT id INTO kid FROM _keep;
    LOOP
        SELECT s INTO status FROM df.status(kid) s;
        -- Terminal, or already removed by the retention_days=0 pass.
        EXIT WHEN status IS NULL
              OR lower(status) IN ('completed', 'failed', 'cancelled')
              OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF status IS NOT NULL AND lower(status) = 'running' THEN
        RAISE EXCEPTION 'TEST FAILED [live_kept]: survivor % never left running after signal', kid;
    END IF;
END $$;

DROP TABLE _keep;

SELECT 'TEST PASSED: reconcile orphans' AS result;
