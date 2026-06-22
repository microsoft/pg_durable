-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.3 → 0.2.4
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).

-- ============================================================================
-- Remove df.debug_connection() (issue #110, reclassified non-security cleanup).
--
-- The function returned the worker connection string (postgres://role@host:port/db)
-- — no password or credential. The worker role is already exposed to any role
-- through native PostgreSQL channels (the world-readable pg_durable.worker_role
-- GUC and pg_stat_activity.usename — see security-review item I-6); the remaining
-- fields (database, host/port, schema) are connection-topology metadata, not
-- secrets (the host comes from PGHOST, defaulting to loopback). It is dropped
-- purely to shrink the public function surface and future-proof against the
-- connection builder ever gaining a secret.
--
-- The background worker builds its connection from the internal Rust helper, not
-- this SQL function, so dropping it changes no runtime behavior. The new .so
-- keeps the underlying C symbol (debug_connection_wrapper) compiled in via a
-- #[pg_extern(sql = false)] shim, so pre-0.2.4 schemas still resolve the function
-- until ALTER EXTENSION UPDATE runs (Scenario B1). df.grant_usage() no longer
-- references this function — its per-function allowlist is removed in this same
-- release (see below) — so the drop needs no further grant_usage change.
-- ============================================================================
DROP FUNCTION IF EXISTS df.debug_connection();

-- ============================================================================
-- Simplify df.grant_usage(): drop the explicit per-function allowlist.
--
-- The previous body looped over a hard-coded list of df.* function signatures
-- and issued GRANT EXECUTE on each. That list was redundant: the ordinary
-- df.* functions retain PostgreSQL's default PUBLIC EXECUTE privilege, so the
-- real access gate is USAGE on schema df (granted below). The list added no
-- access boundary while requiring maintenance on every new function and
-- masquerading as a security allowlist.
--
-- The sensitive functions (df.http, df.grant_usage, df.revoke_usage) have
-- PUBLIC EXECUTE revoked; df.http and the admin helpers are granted explicitly
-- here when requested. The updated body also grants df.metrics() (system-wide
-- aggregate counts) to with_grant => true admins.
--
-- Unlike a fresh 0.2.4 install, this upgrade does NOT revoke df.metrics()'s
-- PUBLIC EXECUTE. Making df.metrics() private by default is a posture change for
-- new installs; existing admins who want it locked down have already revoked the
-- PUBLIC grant themselves, so we leave this install's grants as they are.
--
-- This CREATE OR REPLACE otherwise brings pre-existing installs in line with
-- fresh 0.2.4 installs (see src/lib.rs). The new body works against the existing
-- schema and changes no privileges already granted.
-- ============================================================================
CREATE OR REPLACE FUNCTION df.grant_usage(
    p_role TEXT,
    include_http boolean DEFAULT false,
    with_grant boolean DEFAULT false
)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    grant_opt TEXT := '';
BEGIN
    IF with_grant THEN
        grant_opt := ' WITH GRANT OPTION';
    END IF;

    -- Schema access — the access gate for ordinary df.* functions (see header).
    EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA df TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;

    -- df.http() — opt-in because it makes outbound network requests.
    IF include_http THEN
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    END IF;

    -- Admin helpers and system-wide metrics — with_grant => true marks a
    -- pg_durable admin, so it also grants df.metrics() (cluster-wide aggregate
    -- counts).
    IF with_grant THEN
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.metrics() TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    END IF;

    -- Table privileges
    EXECUTE pg_catalog.format('GRANT SELECT ON df.instances TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT UPDATE (status, updated_at) ON df.instances TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT SELECT ON df.nodes TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT INSERT (id, label, root_node, submitted_by, database) ON df.instances TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;

    RAISE NOTICE 'pg_durable: granted df usage privileges to "%"', p_role;
END;
$fn$;

-- ============================================================================
-- Simplify df.revoke_usage(): make it symmetric with the new df.grant_usage().
--
-- The previous body looped over every df.* function in pg_proc issuing
-- REVOKE EXECUTE. With the simplified grant_usage() that no longer grants
-- per-function EXECUTE on ordinary functions, those revokes target privileges
-- the role never explicitly held (its access comes from schema USAGE + the
-- default PUBLIC EXECUTE), producing only "no privileges could be revoked"
-- warnings. Revoking USAGE on schema df is the access gate, so it alone locks
-- the role out of every ordinary df.* function.
--
-- The new body undoes exactly what grant_usage() grants: schema USAGE, EXECUTE
-- on the sensitive functions (including df.metrics(), which grant_usage() grants
-- to with_grant admins), and the table privileges. Note: a role granted under
-- the OLD grant_usage() (explicit per-function EXECUTE) may retain inert EXECUTE
-- entries on ordinary functions after this revoke; they are harmless because
-- schema USAGE is gone.
-- ============================================================================
CREATE OR REPLACE FUNCTION df.revoke_usage(p_role TEXT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $fn$
BEGIN
    -- Mirror of df.grant_usage(): undo exactly what it grants. Revoking schema
    -- USAGE is the access gate that locks the role out of ordinary df.*
    -- functions; the sensitive functions and table privileges are undone below.
    -- CASCADE also removes any sub-grants the role made via WITH GRANT OPTION.

    -- Sensitive functions (granted explicitly by grant_usage()).  A delegated
    -- admin may lack privilege on some of these (e.g. df.http); skip those.
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.metrics() FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    -- Table privileges.
    -- Column-level revokes must match the column-level grants from grant_usage().
    EXECUTE pg_catalog.format('REVOKE SELECT, INSERT, UPDATE, DELETE ON df.vars FROM %I CASCADE', p_role);
    EXECUTE pg_catalog.format('REVOKE INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes FROM %I CASCADE', p_role);
    EXECUTE pg_catalog.format('REVOKE SELECT ON df.nodes FROM %I CASCADE', p_role);
    EXECUTE pg_catalog.format('REVOKE INSERT (id, label, root_node, submitted_by, database) ON df.instances FROM %I CASCADE', p_role);
    EXECUTE pg_catalog.format('REVOKE UPDATE (status, updated_at) ON df.instances FROM %I CASCADE', p_role);
    EXECUTE pg_catalog.format('REVOKE SELECT ON df.instances FROM %I CASCADE', p_role);

    -- Schema access — the access gate for all ordinary df.* functions.
    EXECUTE pg_catalog.format('REVOKE USAGE ON SCHEMA df FROM %I CASCADE', p_role);

    RAISE NOTICE 'pg_durable: revoked df usage privileges granted by "%" from "%"', current_user, p_role;
END;
$fn$;

-- Renames df.wait_for_completion → df.await_instance. The old name is retained
-- as a deprecated alias for backward compatibility: the new .so still exports
-- both functions (df.await_instance is the canonical name;
-- df.wait_for_completion is a thin Rust shim). Existing customer scripts that
-- call df.wait_for_completion continue to work unchanged.

-- New canonical name for the test/inspection helper formerly known as
-- df.wait_for_completion. Bound to the C symbol await_instance_wrapper exported
-- by the new .so.
CREATE FUNCTION df."await_instance"(
		"instance_id" TEXT,
		"timeout_seconds" INT DEFAULT 30
) RETURNS TEXT
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'await_instance_wrapper';
