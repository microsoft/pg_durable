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

-- ============================================================================
-- df.reconcile(): repair residual df.* / duroxide divergence.
--
-- Best-effort admin backstop: delete orphaned duroxide instance subtrees whose
-- root has no df.instances row, and mark stale df.instances rows failed when
-- the runtime has neither a live instance nor a queued start. Fresh installs
-- define the same function in src/lib.rs.
-- ============================================================================
CREATE FUNCTION df.reconcile(p_grace_seconds integer DEFAULT 60)
RETURNS TABLE(duroxide_orphans_deleted bigint, stuck_instances_failed bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
    sch        text := df.duroxide_schema();
    orphan_ids text[];
    deleted    bigint := 0;
    stuck      bigint := 0;
BEGIN
    -- 1) Delete orphaned duroxide subtrees: every duroxide instance whose ROOT
    --    ancestor has no df.instances row and is older than the grace window.
    --    We must gather the FULL subtree (root + all descendants) because
    --    delete_instances_atomic refuses (even with force) to delete a parent
    --    whose children are not also in the list. Sub-orchestrations (JOIN/RACE
    --    branches, loop generations) have no df.instances row and would be
    --    mis-detected as roots if we keyed on "no df row" alone, so the orphan
    --    seed is restricted to parent_instance_id IS NULL.
    --    Wrapped so a GC failure never aborts reconcile or kills the built-in
    --    reconciler loop.
    BEGIN
        EXECUTE pg_catalog.format(
            'WITH RECURSIVE orphan_root AS ( '
            '    SELECT d.instance_id '
            '    FROM %1$I.instances d '
            '    LEFT JOIN df.instances i ON i.id = d.instance_id '
            '    WHERE i.id IS NULL '
            '      AND d.parent_instance_id IS NULL '
            '      AND d.created_at < pg_catalog.now() - pg_catalog.make_interval(secs => $1) '
            '), subtree AS ( '
            '    SELECT instance_id FROM orphan_root '
            '    UNION '
            '    SELECT c.instance_id FROM %1$I.instances c '
            '    JOIN subtree s ON c.parent_instance_id = s.instance_id '
            ') SELECT pg_catalog.array_agg(instance_id) FROM subtree',
            sch)
        INTO orphan_ids
        USING p_grace_seconds;

        IF orphan_ids IS NOT NULL AND pg_catalog.array_length(orphan_ids, 1) > 0 THEN
            EXECUTE pg_catalog.format(
                'SELECT instances_deleted FROM %I.delete_instances_atomic($1, $2)', sch)
            INTO deleted
            USING orphan_ids, true;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        deleted := 0;
        RAISE WARNING 'pg_durable: reconcile orphan-GC pass failed: %', SQLERRM;
    END;

    -- 2) df.instances stuck non-terminal with no live duroxide instance and no
    --    queued start (lost enqueue) -> mark failed. The duroxide queue row
    --    persists (locked) until ack, and the instance row is created at ack, so
    --    a healthy in-flight start always matches one of the NOT EXISTS guards
    --    and is never failed here. Best-effort; wrapped like step 1.
    BEGIN
        EXECUTE pg_catalog.format(
            'UPDATE df.instances i '
            'SET status = ''failed'', updated_at = pg_catalog.now() '
            'WHERE i.status IN (''pending'', ''running'') '
            '  AND i.updated_at < pg_catalog.now() - pg_catalog.make_interval(secs => $1) '
            '  AND NOT EXISTS (SELECT 1 FROM %1$I.instances d WHERE d.instance_id = i.id) '
            '  AND NOT EXISTS (SELECT 1 FROM %1$I.orchestrator_queue q WHERE q.instance_id = i.id)',
            sch)
        USING p_grace_seconds;
        GET DIAGNOSTICS stuck = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
        stuck := 0;
        RAISE WARNING 'pg_durable: reconcile stuck-failover pass failed: %', SQLERRM;
    END;

    duroxide_orphans_deleted := deleted;
    stuck_instances_failed := stuck;
    RETURN NEXT;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION df.reconcile(integer) FROM PUBLIC;

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

