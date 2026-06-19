-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Tests: authorization and hardening on the in-transaction enqueue wrappers.
--
-- The df._enqueue_orchestrator_* functions are SECURITY DEFINER (the runtime
-- queue is writable by its owner only) and granted to every df user via
-- df.grant_usage(). They must therefore refuse to enqueue work against an
-- instance the caller does not own, and the start wrapper must not become a
-- generic "start any internal orchestration with arbitrary input" primitive.
-- Cancel/signal ownership is checked with pg_has_role(session_user,
-- <instance owner>, 'MEMBER'): session_user cannot be spoofed inside a
-- SECURITY DEFINER function, and membership lets a role that owns the instance
-- through SET ROLE still qualify.
--
-- Without the change these wrappers do not exist, so the forge attempts below
-- raise undefined_function and the test fails.

-- Fresh, non-superuser roles. (Superusers bypass pg_has_role, so the denial can
-- only be exercised by a non-superuser caller.)
DO $precleanup$
DECLARE
    inst_id TEXT;
BEGIN
    -- A failed/interrupted prior run can leave a loop instance submitted by one
    -- of these roles. Cancel it before DROP ROLE so the worker stops reconnecting
    -- as that role while this test rebuilds privileges.
    FOR inst_id IN
        SELECT i.id
        FROM df.instances i
        JOIN pg_catalog.pg_roles r ON r.oid = i.submitted_by::oid
        WHERE r.rolname IN ('authz_owner', 'authz_other')
          AND i.status NOT IN ('completed', 'failed', 'cancelled')
    LOOP
        PERFORM df.cancel(inst_id, 'authz-test-precleanup');
    END LOOP;
END $precleanup$;

SELECT pg_sleep(0.5);

DO $setup$
BEGIN
    BEGIN DROP OWNED BY authz_owner; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY authz_other; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE authz_owner; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE authz_other; EXCEPTION WHEN undefined_object THEN NULL; END;
END $setup$;

CREATE ROLE authz_owner LOGIN;
CREATE ROLE authz_other LOGIN;
SELECT df.grant_usage('authz_owner');
SELECT df.grant_usage('authz_other');

-- The owner starts a long-running instance.
SET SESSION AUTHORIZATION authz_owner;
CREATE TEMP TABLE _t_authz (instance_id TEXT);
INSERT INTO _t_authz
SELECT df.start(df.loop(df.seq('SELECT 1', df.sleep(1))), 'authz-owner-inst');
RESET SESSION AUTHORIZATION;

-- Let the non-owner read the instance id (so the forge attempts can target it).
GRANT SELECT ON _t_authz TO authz_other;

-- Wait until it is running.
DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_authz;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'running' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(status) <> 'running' THEN
        RAISE EXCEPTION 'Setup: owner instance never reached running (status=%)', status;
    END IF;
END $$;

-- ===========================================================================
-- A non-owner cannot forge a cancel/signal against the owner's instance.
-- ===========================================================================

SET SESSION AUTHORIZATION authz_other;
DO $$
DECLARE inst_id TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_authz;

    -- Forge a cancel.
    BEGIN
        PERFORM df._enqueue_orchestrator_cancel(inst_id, 'forged');
        RAISE EXCEPTION 'TEST FAILED: authz_other was allowed to enqueue a cancel for owner instance %', inst_id;
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM LIKE '%not authorized%' THEN
                RAISE NOTICE 'PASSED [cancel_forge_denied]: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST FAILED: cancel denied, but not by the wrapper authorization check: %', SQLERRM;
            END IF;
        WHEN undefined_function THEN
            RAISE EXCEPTION 'TEST FAILED: df._enqueue_orchestrator_cancel is missing (change not present): %', SQLERRM;
    END;

    -- Forge a signal.
    BEGIN
        PERFORM df._enqueue_orchestrator_signal(inst_id, 'go', '{}');
        RAISE EXCEPTION 'TEST FAILED: authz_other was allowed to enqueue a signal for owner instance %', inst_id;
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM LIKE '%not authorized%' THEN
                RAISE NOTICE 'PASSED [signal_forge_denied]: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST FAILED: signal denied, but not by the wrapper authorization check: %', SQLERRM;
            END IF;
        WHEN undefined_function THEN
            RAISE EXCEPTION 'TEST FAILED: df._enqueue_orchestrator_signal is missing (change not present): %', SQLERRM;
    END;
END $$;
RESET SESSION AUTHORIZATION;

-- =========================================================================== 
-- A caller cannot use the start wrapper as a generic privileged entrypoint.
-- =========================================================================== 

SET SESSION AUTHORIZATION authz_other;
DO $$
DECLARE
    inst_id CONSTANT TEXT := 'feedf00d';
    root_id CONSTANT TEXT := 'deadbeef';
BEGIN
    -- Create a legitimate brand-new, pending instance owned by authz_other. The
    -- start wrapper's state check should pass for this row; the test verifies
    -- the wrapper still rejects a non-root internal orchestration name.
    INSERT INTO df.instances (id, label, root_node, submitted_by, database)
    VALUES (inst_id, 'authz-start-wrapper-hardening', root_id, current_user::regrole, 'postgres');

    INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, database)
    VALUES (root_id, inst_id, 'SQL', 'SELECT 1', current_user::regrole, 'postgres');

    BEGIN
        PERFORM df._enqueue_orchestrator_start(
            inst_id,
            'pg_durable::orchestration::execute-subtree',
            json_build_object('instance_id', inst_id)::text);
        RAISE EXCEPTION 'TEST FAILED: start wrapper accepted a non-root orchestration for instance %', inst_id;
    EXCEPTION
        WHEN invalid_parameter_value THEN
            IF SQLERRM LIKE '%invalid start orchestration%' THEN
                RAISE NOTICE 'PASSED [start_wrapper_rejects_internal_orchestration]: %', SQLERRM;
            ELSE
                RAISE EXCEPTION 'TEST FAILED: start wrapper rejected with an unexpected validation error: %', SQLERRM;
            END IF;
        WHEN undefined_function THEN
            RAISE EXCEPTION 'TEST FAILED: df._enqueue_orchestrator_start is missing (change not present): %', SQLERRM;
    END;
END $$;
RESET SESSION AUTHORIZATION;

BEGIN;
DELETE FROM df.instances WHERE id = 'feedf00d';
DELETE FROM df.nodes WHERE instance_id = 'feedf00d';
COMMIT;

-- ===========================================================================
-- The owner can still cancel its own instance (the authorized path works).
-- ===========================================================================

SET SESSION AUTHORIZATION authz_owner;
SELECT df.cancel((SELECT instance_id FROM _t_authz), 'owner-cancel');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE inst_id TEXT; status TEXT; attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _t_authz;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) = 'cancelled' OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    IF lower(status) <> 'cancelled' THEN
        RAISE EXCEPTION 'TEST FAILED: owner could not cancel its own instance % (status=%)', inst_id, status;
    END IF;
    RAISE NOTICE 'PASSED [owner_cancel_allowed]: instance % cancelled by its owner', inst_id;
END $$;

DROP TABLE _t_authz;

-- Cleanup roles.
DO $cleanup$
BEGIN
    BEGIN DROP OWNED BY authz_owner; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP OWNED BY authz_other; EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE authz_owner;     EXCEPTION WHEN undefined_object THEN NULL; END;
    BEGIN DROP ROLE authz_other;     EXCEPTION WHEN undefined_object THEN NULL; END;
END $cleanup$;

SELECT 'TEST PASSED: enqueue wrapper authorization' AS result;
