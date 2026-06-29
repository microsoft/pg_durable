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

SELECT 'TEST PASSED' AS result;
