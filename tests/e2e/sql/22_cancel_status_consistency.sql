-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: Cancel status consistency across df.status(), df.list_instances(), df.instance_info()
--
-- Regression test for: "cancellation status mismatch between df.status() and df.list_instances()"
-- Root cause: df.list_instances() / df.instance_info() were reading status from duroxide
-- (which reports "Failed"), while df.status() reads from df.instances (which stores "cancelled").
--
-- After the fix all three APIs read status from df.instances, so they always agree.
--
-- Scenarios covered:
--   1. Normal completion  — all APIs report 'completed'
--   2. Failure            — all APIs report 'failed'
--   3. Cancel running     — all APIs report 'cancelled'
--   4. Cancel terminal    — df.cancel on already-completed/failed instance is a no-op

SET SESSION AUTHORIZATION df_e2e_user;

-- Helper: assert that df.status(), df.list_instances(), and df.instance_info() all return
-- the same status value for the given instance.
CREATE OR REPLACE FUNCTION df_e2e_assert_status_consistent(
    p_instance_id TEXT,
    p_expected_status TEXT,
    p_scenario TEXT
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_status          TEXT;
    v_list_status     TEXT;
    v_info_status     TEXT;
BEGIN
    SELECT s INTO v_status      FROM df.status(p_instance_id) s;
    SELECT l.status INTO v_list_status
        FROM df.list_instances() l
        WHERE l.instance_id = p_instance_id;
    SELECT i.status INTO v_info_status
        FROM df.instance_info(p_instance_id) i;

    IF lower(v_status) != lower(p_expected_status) THEN
        RAISE EXCEPTION 'FAILED [%]: df.status() returned %, expected %',
            p_scenario, v_status, p_expected_status;
    END IF;
    IF lower(v_list_status) != lower(p_expected_status) THEN
        RAISE EXCEPTION 'FAILED [%]: df.list_instances() returned %, expected %',
            p_scenario, v_list_status, p_expected_status;
    END IF;
    IF lower(v_info_status) != lower(p_expected_status) THEN
        RAISE EXCEPTION 'FAILED [%]: df.instance_info() returned %, expected %',
            p_scenario, v_info_status, p_expected_status;
    END IF;

    RAISE NOTICE 'PASSED [%]: all three APIs agree on status = %',
        p_scenario, p_expected_status;
END $$;

-- ===========================================================================
-- Scenario 1: Normal completion
-- ===========================================================================

CREATE TEMP TABLE _t_complete (instance_id TEXT);
INSERT INTO _t_complete SELECT df.start('SELECT 42', 'cancel-consistency-complete');

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_complete;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'Scenario 1 setup failed: expected completed, got %', status;
    END IF;

    PERFORM df_e2e_assert_status_consistent(inst_id, 'completed', 'normal_completion');
END $$;

DROP TABLE _t_complete;

-- ===========================================================================
-- Scenario 2: Failure mid-execution
-- ===========================================================================

CREATE TEMP TABLE _t_fail (instance_id TEXT);
INSERT INTO _t_fail SELECT df.start(
    'SELECT 1/0',   -- division by zero --> forces failure
    'cancel-consistency-fail'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_fail;

    -- Poll until failed
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'failed' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'Scenario 2 setup failed: expected failed, got %', status;
    END IF;

    PERFORM df_e2e_assert_status_consistent(inst_id, 'failed', 'failure_mid_execution');
END $$;

DROP TABLE _t_fail;

-- ===========================================================================
-- Scenario 3: Cancel of a running instance
-- ===========================================================================

DROP TABLE IF EXISTS _cancel_log;
CREATE TABLE _cancel_log (id SERIAL);

CREATE TEMP TABLE _t_cancel (instance_id TEXT);
INSERT INTO _t_cancel SELECT df.start(
    df.loop(
        'INSERT INTO _cancel_log DEFAULT VALUES'
        ~> df.sleep(1)
    ),
    'cancel-consistency-running'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    cnt     INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_cancel;

    -- Wait for at least 1 iteration so the loop is genuinely running
    LOOP
        SELECT COUNT(*) INTO cnt FROM _cancel_log;
        EXIT WHEN cnt >= 1 OR attempts > 200;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF cnt < 1 THEN
        RAISE EXCEPTION 'Scenario 3 setup: loop never executed';
    END IF;

    -- Cancel while running
    PERFORM df.cancel(inst_id, 'consistency-test');

    -- df.cancel immediately sets df.instances.status = 'cancelled'.
    -- All three APIs should now agree.
    PERFORM df_e2e_assert_status_consistent(inst_id, 'cancelled', 'cancel_running_instance');
END $$;

DROP TABLE _t_cancel;
DROP TABLE _cancel_log;

-- ===========================================================================
-- Scenario 4: df.cancel on an already-terminal instance is a no-op
-- ===========================================================================

CREATE TEMP TABLE _t_noop (instance_id TEXT);
INSERT INTO _t_noop SELECT df.start('SELECT 99', 'cancel-consistency-noop');

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_noop;

    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'Scenario 4 setup failed: expected completed, got %', status;
    END IF;

    -- Call df.cancel on an already-completed instance — must be a no-op
    PERFORM df.cancel(inst_id, 'should-be-ignored');

    -- Status must remain 'completed'
    PERFORM df_e2e_assert_status_consistent(inst_id, 'completed', 'cancel_noop_on_completed');
END $$;

DROP TABLE _t_noop;

-- Cleanup helper function
DROP FUNCTION IF EXISTS df_e2e_assert_status_consistent(TEXT, TEXT, TEXT);

SELECT 'TEST PASSED: cancel status consistency' AS result;
