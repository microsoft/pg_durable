-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests the core df <-> duroxide start-convergence problem this change fixes.
--
-- pg_durable keeps its own bookkeeping in the `df` schema; the workflow engine
-- (duroxide) keeps the running-workflow state in its own schema. `df.start()`
-- writes df rows in the caller's transaction, but the two schemas are separate
-- systems, so historically they could disagree in two ways:
--
--   Scenario 1 (ghost): you start a workflow, then your transaction rolls back.
--     The df rows vanish, but duroxide was already told to run it out-of-band on
--     a separate connection -> a running workflow with no df record.
--
--   Scenario 2 (stuck): the df rows are committed, but duroxide never learned it
--     should run -> a workflow that exists on paper but never executes.
--
-- The fix records intent in df and lets the background worker converge duroxide
-- to match: a rolled-back start tells duroxide nothing, and a committed-but-not-
-- yet-running instance is started by the worker.
--
-- The base connection is the superuser (postgres); durable functions run as the
-- non-superuser df_e2e_user. The runtime schema is resolved via
-- df.duroxide_schema().

-- Helper (superuser): assert no residual runtime rows for an instance id.
CREATE OR REPLACE FUNCTION pg_temp.assert_no_duroxide_residue(p_id text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    sch text := df.duroxide_schema();
    n   int;
BEGIN
    EXECUTE format(
        'SELECT (SELECT count(*) FROM %I.orchestrator_queue WHERE instance_id = $1) '
        '     + (SELECT count(*) FROM %I.instances        WHERE instance_id = $1)',
        sch, sch)
    INTO n USING p_id;
    IF n > 0 THEN
        RAISE EXCEPTION 'TEST FAILED [start_rollback_ghost]: rolled-back df.start left % runtime row(s) for instance %', n, p_id;
    END IF;
    RAISE NOTICE 'PASSED [start_rollback_ghost]: no runtime residue for %', p_id;
END $$;

-- ===========================================================================
-- Scenario 1: a rolled-back df.start() leaves no runtime "ghost".
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;
BEGIN;
SELECT df.start('SELECT 42', 'reconcile-start-rollback') AS rb_id \gset
ROLLBACK;
RESET SESSION AUTHORIZATION;

-- Give any (buggy) out-of-band start a moment to surface before asserting.
SELECT pg_sleep(2);

SELECT pg_temp.assert_no_duroxide_residue(:'rb_id');

-- ===========================================================================
-- Scenario 2: a committed df instance that the engine never heard about is
-- started by the worker (convergence backstop).
--
-- We simulate "committed intent whose start never reached duroxide" by writing
-- df.instances/df.nodes directly (no df.start, no notification), backdated so it
-- is immediately eligible for the worker's reconcile sweep. On the unfixed code
-- nothing ever starts it and this scenario times out.
-- ===========================================================================

DROP TABLE IF EXISTS reconcile_probe;
CREATE TABLE reconcile_probe (id SERIAL PRIMARY KEY, noted_at TIMESTAMPTZ DEFAULT now());
GRANT INSERT ON reconcile_probe TO df_e2e_user;
GRANT USAGE, SELECT ON SEQUENCE reconcile_probe_id_seq TO df_e2e_user;

-- Insert a minimal one-node graph owned by df_e2e_user, backdated past the
-- reconcile grace window. FKs between df.instances.root_node and df.nodes are
-- DEFERRABLE INITIALLY DEFERRED, so both rows can be inserted in one transaction.
BEGIN;
INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, database)
VALUES ('deadbee1', 'abadcafe', 'SQL', 'INSERT INTO reconcile_probe DEFAULT VALUES',
        'df_e2e_user'::regrole, 'postgres');

INSERT INTO df.instances (id, label, root_node, status, submitted_by, database, created_at, updated_at)
VALUES ('abadcafe', 'reconcile-start-backstop', 'deadbee1', 'pending',
        'df_e2e_user'::regrole, 'postgres',
        now() - interval '10 minutes', now() - interval '10 minutes');
COMMIT;

DO $$
DECLARE status TEXT; attempts INT := 0;
BEGIN
    LOOP
        SELECT s INTO status FROM df.status('abadcafe') s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(status, 'pending')) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [start_backstop]: worker did not start committed instance abadcafe (status=%)', status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM reconcile_probe) THEN
        RAISE EXCEPTION 'TEST FAILED [start_backstop]: instance completed but its node never ran';
    END IF;

    RAISE NOTICE 'PASSED [start_backstop]: worker started and completed committed instance abadcafe';
END $$;

-- ===========================================================================
-- Scenario 3: a stale "running" claim left by a worker that died between the
-- atomic claim (pending -> running) and the engine start is recovered.
--
-- We simulate the crashed-mid-start state directly: an instance whose df row is
-- 'running' (as if the claim committed) but which the engine never started,
-- backdated so its claim is older than the reconcile grace window. The sweep
-- must notice the engine does not know it and re-start it. On code that only
-- sweeps 'pending' rows this instance is stranded forever and the scenario times
-- out.
-- ===========================================================================

BEGIN;
INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, database)
VALUES ('deadbee2', 'badcab1e', 'SQL', 'INSERT INTO reconcile_probe DEFAULT VALUES',
        'df_e2e_user'::regrole, 'postgres');

INSERT INTO df.instances (id, label, root_node, status, submitted_by, database, start_input, created_at, updated_at)
VALUES ('badcab1e', 'reconcile-stale-running', 'deadbee2', 'running',
        'df_e2e_user'::regrole, 'postgres', '{"instance_id": "badcab1e", "vars": {}}'::jsonb,
        now() - interval '10 minutes', now() - interval '10 minutes');
COMMIT;

DO $$
DECLARE status TEXT; attempts INT := 0; probe_before INT; probe_after INT;
BEGIN
    SELECT count(*) INTO probe_before FROM reconcile_probe;
    LOOP
        SELECT s INTO status FROM df.status('badcab1e') s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(COALESCE(status, 'running')) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [stale_running_recovery]: worker did not recover stale-running instance badcab1e (status=%)', status;
    END IF;

    SELECT count(*) INTO probe_after FROM reconcile_probe;
    IF probe_after <= probe_before THEN
        RAISE EXCEPTION 'TEST FAILED [stale_running_recovery]: instance completed but its node never ran';
    END IF;

    RAISE NOTICE 'PASSED [stale_running_recovery]: worker recovered stale-running instance badcab1e';
END $$;

DROP TABLE reconcile_probe;

SELECT 'TEST PASSED: reconcile start' AS result;
