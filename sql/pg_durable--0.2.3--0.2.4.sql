-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.3 → 0.2.4
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).

-- ============================================================================
-- Expose signal waits at the instance level (issue #239).
--
-- `df.instances.blocked_on_signal` is set to the signal name while the instance
-- is parked on a SIGNAL node, and cleared when no SIGNAL wait remains or the
-- instance reaches a terminal state. Backfill is unnecessary: existing terminal
-- rows remain NULL, and newly executing SIGNAL nodes set the column when their
-- node status transitions to `running`.
--
-- Preserve existing delegated permissions by granting UPDATE on the new column
-- to every role that already had UPDATE on df.instances.status or updated_at.
-- ============================================================================
ALTER TABLE df.instances ADD COLUMN blocked_on_signal TEXT;

COMMENT ON COLUMN df.instances.blocked_on_signal IS
    'Signal name while the instance is parked on a SIGNAL node; NULL otherwise';

DO $do$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT role_ident, pg_catalog.bool_and(is_grantable) AS all_grantable
        FROM (
            SELECT
                CASE
                    WHEN acl.grantee OPERATOR(pg_catalog.=) 0::oid THEN 'PUBLIC'
                    ELSE grantee_role.rolname
                END AS role_ident,
                acl.is_grantable
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) c.oid
            CROSS JOIN LATERAL pg_catalog.aclexplode(a.attacl) acl
            LEFT JOIN pg_catalog.pg_roles grantee_role ON grantee_role.oid OPERATOR(pg_catalog.=) acl.grantee
            WHERE n.nspname OPERATOR(pg_catalog.=) 'df'
              AND c.relname OPERATOR(pg_catalog.=) 'instances'
              AND a.attname OPERATOR(pg_catalog.=) ANY (ARRAY['status', 'updated_at'])
              AND acl.privilege_type OPERATOR(pg_catalog.=) 'UPDATE'
        ) grants
        WHERE role_ident IS NOT NULL
        GROUP BY role_ident
    LOOP
        IF r.role_ident OPERATOR(pg_catalog.=) 'PUBLIC' THEN
            EXECUTE 'GRANT UPDATE (blocked_on_signal) ON df.instances TO PUBLIC';
        ELSIF r.all_grantable THEN
            EXECUTE pg_catalog.format(
                'GRANT UPDATE (blocked_on_signal) ON df.instances TO %I WITH GRANT OPTION',
                r.role_ident
            );
        ELSE
            EXECUTE pg_catalog.format(
                'GRANT UPDATE (blocked_on_signal) ON df.instances TO %I',
                r.role_ident
            );
        END IF;
    END LOOP;
END;
$do$;

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
    EXECUTE pg_catalog.format('GRANT UPDATE (status, updated_at, blocked_on_signal) ON df.instances TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
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
    EXECUTE pg_catalog.format('REVOKE UPDATE (status, updated_at, blocked_on_signal) ON df.instances FROM %I CASCADE', p_role);
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

-- ============================================================================
-- Promote df.nodes to a composite primary key (instance_id, id) (issue #129).
--
-- The single-column PRIMARY KEY (id) forced node IDs to be globally unique, so
-- the random 8-hex node ID was the sole collision guard across every instance.
-- Node IDs only need to be unique per instance, so the existing composite
-- UNIQUE (instance_id, id) — already referenced by the same-instance foreign
-- keys — is promoted to be the primary key and the global single-column key is
-- dropped. This matches the fresh-install schema in src/lib.rs so a fresh
-- install and an upgraded database end with identical df.nodes constraints.
--
-- The three same-instance foreign keys reference the composite key, so
-- PostgreSQL will not allow dropping it (nor the old single-column PRIMARY KEY)
-- while those foreign keys exist. Drop them first, restructure the keys, then
-- recreate the foreign keys against the new primary key. The recreated foreign
-- keys keep their original DEFERRABLE INITIALLY DEFERRED NOT VALID definition.
--
-- nodes_instance_identity_fkey references df.instances, not df.nodes, so it is
-- left untouched. ADD PRIMARY KEY (instance_id, id) sets NOT NULL on both
-- columns: id was already the old primary key (implicitly NOT NULL), and
-- instance_id carries nodes_instance_id_present_chk CHECK (instance_id IS NOT
-- NULL). That check is NOT VALID, so it only guarantees rows written on 0.2.2+;
-- in the unlikely event a database still holds pre-0.2.2 rows with a NULL
-- instance_id, the ALTER COLUMN ... SET NOT NULL below will abort and the
-- operator must backfill or remove those rows before retrying the upgrade.
-- ============================================================================
ALTER TABLE df.nodes DROP CONSTRAINT nodes_left_node_same_instance_fkey;
ALTER TABLE df.nodes DROP CONSTRAINT nodes_right_node_same_instance_fkey;
ALTER TABLE df.instances DROP CONSTRAINT instances_root_node_same_instance_fkey;

ALTER TABLE df.nodes DROP CONSTRAINT nodes_instance_node_key;
ALTER TABLE df.nodes DROP CONSTRAINT nodes_pkey;

ALTER TABLE df.nodes
    ALTER COLUMN id SET NOT NULL,
    ALTER COLUMN instance_id SET NOT NULL,
    ADD CONSTRAINT nodes_pkey
        PRIMARY KEY (instance_id, id);

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_left_node_same_instance_fkey
        FOREIGN KEY (instance_id, left_node)
        REFERENCES df.nodes (instance_id, id)
        DEFERRABLE INITIALLY DEFERRED NOT VALID,
    ADD CONSTRAINT nodes_right_node_same_instance_fkey
        FOREIGN KEY (instance_id, right_node)
        REFERENCES df.nodes (instance_id, id)
        DEFERRABLE INITIALLY DEFERRED NOT VALID;

ALTER TABLE df.instances
    ADD CONSTRAINT instances_root_node_same_instance_fkey
        FOREIGN KEY (id, root_node)
        REFERENCES df.nodes (instance_id, id)
        DEFERRABLE INITIALLY DEFERRED NOT VALID;
