-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression tests for: df.loop nested INSIDE a JOIN or RACE branch
-- (https://github.com/microsoft/pg_durable/issues/233)
--
-- A loop nested inside a parallel branch is a non-root loop, so it runs as its own child
-- sub-orchestration spawned by the branch's subtree orchestration.  Its instance id embeds
-- the branch lineage, so it gets a distinct durable instance and continue_as_new restarts
-- only the loop body (not the branch).  Before the fix this raised
-- "Missing graph in ExecuteSubtree input" / failed to iterate.

SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: loop inside a JOIN branch, loop iterates >= 2 ===
--
-- Graph: df.loop(body, break after 2) & 'SELECT sibling'
-- Expected: completes, loop body ran exactly 2 times, sibling branch ran once.

DROP TABLE IF EXISTS test_joinloop_body;
DROP TABLE IF EXISTS test_joinloop_sibling;
CREATE TABLE test_joinloop_body    (id SERIAL, iteration INT, ts TIMESTAMPTZ DEFAULT clock_timestamp());
CREATE TABLE test_joinloop_sibling (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t1 AS
SELECT df.start(
    (
        df.loop(
            'INSERT INTO test_joinloop_body (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_joinloop_body))'
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_joinloop_body'
                    ?> df.break()
                    !> df.sleep(1)
            )
        )
        & 'INSERT INTO test_joinloop_sibling DEFAULT VALUES'
    ),
    'test-loop-in-join-branch'
) AS instance_id;

DO $$
DECLARE
    v_id      TEXT;
    v_status  TEXT;
    v_body    INT;
    v_sibling INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t1;
    RAISE NOTICE 'Test 1 - loop inside JOIN branch: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [join-loop]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_body    FROM test_joinloop_body;
    SELECT COUNT(*) INTO v_sibling FROM test_joinloop_sibling;

    IF v_body != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [join-loop]: loop body ran % time(s) (expected 2)', v_body;
    END IF;

    IF v_sibling != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [join-loop]: sibling branch ran % time(s) (expected 1)', v_sibling;
    END IF;

    RAISE NOTICE 'PASSED: loop inside JOIN branch — loop iterated twice, sibling ran once';
END $$;

DROP TABLE _t1;
DROP TABLE test_joinloop_body;
DROP TABLE test_joinloop_sibling;

-- === Test 2: loop inside a RACE branch, loop iterates >= 2 and wins ===
--
-- Graph: df.race( df.loop(body, break after 2), 'SELECT pg_sleep(30)' )
-- The loop completes after 2 iterations (a few seconds) and wins the race against the slow
-- branch.  Expected: completes, loop body ran exactly 2 times.

DROP TABLE IF EXISTS test_raceloop_body;
CREATE TABLE test_raceloop_body (id SERIAL, iteration INT, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t2 AS
SELECT df.start(
    df.race(
        df.loop(
            'INSERT INTO test_raceloop_body (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_raceloop_body))'
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_raceloop_body'
                    ?> df.break()
                    !> df.sleep(1)
            )
        ),
        'SELECT pg_sleep(30)'
    ),
    'test-loop-in-race-branch'
) AS instance_id;

DO $$
DECLARE
    v_id     TEXT;
    v_status TEXT;
    v_body   INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t2;
    RAISE NOTICE 'Test 2 - loop inside RACE branch: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;

    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [race-loop]: expected completed, got %', v_status;
    END IF;

    SELECT COUNT(*) INTO v_body FROM test_raceloop_body;

    IF v_body != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [race-loop]: loop body ran % time(s) (expected 2)', v_body;
    END IF;

    RAISE NOTICE 'PASSED: loop inside RACE branch — loop iterated twice and won the race';
END $$;

DROP TABLE _t2;
DROP TABLE test_raceloop_body;

-- === Test 3: topology — race(loop, sleep) spawns 1 parent + 2 subs (loop not double-wrapped) ===
--
-- Same shape as Test 2 (a RACE at the root; left = df.loop(sleep), right = a sleep) but this
-- time we assert the *orchestration topology* rather than the behaviour:
--   * parent           : the function-graph orchestration (RACE is its root node)
--   * loop sub         : spawned DIRECTLY as an execute-loop child, because the loop is
--                        already the root of its own branch orchestration
--   * right-branch sub : an execute-subtree wrapping the sleep
--
-- The loop branch must NOT be double-wrapped (execute-subtree -> execute-loop): doing so
-- would create a third sub-orchestration for the single loop branch.  We verify the loop's
-- own node is stamped by an orchestration instance that is a *direct* child of the parent,
-- i.e. `{parent}::1::{loop_node_id}` — not `{parent}::1::{loop_node_id}::1::{loop_node_id}`.
--
-- The stamp recorded in df.nodes.status_details->>'execution_id' has the shape
-- `{orchestration_instance_id}::{execution_id}`, and an orchestration instance id is itself
-- `{parent}::{parent_execution_id}::{branch_root_node_id}` for a spawned child.

DROP TABLE IF EXISTS test_topo_log;
CREATE TABLE test_topo_log (id SERIAL, iteration INT, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _t3 AS
SELECT df.start(
    df.race(
        df.loop(
            'INSERT INTO test_topo_log (iteration) VALUES ((SELECT COALESCE(MAX(iteration), 0) + 1 FROM test_topo_log))'
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_topo_log'
                    ?> df.break()
                    !> df.sleep(1)
            )
        ),
        'SELECT pg_sleep(30)'
    ),
    'test-loop-in-race-topology'
) AS instance_id;

DO $$
DECLARE
    v_id            TEXT;
    v_status        TEXT;
    v_loop_node     TEXT;
    v_loop_scope    TEXT;
    v_body_scope    TEXT;
    v_expected      TEXT;
    v_distinct_orch INT;
BEGIN
    SELECT instance_id INTO v_id FROM _t3;
    RAISE NOTICE 'Test 3 - race(loop, sleep) topology: instance %', v_id;

    SELECT df.wait_for_completion(v_id, 90) INTO v_status;
    IF v_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [topo]: expected completed, got %', v_status;
    END IF;

    -- The loop node id is the root of the loop sub-orchestration.
    SELECT id INTO v_loop_node
      FROM df.nodes
     WHERE instance_id = v_id AND node_type = 'LOOP';

    -- Strip the trailing ::<generation> token from the loop node's stamp to recover the
    -- loop sub-orchestration's instance id.
    SELECT substring(status_details->>'execution_id' FROM '^(.*)::[0-9]+$')
      INTO v_loop_scope
      FROM df.nodes
     WHERE instance_id = v_id AND id = v_loop_node;

    -- A directly-spawned loop child runs in `{parent}::1::{loop_node_id}`.  A double-wrapped
    -- loop (subtree -> loop) would instead read `{parent}::1::{loop_node_id}::1::{loop_node_id}`.
    v_expected := v_id || '::1::' || v_loop_node;
    IF v_loop_scope IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'TEST FAILED [topo]: loop sub-orchestration id = % (expected %); loop was double-wrapped',
            v_loop_scope, v_expected;
    END IF;

    -- The loop body (the INSERT SQL node) must run inside the SAME loop sub-orchestration.
    SELECT substring(status_details->>'execution_id' FROM '^(.*)::[0-9]+$')
      INTO v_body_scope
      FROM df.nodes
     WHERE instance_id = v_id
       AND node_type = 'SQL'
       AND query LIKE 'INSERT INTO test_topo_log%';
    IF v_body_scope IS DISTINCT FROM v_loop_scope THEN
        RAISE EXCEPTION 'TEST FAILED [topo]: loop body scope = % (expected loop scope %)',
            v_body_scope, v_loop_scope;
    END IF;

    -- Count distinct orchestration instances that stamped any node of this instance.
    -- Correct topology = 3 (parent RACE + loop sub + right-branch subtree).  A double-wrapped
    -- loop would add a fourth (the redundant subtree wrapper around the loop), so <= 3 is the
    -- regression guard.  (The abandoned right branch reliably stamps its node 'running' before
    -- the race is decided, so 3 is what we observe.)
    SELECT count(DISTINCT substring(status_details->>'execution_id' FROM '^(.*)::[0-9]+$'))
      INTO v_distinct_orch
      FROM df.nodes
     WHERE instance_id = v_id
       AND status_details->>'execution_id' IS NOT NULL;

    IF v_distinct_orch > 3 THEN
        RAISE EXCEPTION 'TEST FAILED [topo]: % distinct orchestration scopes (> 3 means the loop branch was double-wrapped)', v_distinct_orch;
    END IF;

    IF v_distinct_orch < 2 THEN
        RAISE EXCEPTION 'TEST FAILED [topo]: % distinct orchestration scopes (expected parent + loop sub at minimum)', v_distinct_orch;
    END IF;

    RAISE NOTICE 'PASSED: race(loop, sleep) = 1 parent + 2 subs; loop spawned directly (% distinct scopes)', v_distinct_orch;
END $$;

DROP TABLE _t3;
DROP TABLE test_topo_log;

SELECT 'TEST PASSED' AS result;
