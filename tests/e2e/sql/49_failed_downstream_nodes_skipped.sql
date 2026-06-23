-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- E2E Test: downstream nodes are marked 'skipped' after node-level failure.

SET SESSION AUTHORIZATION df_e2e_user;

-- ============================================================================
-- Test 1: THEN chain failure marks downstream SQL node as skipped
-- ============================================================================

CREATE TEMP TABLE _test_skip1 (instance_id TEXT);

INSERT INTO _test_skip1
SELECT df.start(
    df.sql($$SELECT 'skip-test-step1'::text$$)
    ~> df.sql($$SELECT 1/0$$)
    ~> df.sql($$SELECT 'skip-test-step3'::text$$),
    'test-failed-downstream-skipped-seq'
);

DO $$
DECLARE
    inst_id TEXT;
    wf_status TEXT;
    step1_status TEXT;
    fail_status TEXT;
    step3_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_skip1;
    SELECT df.await_instance(inst_id) INTO wf_status;

    IF lower(wf_status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-seq]: expected failed, got %', wf_status;
    END IF;

    SELECT status INTO step1_status
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'SQL' AND query = 'SELECT ''skip-test-step1''::text'
    LIMIT 1;

    IF step1_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-seq]: step1 expected completed, got %', step1_status;
    END IF;

    SELECT status INTO fail_status
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'SQL' AND query = 'SELECT 1/0'
    LIMIT 1;

    IF fail_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-seq]: failing step expected failed, got %', fail_status;
    END IF;

    SELECT status INTO step3_status
    FROM df.nodes
    WHERE instance_id = inst_id AND node_type = 'SQL' AND query = 'SELECT ''skip-test-step3''::text'
    LIMIT 1;

    IF step3_status != 'skipped' THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-seq]: downstream step expected skipped, got %', step3_status;
    END IF;

    RAISE NOTICE 'TEST PASSED: skipped status on failed sequence';
END $$;

DROP TABLE _test_skip1;

-- ============================================================================
-- Test 2: IF condition failure marks both branches as skipped
-- ============================================================================

CREATE TEMP TABLE _test_skip2 (instance_id TEXT);

INSERT INTO _test_skip2
SELECT df.start(
    df.if(
        $$SELECT 1/0$$,
        $$SELECT 'skip-then-branch'::text$$,
        $$SELECT 'skip-else-branch'::text$$
    ),
    'test-failed-downstream-skipped-if'
);

DO $$
DECLARE
    inst_id TEXT;
    wf_status TEXT;
    skipped_branch_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_skip2;
    SELECT df.await_instance(inst_id) INTO wf_status;

    IF lower(wf_status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-if]: expected failed, got %', wf_status;
    END IF;

    SELECT COUNT(*) INTO skipped_branch_count
    FROM df.nodes
    WHERE instance_id = inst_id
      AND node_type = 'SQL'
      AND query IN ('SELECT ''skip-then-branch''::text', 'SELECT ''skip-else-branch''::text')
      AND status = 'skipped';

    IF skipped_branch_count != 2 THEN
        RAISE EXCEPTION 'TEST FAILED [skipped-if]: expected 2 skipped branches, got %', skipped_branch_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: skipped status on IF branches after condition failure';
END $$;

DROP TABLE _test_skip2;

SELECT 'TEST PASSED' AS result;
