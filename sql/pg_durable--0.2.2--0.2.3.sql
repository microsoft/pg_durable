-- pg_durable upgrade: 0.2.2 → 0.2.3
--
-- Security: restrict df.metrics() to superusers only.
--
-- df.metrics() returns system-wide aggregate instance/execution/event counts
-- from the duroxide store without any per-user filtering.  Exposing these
-- counts to all users is an information-disclosure risk (security review
-- Finding 6, severity: Low) — aggregate counts reveal system-wide usage
-- patterns across all users.
--
-- Fix:
--   1. Revoke EXECUTE on df.metrics() from all non-superuser roles that
--      already hold it (received via a prior call to df.grant_usage()).
--   2. Replace df.grant_usage() with a version that omits df.metrics()
--      from its standard privilege set.
--
-- After this upgrade:
--   * df.metrics() is callable only by superusers (they bypass ACL checks).
--   * Non-superusers receive a permission-denied error with a hint to use
--     df.list_instances() for a summary of their own workflows.
--   * Future calls to df.grant_usage() will not re-grant df.metrics().

-- ----------------------------------------------------------------------------
-- Step 1: Revoke df.metrics() EXECUTE from existing non-superuser grantees.
-- ----------------------------------------------------------------------------
-- Revoke from any role that previously received EXECUTE via df.grant_usage()
-- or a direct manual GRANT.  Superusers are excluded because they bypass ACL
-- checks and do not need an explicit EXECUTE grant.
DO $$
DECLARE
    r TEXT;
BEGIN
    FOR r IN
        SELECT DISTINCT grantee::text
        FROM information_schema.role_routine_grants
        WHERE specific_schema = 'df'
          AND routine_name = 'metrics'
          AND privilege_type = 'EXECUTE'
          AND grantee NOT IN (
              SELECT rolname FROM pg_catalog.pg_roles WHERE rolsuper = true
          )
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION df.metrics() FROM %I', r);
    END LOOP;
END $$;

-- Also revoke from PUBLIC (belt-and-suspenders; the install SQL already does
-- this, but repeating ensures correctness if a manual GRANT TO PUBLIC was issued).
REVOKE EXECUTE ON FUNCTION df.metrics() FROM PUBLIC;

-- ----------------------------------------------------------------------------
-- Step 2: Replace df.grant_usage() — remove df.metrics() from func_sigs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION df.grant_usage(
    p_role TEXT,
    include_http boolean DEFAULT false,
    with_grant boolean DEFAULT false
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, df, pg_temp
AS $fn$
DECLARE
    grant_opt TEXT := '';
    func_sig TEXT;
    -- Explicit list of df.* functions to grant.  Sensitive/admin-only functions
    -- (df.http, df.grant_usage, df.revoke_usage, df.metrics) are excluded from
    -- this list and granted conditionally below.
    func_sigs TEXT[] := ARRAY[
        -- DSL functions
        'df.sql(text)',
        'df.seq(text, text)',
        'df.as(text, text)',
        'df.sleep(bigint)',
        'df.wait_for_schedule(text)',
        'df.loop(text, text)',
        'df.break(text)',
        'df.if(text, text, text)',
        'df.if_rows(text, text, text)',
        'df.join(text, text)',
        'df.join3(text, text, text)',
        'df.race(text, text)',
        'df.wait_for_signal(text, integer)',
        'df.signal(text, text, text)',
        'df.start(text, text, text)',
        'df.setvar(text, text)',
        'df.getvar(text)',
        'df.unsetvar(text)',
        'df.clearvars()',
        -- Monitoring functions
        'df.status(text)',
        'df.result(text)',
        'df.cancel(text, text)',
        'df.wait_for_completion(text, integer)',
        'df.run(text)',
        'df.list_instances(text, integer)',
        'df.instance_info(text)',
        'df.instance_nodes(text, integer)',
        'df.instance_executions(text, integer)',
        -- Internal helpers (operators, version, etc.)
        'df.as_op(text, text)',
        'df.if_then_op(text, text)',
        'df.if_else_op(text, text)',
        'df.ensure_durofut(text)',
        'df.loop_prefix_op(text)',
        'df.version()',
        'df.debug_connection()',
        'df.explain(text)',
        'df.target_database()'
    ];
BEGIN
    -- Validate the role exists
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'role "%" does not exist', p_role;
    END IF;

    IF with_grant THEN
        grant_opt := ' WITH GRANT OPTION';
    END IF;

    -- Schema access
    EXECUTE format('GRANT USAGE ON SCHEMA df TO %I', p_role) || grant_opt;

    -- Grant EXECUTE on each standard function explicitly.
    FOREACH func_sig IN ARRAY func_sigs LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', func_sig, p_role) || grant_opt;
    END LOOP;

    -- df.http() — opt-in because it makes outbound network requests.
    IF include_http THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO %I', p_role) || grant_opt;
    END IF;

    -- Admin helpers — only for delegated administrators.
    IF with_grant THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) TO %I', p_role) || grant_opt;
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO %I', p_role) || grant_opt;
    END IF;

    -- Table privileges
    EXECUTE format('GRANT SELECT ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT UPDATE (status, updated_at) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, label, root_node, submitted_by, database) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO %I', p_role) || grant_opt;

    RAISE NOTICE 'pg_durable: granted df usage privileges to "%"', p_role;
END;
$fn$;
