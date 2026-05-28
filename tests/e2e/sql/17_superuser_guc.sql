-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- 17_superuser_guc.sql
-- Tests: pg_durable.enable_superuser_instances GUC enforcement
--
-- This test runs in the "superuser-guc-off" phase where the server was started
-- WITHOUT pg_durable.enable_superuser_instances (defaults to off).  Because the
-- GUC is Postmaster-level, it cannot be changed at runtime.
--
-- Cases covered:
--   1. GUC off: superuser df.start() is rejected immediately.
--   2. Non-superuser unaffected: df_e2e_user can submit with GUC off.
--   3. Forgery caught by load_function_graph (instance-level rejection).
--   4. Forgery caught by execute_sql (node-level rejection, post-cache tamper).
--
-- "GUC on + superuser succeeds" is implicitly covered by every other E2E test
-- (standard phase runs as postgres with enable_superuser_instances = on).
--
-- Runs as postgres throughout (superuser); identity switching is explicit.

-- ============================================================
-- Setup
-- ============================================================
DO $setup$
BEGIN
    -- Clean up forger role from previous runs
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename = 'su_guc_forger' AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY su_guc_forger; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE su_guc_forger;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

-- Role with BYPASSRLS but NOT a superuser — the threat actor.
CREATE ROLE su_guc_forger LOGIN BYPASSRLS;
SELECT df.grant_usage('su_guc_forger');
GRANT TEMPORARY ON DATABASE postgres TO su_guc_forger;
-- The forger needs UPDATE on submitted_by to simulate the attack.
-- df.grant_usage() only grants UPDATE (status, updated_at).
GRANT UPDATE (submitted_by) ON df.instances TO su_guc_forger;
GRANT UPDATE (submitted_by) ON df.nodes TO su_guc_forger;

-- ============================================================
-- Test 1: GUC off — superuser df.start() is rejected
-- ============================================================
DO $$
DECLARE
    caught BOOLEAN := false;
    msg TEXT;
BEGIN
    BEGIN
        PERFORM df.start('SELECT 1', 'su-guc-test1');
    EXCEPTION WHEN OTHERS THEN
        caught := true;
        msg := SQLERRM;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST 1 FAILED: expected df.start() to raise an error for superuser when GUC is off';
    END IF;

    IF msg NOT LIKE '%enable_superuser_instances%' THEN
        RAISE EXCEPTION 'TEST 1 FAILED: error message does not mention enable_superuser_instances, got: %', msg;
    END IF;

    RAISE NOTICE 'TEST 1 PASSED: superuser df.start() rejected when GUC is off (error: %)', msg;
END $$;

-- ============================================================
-- Test 2: Non-superuser unaffected when GUC is off
-- ============================================================
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _su_guc_t2 (instance_id TEXT);
INSERT INTO _su_guc_t2 SELECT df.start('SELECT 1', 'su-guc-test2');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _su_guc_t2;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF status != 'completed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: non-superuser blocked when GUC is off, status=%', status;
    END IF;
    RAISE NOTICE 'TEST 2 PASSED: non-superuser df.start() works when GUC is off';
END $$;
DROP TABLE _su_guc_t2;

-- ============================================================
-- Test 3: Forgery caught by load_function_graph (instance level)
--
-- Tamper submitted_by immediately after df.start(), before the worker has
-- a chance to call load_function_graph.  load_function_graph reads
-- submitted_by and rejects the instance because the GUC is off.
-- ============================================================

DROP TABLE IF EXISTS _su_guc_t3;
CREATE TABLE _su_guc_t3 (instance_id TEXT);
GRANT ALL ON _su_guc_t3 TO df_e2e_user, su_guc_forger;

SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _su_guc_t3 SELECT df.start('SELECT 1', 'su-guc-test3-load-guard');
RESET SESSION AUTHORIZATION;

