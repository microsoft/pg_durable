-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.3 → 0.2.4
--
-- Adds df.assert_structural_invariants(instance_id, fail_on_violation), a sound
-- post-run snapshot oracle that validates a terminal instance's df.nodes against
-- the operational-semantics contract (docs/dsl-semantics.md). It returns one row
-- per invariant when all hold, or one row per offending node when violated, and
-- can raise on violation (fail_on_violation => true) so tests can assert in one
-- line. Read-only and RLS-scoped — it only inspects instances visible to the
-- caller. Backward-compatible: it reads only long-present df.nodes / df.instances
-- columns and needs no runtime schema detection.
--
-- The CREATE FUNCTION block below mirrors exactly what a fresh 0.2.4 install
-- generates (pgrx-emitted DDL), so the upgraded catalog matches a fresh one.
--
-- df.grant_usage() is re-emitted (CREATE OR REPLACE) with the new function added
-- to its func_sigs list, so that delegated roles granted via df.grant_usage()
-- on an upgraded install also receive EXECUTE on the new diagnostic function.

-- pgspot's SQL security gate (scripts/pgspot-gate.sh) trusts a schema named in a
-- function's SET search_path only when that schema is created in the same script
-- (pgspot state.py is_secure_searchpath). df already exists on any install being
-- upgraded, so this IF NOT EXISTS is a harmless runtime no-op; it is present so the
-- df.grant_usage() re-emit below -- which relies on SET search_path = pg_catalog,
-- df, pg_temp -- is recognized as secure by the gate, exactly as the fresh-install
-- SQL achieves it (pgrx emits CREATE SCHEMA IF NOT EXISTS df there). The resulting
-- PS010 finding for df is on the gate's allowlist.
CREATE SCHEMA IF NOT EXISTS df;

/* <begin connected objects> */
-- pg_durable::invariants::assert_structural_invariants
CREATE  FUNCTION df."assert_structural_invariants"(
"instance_id" TEXT, /* &str */
"fail_on_violation" bool DEFAULT false /* bool */
) RETURNS TABLE (
"invariant" TEXT,  /* alloc::string::String */
"passed" bool,  /* bool */
"node_id" TEXT,  /* core::option::Option<alloc::string::String> */
"detail" TEXT  /* core::option::Option<alloc::string::String> */
)
STRICT
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'assert_structural_invariants_wrapper';
/* </end connected objects> */

-- Re-emit df.grant_usage() so its func_sigs list includes the new
-- df.assert_structural_invariants(text, boolean) function. Without this, a role
-- granted access via df.grant_usage() on an upgraded install would not receive
-- EXECUTE on the new function. The body is identical to the fresh-install
-- definition in src/lib.rs aside from the added func_sig.
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
    -- Explicit list of df.* functions to grant.  Sensitive functions
    -- (df.http, df.grant_usage, df.revoke_usage) are excluded from this
    -- list and granted conditionally below.
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
        'df.metrics()',
        -- Internal helpers (operators, version, etc.)
        'df.as_op(text, text)',
        'df.if_then_op(text, text)',
        'df.if_else_op(text, text)',
        'df.ensure_durofut(text)',
        'df.loop_prefix_op(text)',
        'df.version()',
        'df.debug_connection()',
        'df.explain(text)',
        'df.assert_structural_invariants(text, boolean)',
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
