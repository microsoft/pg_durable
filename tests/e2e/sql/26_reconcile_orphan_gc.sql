-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.reconcile() repairs leftover df/_duroxide drift.
--
-- df.reconcile() deletes orphaned ROOT runtime instances (no df.instances row,
-- older than the grace window), gathering each orphan's full subtree so the
-- delete is accepted, and leaves healthy instances untouched.
--
-- Without the change df.reconcile() does not exist, so the calls below raise
-- undefined_function and the test fails.
--
-- _duroxide is read as the superuser (postgres); durable functions run as
-- df_e2e_user.

-- Helper (superuser): number of direct children (sub-orchestrations) of a root.
CREATE OR REPLACE FUNCTION pg_temp.duroxide_child_count(p_root text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE sch text := df.duroxide_schema(); n bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM %I.instances WHERE parent_instance_id = $1', sch)
        INTO n USING p_root;
    RETURN n;
END $$;

-- Helper (superuser): size of the full instance subtree rooted at p_root.
CREATE OR REPLACE FUNCTION pg_temp.duroxide_subtree_count(p_root text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE sch text := df.duroxide_schema(); n bigint;
BEGIN
    EXECUTE format(
        'WITH RECURSIVE t AS ( '
        '    SELECT instance_id FROM %1$I.instances WHERE instance_id = $1 '
        '    UNION '
        '    SELECT c.instance_id FROM %1$I.instances c JOIN t ON c.parent_instance_id = t.instance_id '
        ') SELECT count(*) FROM t', sch)
        INTO n USING p_root;
    RETURN n;
END $$;

-- ===========================================================================
-- Scenario 1: a planted root orphan WITH a running subtree is fully collected
-- ===========================================================================

-- Start a parallel JOIN: each branch runs as its own sub-orchestration, which
-- has no df.instances row of its own. Orphaning the root then forces reconcile
-- to gather the FULL subtree (root + children) -- deleting only the root would be
-- refused by delete_instances_atomic, leaving the orphan behind. Long branches
-- keep the children running for the duration of the test.
SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _t_orphan (instance_id TEXT);
INSERT INTO _t_orphan
SELECT df.start('SELECT pg_sleep(30)' & 'SELECT pg_sleep(30)', 'reconcile-orphan-victim');
RESET SESSION AUTHORIZATION;

-- Wait until the worker has materialized the root AND at least one child, so the
-- subtree genuinely exists when we reconcile.
DO $$
DECLARE inst_id TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_orphan;
    LOOP
        EXIT WHEN pg_temp.duroxide_child_count(inst_id) >= 1 OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF pg_temp.duroxide_child_count(inst_id) < 1 THEN
        RAISE EXCEPTION 'Setup: orphan victim never spawned a child sub-orchestration';
    END IF;
    RAISE NOTICE 'Setup: orphan victim % has % child sub-orchestration(s)', inst_id, pg_temp.duroxide_child_count(inst_id);
END $$;

-- Orphan it: drop the control-plane rows (superuser bypasses row security).
-- df.instances and df.nodes reference each other, but the FKs are
-- DEFERRABLE INITIALLY DEFERRED, so deleting both in one transaction is fine.
BEGIN;
DELETE FROM df.instances WHERE id          = (SELECT instance_id FROM _t_orphan);
DELETE FROM df.nodes     WHERE instance_id = (SELECT instance_id FROM _t_orphan);
COMMIT;

-- Reconcile with a zero grace window: the orphaned root AND its subtree must be
-- collected.
SELECT df.reconcile(0);

DO $$
DECLARE inst_id TEXT; remaining bigint;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_orphan;
    remaining := pg_temp.duroxide_subtree_count(inst_id);
    IF remaining > 0 THEN
        RAISE EXCEPTION 'TEST FAILED: df.reconcile left % subtree row(s) for orphaned root % (subtree not gathered)', remaining, inst_id;
    END IF;
    RAISE NOTICE 'PASSED [orphan_subtree_collected]: root % and all children removed', inst_id;
END $$;

DROP TABLE _t_orphan;

-- ===========================================================================
-- Scenario 2: a healthy, running instance is left untouched
-- ===========================================================================

SET SESSION AUTHORIZATION df_e2e_user;
CREATE TEMP TABLE _t_live (instance_id TEXT);
INSERT INTO _t_live SELECT df.start('SELECT pg_sleep(3)', 'reconcile-live');
RESET SESSION AUTHORIZATION;

-- Ensure it is running before reconciling.
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_live;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'Setup: live instance never reached running (status=%)', status;
    END IF;
END $$;

-- Reconcile must not disturb a healthy instance (it has a df.instances row).
SELECT df.reconcile(0);

DO $$
DECLARE inst_id TEXT; status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_live;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;
    IF lower(status) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: df.reconcile disturbed a healthy instance % (status=%)', inst_id, status;
    END IF;
    RAISE NOTICE 'PASSED [live_untouched]: % completed normally despite reconcile', inst_id;
END $$;

DROP TABLE _t_live;

SELECT 'TEST PASSED: reconcile orphan GC' AS result;