-- ============================================================================
-- Indexes for efficient instance listing (monitoring redesign, issues #167/#87/#146).
--
-- df.list_instances() returns rows newest-first (ORDER BY created_at DESC),
-- optionally filtered by status. The previous single-column
-- idx_instances_status(status) did not cover created_at, so a status-filtered
-- listing still required a sort, and an unfiltered listing had no supporting
-- index at all. Replace the single-column index with a composite
-- (status, created_at DESC, id) and add (created_at DESC, id) for the unfiltered
-- path. The trailing id prepares the access path for the keyset pagination planned
-- for df.list_instances (ORDER BY created_at DESC, id ASC); df.list_instances() does
-- not order by id yet, so this does not change the current result ordering. These
-- definitions are byte-identical to the fresh-install DDL in src/lib.rs, so the
-- Scenario A index snapshot matches.
-- ============================================================================
DROP INDEX IF EXISTS df.idx_instances_status;
CREATE INDEX idx_instances_status ON df.instances(status, created_at DESC, id);
DROP INDEX IF EXISTS df.idx_instances_created_at;
CREATE INDEX idx_instances_created_at ON df.instances(created_at DESC, id);

-- ============================================================================
-- Node state-transition model: add df.nodes.status_details (PR #263).
--
-- The background worker stamps every node transition with the orchestration
-- generation "{instance_id}::{execution_id}" in status_details->>'execution_id'.
-- df.instance_nodes() parses that stamp to derive the pending/skipped statuses
-- and to reconcile loop re-entry, and update_node_status() uses it to fence stale
-- writes. The column is nullable and is deliberately NOT added to any user INSERT
-- grant on df.nodes -- only the background worker writes it.
--
-- Backward compatibility (Scenario B1): the new .so probes for this column at
-- runtime (update_node_status) and degrades to the plain status/result write when
-- it is absent, so a pre-0.2.4 schema keeps running until this upgrade applies.
--
-- Upgrade ordering (in-flight instances): the worker's orchestration history
-- changed shape in this release -- update_node_status activity inputs gained an
-- execution_id field, and JOIN/RACE branch sub-orchestrations now use
-- deterministic composed instance ids instead of auto-generated ones. duroxide
-- replays by exact equality on recorded inputs/ids, so instances in flight across
-- the upgrade cannot resume; drain or recreate them before upgrading (the same
-- constraint documented for issue #129).
-- ============================================================================
ALTER TABLE df.nodes ADD COLUMN status_details JSONB;

COMMENT ON COLUMN df.nodes.status_details IS
    'Execution metadata written by the worker (never inserted by users). JSON object with key '
    '"execution_id": the orchestration instance_id::execution_id stamp recorded when the node last '
    'transitioned. df.instance_nodes() parses it to derive pending/skipped statuses; see USER_GUIDE.md.';

-- ============================================================================
-- df.instance_nodes(): one row per node with derived status (PR #263).
--
-- The return shape changed: the per-execution fan-out is gone, replaced by a
-- single row per node carrying the stored status plus the derived status_details,
-- inferred_status and inferred_status_from_ancestor_id columns. Keep the old
-- two-argument overload callable for binary/schema compatibility, but implement
-- it as a one-row-per-node adapter that ignores last_n_executions and returns a
-- dummy execution_id of 1. Remove its default argument so one-argument calls
-- resolve to the new API after the schema upgrade. The definitions below are the
-- pgrx-generated fresh-install DDL (src/monitoring.rs) verbatim, so the Scenario
-- A schema snapshot (function arguments + result type) matches a fresh 0.2.4
-- install.
-- ============================================================================
DROP FUNCTION IF EXISTS df.instance_nodes(text, integer);

CREATE  FUNCTION df."instance_nodes"(
    "instance_id_param" TEXT, /* &str */
    "_last_n_executions" INT /* i32 */
) RETURNS TABLE (
    "execution_id" bigint,  /* i64 */
    "node_id" TEXT,  /* alloc::string::String */
    "node_type" TEXT,  /* alloc::string::String */
    "query" TEXT,  /* core::option::Option<alloc::string::String> */
    "result_name" TEXT,  /* core::option::Option<alloc::string::String> */
    "left_node" TEXT,  /* core::option::Option<alloc::string::String> */
    "right_node" TEXT,  /* core::option::Option<alloc::string::String> */
    "status" TEXT,  /* core::option::Option<alloc::string::String> */
    "result" TEXT,  /* core::option::Option<alloc::string::String> */
    "updated_at" timestamp with time zone  /* core::option::Option<pgrx::datum::time_stamp_with_timezone::TimestampWithTimeZone> */
)
STRICT 
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'instance_nodes_wrapper';

CREATE  FUNCTION df."instance_nodes"(
	"instance_id_param" TEXT /* &str */
) RETURNS TABLE (
	"node_id" TEXT,  /* alloc::string::String */
	"node_type" TEXT,  /* alloc::string::String */
	"query" TEXT,  /* core::option::Option<alloc::string::String> */
	"result_name" TEXT,  /* core::option::Option<alloc::string::String> */
	"left_node" TEXT,  /* core::option::Option<alloc::string::String> */
	"right_node" TEXT,  /* core::option::Option<alloc::string::String> */
	"status" TEXT,  /* core::option::Option<alloc::string::String> */
	"result" TEXT,  /* core::option::Option<alloc::string::String> */
	"status_details" TEXT,  /* core::option::Option<alloc::string::String> */
	"inferred_status" TEXT,  /* alloc::string::String */
	"inferred_status_from_ancestor_id" TEXT,  /* core::option::Option<alloc::string::String> */
	"updated_at" timestamp with time zone  /* core::option::Option<pgrx::datum::time_stamp_with_timezone::TimestampWithTimeZone> */
)
STRICT 
LANGUAGE c /* Rust */
AS 'MODULE_PATHNAME', 'instance_nodes_v2_wrapper';