-- Tamper immediately — worker hasn't picked this up yet.
SET SESSION AUTHORIZATION su_guc_forger;
DO $$
DECLARE
    inst TEXT;
BEGIN
    SELECT instance_id INTO inst FROM _su_guc_t3;

    UPDATE df.instances
    SET    submitted_by = 'postgres'::regrole
    WHERE  id = inst;

    UPDATE df.nodes
    SET    submitted_by = 'postgres'::regrole
    WHERE  instance_id = inst;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _su_guc_t3;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST 3 FAILED: expected failed, got: %', status;
    END IF;

    -- Verify no individual node was marked failed (the rejection happened
    -- before any node execution, at the load_function_graph level).
    IF EXISTS (
        SELECT 1 FROM df.nodes n
        WHERE n.instance_id = inst_id AND n.status = 'failed'
    ) THEN
        RAISE EXCEPTION 'TEST 3 FAILED: a node was marked failed — expected instance-level rejection only';
    END IF;

    RAISE NOTICE 'TEST 3 PASSED: forgery caught by load_function_graph (instance-level rejection)';
END $$;

DROP TABLE _su_guc_t3;

-- ============================================================
-- Test 4: Post-load tampering has no effect (immutable cached graph)
--
-- execute_sql uses the in-memory FunctionGraph cached by duroxide after
-- load_function_graph runs.  That cache is immutable: an attacker who
-- tampers df.nodes after graph load cannot affect execution identity.
-- The test below verifies that a legitimately submitted instance
-- completes successfully even if df.nodes is tampered afterward —
-- confirming the cache is used, not the live table.
-- ============================================================

DROP TABLE IF EXISTS su_guc_executed_sentinel;
CREATE TABLE su_guc_executed_sentinel (marker TEXT);
GRANT ALL ON su_guc_executed_sentinel TO df_e2e_user;

DROP TABLE IF EXISTS _su_guc_t4;
CREATE TABLE _su_guc_t4 (instance_id TEXT);
GRANT ALL ON _su_guc_t4 TO df_e2e_user, su_guc_forger;

SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _su_guc_t4
SELECT df.start(
    df.sleep(2) ~> 'INSERT INTO su_guc_executed_sentinel VALUES (''legitimate SQL ran'')',
    'su-guc-test4-cache-immutable'
);
RESET SESSION AUTHORIZATION;

-- Wait for load_function_graph to complete before tampering.
SELECT pg_sleep(1);

-- Tamper after graph is already cached — should have no effect on execution.
SET SESSION AUTHORIZATION su_guc_forger;
DO $$
DECLARE
    inst TEXT;
BEGIN
    SELECT instance_id INTO inst FROM _su_guc_t4;

    UPDATE df.instances
    SET    submitted_by = 'postgres'::regrole
    WHERE  id = inst;

    UPDATE df.nodes
    SET    submitted_by = 'postgres'::regrole
    WHERE  instance_id = inst;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id    TEXT;
    status     TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _su_guc_t4;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    -- The instance must complete: execute_sql ran with the cached (clean)
    -- identity and never saw the tampered superuser in df.nodes.
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 4 FAILED: expected completed (cache immutable), got: %', status;
    END IF;

    -- The sentinel must contain the row — the legitimate SQL ran.
    IF NOT EXISTS (SELECT 1 FROM su_guc_executed_sentinel) THEN
        RAISE EXCEPTION 'TEST 4 FAILED: sentinel is empty — legitimate SQL did not run';
    END IF;

    RAISE NOTICE 'TEST 4 PASSED: post-load tamper had no effect; graph cache is immutable';
END $$;

DROP TABLE _su_guc_t4;

