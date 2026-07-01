-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: df.instance_nodes() derived `inferred_status` column.
--   1. Untaken df.if() arm           --> inferred_status = 'skipped'
--   2. Right side of a failed df.then() (~>) --> inferred_status = 'skipped'
--   3. Fully-completed sequence       --> no 'skipped', inferred matches physical status
SET SESSION AUTHORIZATION df_e2e_user;

-- === Test 1: untaken IF arm is reported as skipped ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Condition is true, so the THEN arm runs and the ELSE arm is never executed.
INSERT INTO _test_state SELECT df.start(
    df.if('SELECT true', 'SELECT 1', 'SELECT 2'),
    'test-inferred-if'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    skipped_count INT;
    skipped_physical TEXT;
    skipped_ancestor TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.await_instance(inst_id) INTO status;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [if]: status = %', status;
    END IF;

    -- Exactly one node (the untaken ELSE arm) must be inferred as skipped.
    SELECT count(*) INTO skipped_count
    FROM df.instance_nodes(inst_id)
    WHERE inferred_status = 'skipped';

    IF skipped_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [if]: expected exactly 1 skipped node, got %', skipped_count;
    END IF;

    -- The skipped node never physically ran and points at an ancestor.
    SELECT n.status, n.inferred_status_from_ancestor_id
      INTO skipped_physical, skipped_ancestor
    FROM df.instance_nodes(inst_id) n
    WHERE n.inferred_status = 'skipped';

    IF skipped_physical != 'pending' THEN
        RAISE EXCEPTION 'TEST FAILED [if]: skipped node physical status = % (expected pending)', skipped_physical;
    END IF;

    IF skipped_ancestor IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED [if]: skipped node has NULL inferred_status_from_ancestor_id';
    END IF;

    -- df.explain() shares the same inference and must render the skipped marker (⊘).
    IF df.explain(inst_id) NOT LIKE '%⊘%' THEN
        RAISE EXCEPTION 'TEST FAILED [if]: df.explain() did not show the skipped (⊘) marker: %', df.explain(inst_id);
    END IF;

    RAISE NOTICE 'TEST PASSED: inferred_status if-untaken-skipped';
END $$;

DROP TABLE _test_state;

-- === Test 2: right side of a failed df.then() is reported as skipped ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Left node divides by zero and fails; the right node must never run.
INSERT INTO _test_state SELECT df.start(
    'SELECT 1/0' ~> 'SELECT 42',
    'test-inferred-then-fail'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    failed_inferred TEXT;
    skipped_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.await_instance(inst_id) INTO status;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [then-fail]: status = %', status;
    END IF;

    -- The failing node keeps its physical 'failed' status.
    SELECT n.inferred_status INTO failed_inferred
    FROM df.instance_nodes(inst_id) n
    WHERE n.status = 'failed';

    IF failed_inferred != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [then-fail]: failing node inferred_status = % (expected failed)', failed_inferred;
    END IF;

    -- The right (never-run) node is reported as skipped.
    SELECT count(*) INTO skipped_count
    FROM df.instance_nodes(inst_id)
    WHERE inferred_status = 'skipped';

    IF skipped_count != 1 THEN
        RAISE EXCEPTION 'TEST FAILED [then-fail]: expected exactly 1 skipped node, got %', skipped_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: inferred_status then-failure-skipped';
END $$;

DROP TABLE _test_state;

-- === Test 3: fully-completed sequence has no skipped nodes ===

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    'SELECT 1' ~> 'SELECT 2',
    'test-inferred-seq-ok'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    skipped_count INT;
    mismatch_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.await_instance(inst_id) INTO status;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [seq-ok]: status = %', status;
    END IF;

    SELECT count(*) INTO skipped_count
    FROM df.instance_nodes(inst_id)
    WHERE inferred_status = 'skipped';

    IF skipped_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [seq-ok]: expected 0 skipped nodes, got %', skipped_count;
    END IF;

    -- For a clean completion, inferred_status mirrors the physical status.
    SELECT count(*) INTO mismatch_count
    FROM df.instance_nodes(inst_id) n
    WHERE n.status IS NOT NULL AND n.inferred_status != n.status;

    IF mismatch_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [seq-ok]: % nodes have inferred_status != status', mismatch_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: inferred_status completed-sequence';
END $$;

DROP TABLE _test_state;

-- === Test 4: non-root loop — untaken IF arm in the body is skipped, nothing stuck running ===
--
-- A non-root loop runs as a child sub-orchestration that re-stamps its body nodes every
-- generation under a scope whose trailing `::`-token is the loop's inner generation. The
-- derived status must be SCOPE-AWARE: after the loop completes, the untaken ELSE arm inside
-- the body reads 'skipped', the loop node reads 'completed', and no node is left inferred as
-- 'running' (older-generation body stamps are superseded, not surfaced as in-flight).

DROP TABLE IF EXISTS test_inferred_loop_body;
CREATE TABLE test_inferred_loop_body (id SERIAL, ts TIMESTAMPTZ DEFAULT clock_timestamp());

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start(
    df.seq(
        'SELECT 1',
        df.loop(
            df.if(
                'SELECT true',
                'INSERT INTO test_inferred_loop_body DEFAULT VALUES',
                'SELECT 999'
            )
            ~> (
                'SELECT COUNT(*) >= 2 FROM test_inferred_loop_body'
                    ?> df.break()
                    !> df.sleep(1)
            )
        )
    ),
    'test-inferred-nonroot-loop'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    skipped_count INT;
    running_count INT;
    loop_inferred TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    SELECT df.wait_for_completion(inst_id, 90) INTO status;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-loop-inferred]: status = %', status;
    END IF;

    -- The untaken ELSE arm ('SELECT 999') never runs in any generation → skipped.
    SELECT count(*) INTO skipped_count
    FROM df.instance_nodes(inst_id)
    WHERE inferred_status = 'skipped';

    IF skipped_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-loop-inferred]: expected >= 1 skipped node, got %', skipped_count;
    END IF;

    -- After completion nothing may be reported as still running (superseded older-generation
    -- body stamps must not surface as in-flight).
    SELECT count(*) INTO running_count
    FROM df.instance_nodes(inst_id)
    WHERE inferred_status = 'running';

    IF running_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-loop-inferred]: % node(s) still inferred running after completion', running_count;
    END IF;

    -- The loop node itself is stamped completed by its child sub-orchestration on exit.
    SELECT n.inferred_status INTO loop_inferred
    FROM df.instance_nodes(inst_id) n
    WHERE lower(n.node_type) = 'loop';

    IF loop_inferred != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [nonroot-loop-inferred]: loop node inferred_status = % (expected completed)', loop_inferred;
    END IF;

    RAISE NOTICE 'TEST PASSED: inferred_status non-root-loop-scope-aware';
END $$;

DROP TABLE _test_state;
DROP TABLE test_inferred_loop_body;

SELECT 'TEST PASSED' AS result;
