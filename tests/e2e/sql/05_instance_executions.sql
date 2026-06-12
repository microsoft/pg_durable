-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression test for issue #168:
--   df.instance_executions() can return no rows for completed instances.
--
-- A completed instance always has at least one execution row in the duroxide
-- store (the instance and its first execution are created in the same
-- transaction). Previously, instance_executions() swallowed any
-- runtime/provider/lookup error into an empty rowset, making "no execution
-- history yet" indistinguishable from "the lookup failed".
--
-- This test guards the contract:
--   * a completed instance exposes >= 1 execution row, and
--   * an invalid limit_count is rejected with an explicit error rather than
--     being silently masked by an empty rowset.
SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_state (instance_id TEXT);

INSERT INTO _test_state SELECT df.start('SELECT 42', 'test-instance-executions-168');

DO $$
DECLARE
    inst_id    TEXT;
    status     TEXT;
    exec_count INT;
    top_exec_id BIGINT;
    top_status TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing instance: %', inst_id;

    SELECT df.wait_for_completion(inst_id) INTO status;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: expected completed, got %', status;
    END IF;

    -- Core assertion (issue #168): a completed instance must expose >= 1 execution.
    SELECT count(*) INTO exec_count FROM df.instance_executions(inst_id, 1);
    IF exec_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: instance_executions(inst_id, 1) returned % rows for a completed instance, expected >= 1', exec_count;
    END IF;

    -- The returned execution should have a valid id and a non-empty status.
    -- We deliberately do NOT assert status = 'completed': df.status() /
    -- wait_for_completion track the pg_durable df.instances table, while
    -- instance_executions reports duroxide's per-execution status. The two are
    -- updated independently and can briefly diverge under concurrent
    -- background-worker load. Issue #168 is about empty rows, not the exact
    -- status string, so asserting row presence + a well-formed status is the
    -- correct, race-free check.
    SELECT e.execution_id, e.status INTO top_exec_id, top_status
    FROM df.instance_executions(inst_id, 1) e;
    IF top_exec_id < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: execution_id should be >= 1, got %', top_exec_id;
    END IF;
    IF top_status IS NULL OR length(trim(top_status)) = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: execution status should be non-empty, got %', coalesce(top_status, '<null>');
    END IF;

    -- The default limit should also return the execution history.
    SELECT count(*) INTO exec_count FROM df.instance_executions(inst_id);
    IF exec_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: instance_executions(inst_id) (default limit) returned % rows, expected >= 1', exec_count;
    END IF;

    RAISE NOTICE 'TEST PASSED: instance_executions returns execution history for a completed instance';
END $$;

-- limit_count < 1 must raise an explicit error, not silently return empty rows.
DO $$
DECLARE
    inst_id   TEXT;
    got_error BOOLEAN := false;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    BEGIN
        PERFORM * FROM df.instance_executions(inst_id, 0);
    EXCEPTION WHEN OTHERS THEN
        got_error := true;
    END;

    IF NOT got_error THEN
        RAISE EXCEPTION 'TEST FAILED: instance_executions(inst_id, 0) should raise an error for limit_count < 1';
    END IF;

    RAISE NOTICE 'TEST PASSED: instance_executions rejects limit_count < 1';
END $$;

DROP TABLE _test_state;

RESET SESSION AUTHORIZATION;
SELECT 'TEST PASSED' AS result;