-- ============================================================
-- Test 5: Cross-iteration tamper caught on continue_as_new re-load
--
-- Loop functions call continue_as_new on each iteration, which discards
-- duroxide history and starts a fresh orchestration generation.
-- load_function_graph is therefore called again at the top of every
-- new generation, re-reading submitted_by from the database.
--
-- Attack: tamper submitted_by between iterations (or during restart between
-- iterations) → load_function_graph reads tampered data → superuser detected
-- → instance is failed, NOT executed as superuser.
-- ============================================================
DROP TABLE IF EXISTS su_guc_loop_sentinel;
CREATE TABLE su_guc_loop_sentinel (iteration INT);
GRANT ALL ON su_guc_loop_sentinel TO df_e2e_user;

DROP TABLE IF EXISTS _su_guc_t5;
CREATE TABLE _su_guc_t5 (instance_id TEXT);
GRANT ALL ON _su_guc_t5 TO df_e2e_user, su_guc_forger;

-- Start a loop that runs through continue_as_new at least once.
-- Iteration 1 records iteration=1 and continues (count < 2).
-- We tamper AFTER iteration 1 completes. load_function_graph for
-- iteration 2 sees the tampered superuser identity and blocks the instance.
-- The df.sleep(2) at the top of the loop body ensures that after
-- continue_as_new fires, the new generation pauses long enough for the
-- tamper to land before load_function_graph returns and SQL executes.
SET SESSION AUTHORIZATION df_e2e_user;
INSERT INTO _su_guc_t5
SELECT df.start(
    @> (
        df.sleep(2)
        ~> 'INSERT INTO su_guc_loop_sentinel VALUES (
            (SELECT COALESCE(MAX(iteration), 0) + 1 FROM su_guc_loop_sentinel)
        ) RETURNING iteration'
        ~> df.if(
            'SELECT (SELECT COUNT(*) FROM su_guc_loop_sentinel) >= 2',
            df.break(),
            df.sleep(0)
        )
    ),
    'su-guc-test5-loop-tamper'
);
RESET SESSION AUTHORIZATION;

-- Wait for exactly 1 row to appear (iteration 1 done, continue_as_new fired).
DO $$
DECLARE
    attempts INT := 0;
BEGIN
    LOOP
        EXIT WHEN (SELECT COUNT(*) FROM su_guc_loop_sentinel) >= 1 OR attempts > 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
END $$;

-- Iteration 1 completed.  The loop would continue_as_new for iteration 2.
-- Tamper now — load_function_graph for iteration 2 will see the superuser.
SET SESSION AUTHORIZATION su_guc_forger;
DO $$
DECLARE
    inst TEXT;
BEGIN
    SELECT instance_id INTO inst FROM _su_guc_t5;
    UPDATE df.instances SET submitted_by = 'postgres'::regrole WHERE id = inst;
    UPDATE df.nodes      SET submitted_by = 'postgres'::regrole WHERE instance_id = inst;
END $$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    iter_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _su_guc_t5;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    -- load_function_graph for iteration 2 must have blocked the tampered identity.
    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST 5 FAILED: expected failed after cross-iteration tamper, got: %', status;
    END IF;

    -- Only iteration 1 should have written a row; the forged SQL for
    -- iteration 2 must never have run.
    SELECT COUNT(*) INTO iter_count FROM su_guc_loop_sentinel;
    IF iter_count != 1 THEN
        RAISE EXCEPTION 'TEST 5 FAILED: expected 1 iteration row, found %', iter_count;
    END IF;

    RAISE NOTICE 'TEST 5 PASSED: cross-iteration tamper caught by load_function_graph re-validation (iterations=%, status=%)', iter_count, status;
END $$;

DROP TABLE _su_guc_t5;

-- ============================================================
-- Cleanup
-- ============================================================
DROP TABLE IF EXISTS su_guc_loop_sentinel;
DROP TABLE IF EXISTS su_guc_executed_sentinel;

DO $teardown$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE usename = 'su_guc_forger' AND pid <> pg_backend_pid();

    BEGIN DROP OWNED BY su_guc_forger; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE su_guc_forger;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $teardown$;

SELECT 'TEST PASSED' AS result;
