// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! pg_durable - Durable SQL Functions for PostgreSQL
//!
//! This extension provides durable, fault-tolerant function execution within PostgreSQL
//! using the Duroxide runtime for persistence.

use pgrx::guc::*;
use pgrx::prelude::*;
use std::ffi::CString;

// ============================================================================
// GUC Definitions
// ============================================================================

pub static WORKER_ROLE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"postgres"));

pub static DATABASE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"postgres"));

pub static MAX_MANAGEMENT_CONNECTIONS: GucSetting<i32> = GucSetting::<i32>::new(6);
pub static MAX_DUROXIDE_CONNECTIONS: GucSetting<i32> = GucSetting::<i32>::new(10);
pub static MAX_USER_CONNECTIONS: GucSetting<i32> = GucSetting::<i32>::new(10);
pub static EXECUTION_ACQUIRE_TIMEOUT: GucSetting<i32> = GucSetting::<i32>::new(30);
/// When `false` (default), pg_durable rejects any instance whose `submitted_by`
/// role is a PostgreSQL superuser. Set to `true` only when superuser durable
/// functions are explicitly desired. See docs/superuser_guc.md.
pub static ENABLE_SUPERUSER_INSTANCES: GucSetting<bool> = GucSetting::<bool>::new(false);

/// Maximum page size (`limit_count`) accepted by `df.list_instances()`. A call
/// requesting more rows than this raises an error instead of silently truncating
/// the result, steering external clients toward keyset pagination
/// (`after_cursor`/`next_cursor`) for large result sets (issue #146). Superuser-
/// settable (Suset) so it can be tuned at runtime without a restart.
///
/// NOTE: the default (`1000`) and max (`1_000_000`) below are also documented in
/// `docs/api-reference.md` and `USER_GUIDE.md`; update those mirrors if you change them.
pub static LIST_INSTANCES_MAX_LIMIT: GucSetting<i32> = GucSetting::<i32>::new(1000);

/// Days a terminal ('completed'/'failed'/'cancelled') instance is retained
/// before reconciliation removes it and its engine record. The same age bound
/// governs when orphaned engine records left by a rolled-back `df.start()` are
/// reclaimed. `0` removes terminal instances as soon as the next pass runs.
pub static RETENTION_DAYS: GucSetting<i32> = GucSetting::<i32>::new(30);

/// Seconds between background reconciliation passes. Each pass removes expired
/// terminal instances and reclaims orphaned engine records. `0` disables it.
pub static RECONCILE_INTERVAL: GucSetting<i32> = GucSetting::<i32>::new(3600);

// Module declarations
pub mod activities;
pub mod client;
pub mod dsl;
pub mod explain;
pub mod monitoring;
pub mod node_status;
pub mod orchestrations;
pub mod registry;
pub mod ssrf;
pub mod types;
pub mod worker;

// Re-export key types for tests
pub use types::Durofut;

/// Monotonically increasing schema version written to `duroxide._worker_ready`
/// by the background worker after successful initialization. Increment whenever
/// a new binary introduces new duroxide-pg migration scripts or any other
/// BGW-applied duroxide schema change.
pub const WORKER_SCHEMA_VERSION: i32 = 1;

::pgrx::pg_module_magic!(name, version);

// ============================================================================
// Background Worker Registration
// ============================================================================

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    if unsafe { !pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
        pgrx::error!(
            "pg_durable must be loaded via shared_preload_libraries.\n\nHINT: Add 'pg_durable' to shared_preload_libraries in postgresql.conf and restart the server."
        );
    }

    GucRegistry::define_string_guc(
        c"pg_durable.worker_role",
        c"PostgreSQL role used by the pg_durable background worker",
        c"",
        &WORKER_ROLE,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_durable.database",
        c"PostgreSQL database used by the pg_durable background worker",
        c"",
        &DATABASE,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.max_management_connections",
        c"Maximum number of connections in the background worker management pool (lifecycle, graph loading, status updates)",
        c"",
        &MAX_MANAGEMENT_CONNECTIONS,
        1,
        1000,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.max_duroxide_connections",
        c"Maximum number of connections in the duroxide provider pool (orchestration state + listener)",
        c"",
        &MAX_DUROXIDE_CONNECTIONS,
        1,
        1000,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.max_user_connections",
        c"Maximum number of concurrent user-execution connections for SQL node execution",
        c"",
        &MAX_USER_CONNECTIONS,
        1,
        1000,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.execution_acquire_timeout",
        c"Seconds to wait for an available execution slot before failing a SQL node",
        c"",
        &EXECUTION_ACQUIRE_TIMEOUT,
        1,
        3600,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_bool_guc(
        c"pg_durable.enable_superuser_instances",
        c"Allow pg_durable instances whose submitted_by role is a PostgreSQL superuser",
        c"Disabled by default to prevent superuser execution-identity forgery via RLS-bypassing roles. Requires server restart to change.",
        &ENABLE_SUPERUSER_INSTANCES,
        GucContext::Postmaster,
        GucFlags::SUPERUSER_ONLY,
    );

    // First Suset-context GUC in this extension (the connection-limit and
    // enable_superuser_instances GUCs above are Postmaster). Suset is deliberate:
    // this guardrail is read on the df.list_instances() query path, so a superuser
    // must be able to tune it per-session at runtime. Its long description is
    // intentionally populated (unlike the c"" connection GUCs) because the
    // raise-instead-of-truncate behavior is not obvious from the name alone.
    GucRegistry::define_int_guc(
        c"pg_durable.list_instances_max_limit",
        c"Maximum number of rows df.list_instances() returns in a single call before raising an error",
        c"A call to df.list_instances() with limit_count above this value raises an error instead of silently truncating the result. Clients needing more rows should use the paginated df.list_instances overload (after_cursor/next_cursor). Superusers can change this at runtime without a restart; by default ordinary callers cannot raise it.",
        &LIST_INSTANCES_MAX_LIMIT,
        1,
        1_000_000,
        GucContext::Suset,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.retention_days",
        c"Days a terminal instance is retained before reconciliation removes it",
        c"Background reconciliation removes 'completed'/'failed'/'cancelled' df.instances rows (and their engine records) once they are older than this many days, subject to a fixed hard cap on the number retained. The same age bound governs when orphaned engine records left by a rolled-back df.start() are reclaimed. 0 removes terminal instances as soon as the next pass runs.",
        &RETENTION_DAYS,
        0,
        36500,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_durable.reconcile_interval",
        c"Seconds between background reconciliation passes (0 disables reconciliation)",
        c"Each background reconciliation pass removes expired terminal instances and reclaims orphaned engine records left by a rolled-back df.start(). Set to 0 to disable background reconciliation entirely.",
        &RECONCILE_INTERVAL,
        0,
        86400,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    worker::register_background_worker();
}

// ============================================================================
// Schema Declaration
// ============================================================================

// Create both extension-owned schemas as the very first statements of the
// install script. `bootstrap` guarantees this runs before every other extension
// object, including the redundant `CREATE SCHEMA IF NOT EXISTS df` that pgrx
// emits for the `#[pg_schema] mod df` entity below.
extension_sql!(
    r#"
CREATE SCHEMA df;
CREATE SCHEMA _duroxide;

-- Returns the name of the duroxide provider schema selected for this install.
-- Fresh installs return '_duroxide'. The body is version-specific: the upgrade
-- script pg_durable--0.2.2--0.2.3.sql replaces it to return 'duroxide' for
-- installs that originated on pg_durable <= 0.2.2 (which keep the legacy
-- 'duroxide' schema). Both backend sessions and the background worker call
-- df.duroxide_schema() to discover which schema to use, falling back to
-- 'duroxide' when the helper is absent (installs predating it).
CREATE FUNCTION df.duroxide_schema() RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
    AS $$ SELECT '_duroxide'::text $$;
"#,
    name = "bootstrap_schemas",
    bootstrap
);

/// The 'df' schema contains all pg_durable functions (df = durable functions).
/// pgrx requires this entity so that `#[pg_extern(schema = "df")]` functions can
/// resolve their target schema. It emits a redundant `CREATE SCHEMA IF NOT
/// EXISTS df` that no-ops after the bootstrap block above has already created df.
#[pg_schema]
mod df {}

// ============================================================================
// Table Definitions
// ============================================================================

extension_sql!(
    r#"
-- Table to store function nodes (SQL steps, THEN chains, etc.)
CREATE TABLE df.nodes (
    id VARCHAR(8) NOT NULL,
    instance_id VARCHAR(8) NOT NULL,
    node_type TEXT NOT NULL,
    query TEXT,
    result_name TEXT,
    left_node VARCHAR(8),
    right_node VARCHAR(8),
    status TEXT DEFAULT 'pending',
    result JSONB,
    error TEXT,
    submitted_by REGROLE,
    database TEXT,
    created_at TIMESTAMPTZ DEFAULT pg_catalog.now(),
    updated_at TIMESTAMPTZ DEFAULT pg_catalog.now(),
    -- Appended last so the fresh-install column order matches the upgrade path,
    -- where ALTER TABLE ADD COLUMN can only append (see pg_durable--0.2.3--0.2.4.sql).
    status_details JSONB
);

COMMENT ON COLUMN df.nodes.submitted_by IS
    'Effective role (current_user) at df.start() time - used for connection authentication and SQL execution';

COMMENT ON COLUMN df.nodes.status_details IS
    'Execution metadata written by the worker (never inserted by users). JSON object with key '
    '"execution_id": the orchestration instance_id::execution_id stamp recorded when the node last '
    'transitioned. df.instance_nodes() parses it to derive pending/skipped statuses; see USER_GUIDE.md.';

-- Table to store function instances
CREATE TABLE df.instances (
    id VARCHAR(8) PRIMARY KEY,
    label TEXT,
    root_node VARCHAR(8) NOT NULL,
    status TEXT DEFAULT 'pending',
    submitted_by REGROLE NOT NULL,
    database TEXT,
    created_at TIMESTAMPTZ DEFAULT pg_catalog.now(),
    updated_at TIMESTAMPTZ DEFAULT pg_catalog.now(),
    completed_at TIMESTAMPTZ
);

COMMENT ON COLUMN df.instances.submitted_by IS
    'Effective role (current_user) at df.start() time - used for connection authentication and SQL execution';

-- Index for status-filtered listing, newest-first
-- (df.list_instances() WHERE status = $1 ORDER BY created_at DESC, id ASC). Also
-- serves the pending-instance scan via the leading status column. The trailing id
-- is the keyset tiebreaker for df.list_instances() pagination (ORDER BY
-- created_at DESC, id ASC), so both the sort and the after_cursor range predicate
-- are index-served.
-- NOTE: keep these two index definitions byte-identical to the 0.2.3->0.2.4 upgrade
-- script (sql/pg_durable--0.2.3--0.2.4.sql) until 0.2.4 is released -- Scenario A
-- compares pg_get_indexdef() across the fresh-install and upgrade paths.
CREATE INDEX idx_instances_status ON df.instances(status, created_at DESC, id);

-- Index for unfiltered listing, newest-first
-- (df.list_instances() ORDER BY created_at DESC, id ASC). The trailing id is the
-- keyset tiebreaker that makes the after_cursor range predicate index-served.
CREATE INDEX idx_instances_created_at ON df.instances(created_at DESC, id);

-- Index for label-filtered listing, newest-first
-- (df.list_instances(..., label_filter => $n) WHERE label = $n ORDER BY
-- created_at DESC, id ASC). Partial on (label IS NOT NULL) because label_filter only
-- matches non-NULL labels and many instances are unlabeled, keeping the index small;
-- the planner still uses it since `label = $n` implies the partial predicate. The
-- trailing id keeps the after_cursor keyset range predicate index-served on the
-- label-scoped page. (Not leading with submitted_by -- consistent with the indexes
-- above; an owner-leading variant is a future refinement if RLS-scoped label listing
-- becomes hot.)
-- NOTE: keep this definition byte-identical to the 0.2.3->0.2.4 upgrade script
-- (sql/pg_durable--0.2.3--0.2.4.sql) until 0.2.4 is released -- Scenario A compares
-- pg_get_indexdef() across the fresh-install and upgrade paths.
CREATE INDEX idx_instances_label ON df.instances(label, created_at DESC, id) WHERE label IS NOT NULL;

-- Index for finding nodes by instance
CREATE INDEX idx_nodes_instance ON df.nodes(instance_id);

-- Table to store workflow variables (captured at df.start())
-- Per-user scoping: each user has their own variable namespace.
CREATE TABLE df.vars (
    name TEXT NOT NULL,
    value TEXT,
    owner REGROLE NOT NULL DEFAULT pg_catalog.quote_ident(current_user)::pg_catalog.regrole,
    PRIMARY KEY (owner, name)
);

-- Sentinel table: the background worker writes its epoch_id here after
-- initialising.  If the extension is DROP-ed and re-CREATEd between
-- two poll ticks the epoch row disappears, so the worker detects the
-- recreation even though the extension is always "present" in pg_extension.
CREATE TABLE df._worker_epoch (
    epoch_id UUID PRIMARY KEY,
    started_at TIMESTAMPTZ DEFAULT pg_catalog.now(),
    last_seen_at TIMESTAMPTZ DEFAULT pg_catalog.now()
);

ALTER TABLE df.instances
    ADD CONSTRAINT instances_id_format_chk
        -- Operators (OPERATOR(pg_catalog.<op>)) and functions (e.g. pg_catalog.now)
        -- are schema-qualified throughout this install DDL so name resolution never
        -- depends on the session search_path -- closing the CVE-2018-1058 vector
        -- (a malicious schema shadowing `=`, `~`, etc.). Enforced by the pgspot CI
        -- gate (scripts/pgspot-gate.sh).
        CHECK (id OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT instances_root_node_format_chk
        CHECK (root_node OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT instances_status_chk
        CHECK (status OPERATOR(pg_catalog.=) ANY (ARRAY['pending', 'running', 'completed', 'failed', 'cancelled'])) NOT VALID,
    -- Supports the composite FK from df.nodes that ties node identity to the instance row.
    ADD CONSTRAINT instances_identity_key
        UNIQUE (id, submitted_by);

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_instance_id_present_chk
        CHECK (instance_id IS NOT NULL) NOT VALID,
    ADD CONSTRAINT nodes_submitted_by_present_chk
        CHECK (submitted_by IS NOT NULL) NOT VALID,
    ADD CONSTRAINT nodes_id_format_chk
        CHECK (id OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_instance_id_format_chk
        CHECK (instance_id OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_left_node_format_chk
        CHECK (left_node IS NULL OR left_node OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_right_node_format_chk
        CHECK (right_node IS NULL OR right_node OPERATOR(pg_catalog.~) '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_node_type_chk
        CHECK (node_type OPERATOR(pg_catalog.=) ANY (ARRAY['SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL'])) NOT VALID,
    ADD CONSTRAINT nodes_result_name_chk
        CHECK (result_name IS NULL OR result_name OPERATOR(pg_catalog.~) '^[A-Za-z_][A-Za-z0-9_]*$') NOT VALID,
    ADD CONSTRAINT nodes_status_chk
        CHECK (status OPERATOR(pg_catalog.=) ANY (ARRAY['pending', 'running', 'completed', 'failed'])) NOT VALID,
    ADD CONSTRAINT nodes_result_status_chk
        CHECK (result IS NULL OR status OPERATOR(pg_catalog.=) ANY (ARRAY['completed', 'failed'])) NOT VALID,
    ADD CONSTRAINT nodes_structure_chk
        CHECK (
            CASE
                WHEN node_type OPERATOR(pg_catalog.=) ANY (ARRAY['SQL', 'SLEEP', 'WAIT_SCHEDULE', 'BREAK', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL'])
                    THEN left_node IS NULL AND right_node IS NULL AND query IS NOT NULL
                WHEN node_type OPERATOR(pg_catalog.=) 'THEN'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
                WHEN node_type OPERATOR(pg_catalog.=) 'IF'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NOT NULL
                WHEN node_type OPERATOR(pg_catalog.=) 'LOOP'
                    THEN left_node IS NOT NULL AND right_node IS NULL
                WHEN node_type OPERATOR(pg_catalog.=) 'JOIN'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL
                WHEN node_type OPERATOR(pg_catalog.=) 'RACE'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
                ELSE FALSE
            END
        ) NOT VALID,
    -- Composite primary key: node IDs only need to be unique per instance, so
    -- the random 8-hex node ID is never the sole uniqueness guarantee (issue
    -- #129). The same-instance foreign keys below reference (instance_id, id),
    -- which this primary key satisfies.
    ADD CONSTRAINT nodes_pkey
        PRIMARY KEY (instance_id, id);

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_instance_identity_fkey
        FOREIGN KEY (instance_id, submitted_by)
        REFERENCES df.instances (id, submitted_by)
        DEFERRABLE INITIALLY DEFERRED NOT VALID,
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
"#,
    name = "create_tables",
    requires = [df]
);

// ============================================================================
// Row-Level Security Policies & Grants
// ============================================================================

extension_sql!(
    r#"
-- Enable RLS on df.instances (no FORCE — superuser/table-owner bypasses RLS)
ALTER TABLE df.instances ENABLE ROW LEVEL SECURITY;

CREATE POLICY instances_user_isolation ON df.instances
    FOR ALL
    USING (submitted_by OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole)
    WITH CHECK (submitted_by OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole);

-- Enable RLS on df.nodes
ALTER TABLE df.nodes ENABLE ROW LEVEL SECURITY;

CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (submitted_by OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole)
    WITH CHECK (submitted_by OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole);

-- Enable RLS on df.vars (per-user variable isolation)
ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;

CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole)
    WITH CHECK (owner OPERATOR(pg_catalog.=) pg_catalog.quote_ident(current_user)::pg_catalog.regrole);

-- No automatic PUBLIC grants — admins call df.grant_usage('role') after
-- CREATE EXTENSION (or see USER_GUIDE.md "Privilege Grants" for manual GRANTs).

-- Helper: grant all required df privileges to a role in one call. Additive
-- only (never REVOKEs); call df.revoke_usage() first to downgrade. SECURITY
-- INVOKER with EXECUTE revoked from PUBLIC, so the caller must hold the
-- underlying privileges WITH GRANT OPTION (superusers and with_grant => true
-- admins do). See USER_GUIDE.md "Privilege Grants" for full details.
--
-- Access gate: schema USAGE makes the ordinary df.* functions callable (they
-- keep PostgreSQL's default PUBLIC EXECUTE). Sensitive functions (df.http,
-- df.metrics, df.grant_usage, df.revoke_usage) have PUBLIC EXECUTE revoked at
-- install time and are granted explicitly below when appropriate — keep a new
-- private function private the same way (REVOKE ... FROM PUBLIC in
-- rls_and_grants, then grant it here).
--   include_http => true  also grants EXECUTE on df.http() (opt-in: network).
--   with_grant   => true  marks a pg_durable admin: grants everything WITH GRANT
--                         OPTION, lets the role call df.grant_usage()/
--                         df.revoke_usage() for others, and grants df.metrics()
--                         (system-wide aggregate counts).
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
        -- df.http_multipart() shares the same opt-in (HTTP egress is one privilege).
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
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

-- Revoke everything df.grant_usage() grants (same authorization model).
-- format(%I) quotes identifiers; SECURITY INVOKER caps it at the caller's
-- own privileges.
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
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) FROM %I CASCADE', p_role);
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

-- Validate that the worker role is a superuser.
-- The background worker must bypass RLS to manage all users' instances/nodes.
-- If the worker role is not a superuser, workflows will silently fail because
-- RLS will filter out rows the worker needs to read/update.
DO $$
DECLARE
    wrole TEXT;
    is_super BOOLEAN;
BEGIN
    wrole := pg_catalog.current_setting('pg_durable.worker_role', true);
    IF wrole IS NULL OR wrole OPERATOR(pg_catalog.=) '' THEN
        wrole := 'postgres';
    END IF;

    SELECT rolsuper INTO is_super FROM pg_catalog.pg_roles WHERE rolname OPERATOR(pg_catalog.=) wrole;
    IF is_super IS NULL THEN
        RAISE WARNING 'pg_durable: worker role "%" does not exist. The background worker will not be able to process workflows. Create the role as a superuser before using pg_durable.', wrole;
    ELSIF NOT is_super THEN
        RAISE WARNING 'pg_durable: worker role "%" is not a superuser. The background worker must be a superuser to bypass RLS and manage all users'' instances. Grant superuser or BYPASSRLS to this role.', wrole;
    END IF;
END $$;

-- df.http(), df.metrics(), df.grant_usage() and df.revoke_usage() are sensitive
-- (network access / system-wide monitoring / privilege management), so revoke
-- PostgreSQL's default PUBLIC EXECUTE. df.grant_usage() re-grants the helper
-- functions explicitly to authorized roles; df.metrics() is granted to
-- with_grant => true admins or by a direct administrator GRANT.
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.metrics() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM PUBLIC;
"#,
    name = "rls_and_grants",
    requires = [
        "create_tables",
        dsl::http,
        dsl::http_multipart,
        monitoring::metrics
    ]
);

// ============================================================================
// Extension Validation (must run before duroxide schema creation)
// ============================================================================

// In production builds, validate that the extension is created in the database
// the background worker will connect to.  In pgrx test builds the test database
// name is chosen by pgrx and won't match the worker's target database, so we
// skip the check (unit tests don't need the background worker).

#[cfg(not(any(test, feature = "pg_test")))]
extension_sql!(
    r#"
-- Validate that CREATE EXTENSION is run in the correct database
-- The background worker connects to one specific database (determined by
-- the pg_durable.database GUC, defaults to "postgres").
-- The extension must be created in that database for workflows to execute.
DO $$
DECLARE
    current_db TEXT;
    target_db TEXT;
BEGIN
    -- Get the current database
    SELECT pg_catalog.current_database() INTO current_db;
    
    -- Get the target database that the background worker will connect to
    SELECT df.target_database() INTO target_db;
    
    IF current_db OPERATOR(pg_catalog.<>) target_db THEN
        RAISE EXCEPTION 'pg_durable extension must be created in database "%" (currently in "%"). The background worker only processes functions in the database specified by the pg_durable.database GUC (defaults to "postgres").', target_db, current_db
            USING HINT = 'Connect to the correct database and run: CREATE EXTENSION pg_durable;';
    END IF;
END $$;
"#,
    name = "validate_database",
    requires = [df, target_database]
);

#[cfg(any(test, feature = "pg_test"))]
extension_sql!(
    r#"
-- Test build: skip database validation.
-- pgrx creates a test database whose name differs from the background worker's
-- target database.  The worker won't run in the test database; unit tests that
-- exercise duroxide use direct tokio runtimes instead.
DO $$
BEGIN
    RAISE NOTICE 'pg_durable: database validation skipped (test build)';
END $$;
"#,
    name = "validate_database",
    requires = [df]
);

// ============================================================================
// SQL Operators
// ============================================================================

extension_sql!(
    r#"
-- Operator ~> for sequencing: a ~> b means "run a, then run b"
CREATE OPERATOR ~> (
    FUNCTION = df.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator |=> for naming: fut |=> 'name' means "name this result as $name"
CREATE OR REPLACE FUNCTION df.as_op(fut text, name text) RETURNS text AS $$
    SELECT df.as(fut, name);
$$ LANGUAGE SQL IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OPERATOR |=> (
    FUNCTION = df.as_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator & for parallel join: a & b means "run a and b in parallel, wait for both"
CREATE OPERATOR & (
    FUNCTION = df.join,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator | for race: a | b means "run a and b in parallel, first wins"
CREATE OPERATOR | (
    FUNCTION = df.race,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operators ?> and !> for if-then-else: cond ?> then_branch !> else_branch
-- We need helper functions to build the if node incrementally

-- Helper: cond ?> then creates a partial if (stores condition and then branch)
CREATE OR REPLACE FUNCTION df.if_then_op(condition text, then_branch text) RETURNS text AS $$
DECLARE
    cond_fut jsonb;
    then_fut jsonb;
    result_obj jsonb;
BEGIN
    -- Ensure both are durofuts
    cond_fut := df.ensure_durofut(condition)::jsonb;
    then_fut := df.ensure_durofut(then_branch)::jsonb;
    
    -- Return a special marker object for the partial if
    result_obj := jsonb_build_object(
        '_partial_if', true,
        'condition', cond_fut,
        'then_branch', then_fut
    );
    RETURN result_obj::text;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

-- Helper: partial_if !> else completes the if node
CREATE OR REPLACE FUNCTION df.if_else_op(partial_if text, else_branch text) RETURNS text AS $$
DECLARE
    partial jsonb;
    else_fut text;
    cond_text text;
    then_text text;
BEGIN
    partial := partial_if::jsonb;
    
    -- Check if it's a partial if
    IF partial->>'_partial_if' IS NULL THEN
        RAISE EXCEPTION 'Invalid if-then-else: left side of !> must be a ?> expression';
    END IF;
    
    cond_text := partial->'condition'::text;
    then_text := partial->'then_branch'::text;
    else_fut := df.ensure_durofut(else_branch);
    
    -- Now call the real df.if function
    RETURN df.if(cond_text, then_text, else_fut);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

-- Helper to ensure a value is a durofut (returns JSON string)
-- Rejects JSON with unknown node_type values.
-- NOTE: The valid node type list here must be kept in sync with
-- VALID_NODE_TYPES in src/types.rs (the Rust constant is the canonical source).
CREATE OR REPLACE FUNCTION df.ensure_durofut(val text) RETURNS text AS $$
DECLARE
    node_type_val text;
BEGIN
    -- Try to parse as JSON to check if it's already a durofut
    BEGIN
        node_type_val := (val::jsonb)->>'node_type';
        IF node_type_val IS NOT NULL THEN
            -- Has a node_type - validate it
            IF node_type_val NOT IN ('SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL') THEN
                RAISE EXCEPTION 'Unknown node_type ''%''. Valid types: SQL, THEN, IF, JOIN, LOOP, BREAK, RACE, SLEEP, WAIT_SCHEDULE, HTTP, HTTP_MULTIPART, SIGNAL', node_type_val;
            END IF;
            RETURN val;
        END IF;
    EXCEPTION WHEN invalid_text_representation THEN
        -- Not valid JSON, treat as SQL
        NULL;
    WHEN raise_exception THEN
        -- Re-raise our validation error
        RAISE;
    WHEN OTHERS THEN
        -- Not valid JSON, treat as SQL
        NULL;
    END;
    
    -- It's plain SQL, wrap it
    RETURN df.sql(val);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OPERATOR ?> (
    FUNCTION = df.if_then_op,
    LEFTARG = text,
    RIGHTARG = text
);

CREATE OPERATOR !> (
    FUNCTION = df.if_else_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator @> for loop: @> body means "repeat body forever"
-- This is a PREFIX operator with lowest precedence
CREATE OR REPLACE FUNCTION df.loop_prefix_op(body text) RETURNS text AS $$
    SELECT df.loop(body);
$$ LANGUAGE SQL IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OPERATOR @> (
    FUNCTION = df.loop_prefix_op,
    RIGHTARG = text
);
"#,
    name = "create_operators",
    requires = [
        dsl::then_fn,
        dsl::as_named,
        dsl::join,
        dsl::race,
        dsl::if_fn,
        dsl::loop_fn
    ]
);

// ============================================================================
// Tests
// ============================================================================

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use crate::Durofut;
    use pgrx::prelude::*;

    // ========================================================================
    // Test Helpers for Integration Tests
    // ========================================================================

    /// Ensure the Duroxide store exists and is ready
    fn ensure_store_ready() -> Result<String, String> {
        use crate::types::{
            backend_duroxide_schema, new_backend_provider, postgres_connection_string,
        };
        use std::time::{Duration, Instant};

        let pg_conn_str = postgres_connection_string();
        let schema = backend_duroxide_schema();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {e}"))?;

        // Try to initialize the store (creates schema if it doesn't exist)
        rt.block_on(async {
            let start = Instant::now();
            let timeout = Duration::from_secs(10);

            loop {
                match new_backend_provider(&pg_conn_str, schema).await {
                    Ok(_) => return Ok(format!("{pg_conn_str} (schema: {schema})")),
                    Err(e) => {
                        if start.elapsed() > timeout {
                            return Err(format!(
                                "Failed to initialize store after {}s: {}",
                                timeout.as_secs(),
                                e
                            ));
                        }
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        })
    }

    /// Wait for a durable function to complete, polling Duroxide status
    fn poll_until_terminal(instance_id: &str, timeout_secs: u64) -> Result<String, String> {
        use crate::types::{
            backend_duroxide_schema, new_backend_provider, postgres_connection_string,
        };
        use duroxide::Client;
        use std::time::{Duration, Instant};

        // Ensure store is ready first
        let _ = ensure_store_ready()?;

        let pg_conn_str = postgres_connection_string();
        let schema = backend_duroxide_schema();
        let start = Instant::now();
        let timeout = Duration::from_secs(timeout_secs);

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {e}"))?;

        rt.block_on(async {
            let store = new_backend_provider(&pg_conn_str, schema).await?;
            let client = Client::new(store);

            loop {
                if let Ok(info) = client.get_instance_info(instance_id).await {
                    match info.status.as_str() {
                        "Completed" | "ContinuedAsNew" => {
                            return Ok(info.output.unwrap_or_default());
                        }
                        "Failed" | "Canceled" => {
                            return Err(format!(
                                "{}: {}",
                                info.status,
                                info.output.unwrap_or_default()
                            ));
                        }
                        _ => {} // Still running
                    }
                }
                // Instance not found yet - continue polling

                if start.elapsed() > timeout {
                    // Get final status for better error message
                    let final_status = client
                        .get_instance_info(instance_id)
                        .await
                        .map(|i| i.status)
                        .unwrap_or_else(|_| "unknown".to_string());
                    return Err(format!(
                        "Timeout after {timeout_secs}s, status: {final_status}"
                    ));
                }

                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
    }

    /// Get the current status from Duroxide
    fn get_duroxide_status(instance_id: &str) -> Option<String> {
        use crate::types::{
            backend_duroxide_schema, new_backend_provider, postgres_connection_string,
        };
        use duroxide::Client;

        let _ = ensure_store_ready().ok()?;
        let pg_conn_str = postgres_connection_string();
        let schema = backend_duroxide_schema();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()?;

        rt.block_on(async {
            let store = new_backend_provider(&pg_conn_str, schema).await.ok()?;
            let client = Client::new(store);
            client
                .get_instance_info(instance_id)
                .await
                .ok()
                .map(|i| i.status)
        })
    }

    fn sql_literal(s: &str) -> String {
        format!("'{}'", s.replace('\'', "''"))
    }

    fn test_database_connection_string() -> String {
        use crate::types::{get_host, get_port};

        let database = Spi::get_one::<String>("SELECT pg_catalog.current_database()::text")
            .expect("current_database query should succeed")
            .expect("current_database should return a value");
        // Connect as the current session role rather than the worker role GUC
        // (which defaults to "postgres"). The pgrx test cluster's superuser is
        // the OS account, so "postgres" may not exist; the current role always
        // does and can log in.
        let role = Spi::get_one::<String>("SELECT current_user::text")
            .expect("current_user query should succeed")
            .expect("current_user should return a value");
        format!(
            "postgres://{}@{}:{}/{}",
            role,
            get_host(),
            get_port(),
            database
        )
    }

    async fn delete_expired_test_rows(pool: &sqlx::PgPool, id_list: &str) {
        let mut tx = pool.begin().await.expect("begin teardown transaction");
        sqlx::query("SET CONSTRAINTS ALL DEFERRED")
            .execute(&mut *tx)
            .await
            .expect("defer teardown constraints");
        sqlx::query(&format!(
            "DELETE FROM df.nodes WHERE instance_id IN ({id_list})"
        ))
        .execute(&mut *tx)
        .await
        .expect("clean test nodes");
        sqlx::query(&format!("DELETE FROM df.instances WHERE id IN ({id_list})"))
            .execute(&mut *tx)
            .await
            .expect("clean test instances");
        tx.commit().await.expect("commit teardown");
    }

    // ========================================================================
    // Unit Tests - DSL Node Creation
    // ========================================================================

    #[pg_test]
    fn test_sql_creates_valid_durofut() {
        let json = crate::dsl::sql("SELECT 1");
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SQL");
        assert!(fut.query.is_some());
    }

    #[pg_test]
    fn test_seq_creates_then_node() {
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let then_json = crate::dsl::then_fn(&a, &b);
        let then_fut = Durofut::from_json(&then_json);
        assert_eq!(then_fut.node_type, "THEN");
        assert!(then_fut.left_node.is_some());
        assert!(then_fut.right_node.is_some());
    }

    #[pg_test]
    fn test_as_named_sets_result_name() {
        let sql_json = crate::dsl::sql("SELECT 1");
        let named_json = crate::dsl::as_named(&sql_json, "my_result");
        let named_fut = Durofut::from_json(&named_json);
        assert_eq!(named_fut.result_name, Some("my_result".to_string()));
    }

    #[pg_test]
    fn test_sleep_creates_valid_node() {
        let json = crate::dsl::sleep(60);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SLEEP");
        assert_eq!(fut.query, Some("60".to_string()));
    }

    #[pg_test]
    fn test_sleep_node_is_recognized_as_durofut() {
        // This test verifies that SLEEP nodes created by df.sleep() can be
        // properly recognized and deserialized by Durofut::ensure()
        let sleep_json = crate::dsl::sleep(1);

        // Test that is_durofut recognizes it
        assert!(
            Durofut::is_durofut(&sleep_json),
            "Durofut::is_durofut should recognize SLEEP node JSON: {}",
            sleep_json
        );

        // Test that ensure doesn't wrap it in SQL
        let ensured = Durofut::ensure(&sleep_json);
        assert_eq!(
            ensured.node_type, "SLEEP",
            "Durofut::ensure should preserve SLEEP, not wrap as SQL"
        );
        assert_eq!(ensured.query, Some("1".to_string()));
    }

    #[pg_test]
    fn test_wait_for_schedule_valid_cron() {
        let json = crate::dsl::wait_for_schedule("*/5 * * * *");
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "WAIT_SCHEDULE");

        // The node stores only the cron expression; the next tick is computed at
        // execution time, so there must be no pre-computed wait baked in at DSL time.
        let config: serde_json::Value =
            serde_json::from_str(fut.query.as_ref().expect("query must be set")).unwrap();
        assert_eq!(
            config["cron_expr"].as_str(),
            Some("*/5 * * * *"),
            "cron_expr should be preserved"
        );
        assert!(
            config.get("wait_seconds").is_none(),
            "config must not pre-compute wait_seconds at DSL time"
        );
        assert!(
            config.get("target_timestamp").is_none(),
            "config must not pre-compute a target_timestamp at DSL time"
        );
    }

    #[pg_test]
    fn test_loop_creates_loop_node() {
        let body = crate::dsl::sql("SELECT 1");
        let json = crate::dsl::loop_fn(&body, None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "LOOP");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_none()); // No condition = infinite loop
    }

    #[pg_test]
    fn test_loop_with_condition_creates_while_loop() {
        let body = crate::dsl::sql("SELECT 1");
        let condition = crate::dsl::sql("SELECT count(*) > 0 FROM queue");
        let json = crate::dsl::loop_fn(&body, Some(&condition));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "LOOP");
        assert!(fut.left_node.is_some(), "body should be set"); // body
        assert!(
            fut.right_node.is_none(),
            "right_node should be None for LOOP"
        ); // condition in config now
        assert!(
            fut.query.is_some(),
            "should have config with condition_node"
        ); // has config with condition_node

        // Verify condition is embedded in config
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert!(
            config.get("condition_node").is_some(),
            "config should have condition_node"
        );
    }

    #[pg_test]
    fn test_break_creates_break_node() {
        let json = crate::dsl::break_fn(None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "BREAK");
    }

    #[pg_test]
    fn test_break_with_value() {
        let json = crate::dsl::break_fn(Some(r#"{"status": "done"}"#));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "BREAK");
        assert!(fut.query.is_some());
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(
            config["break_value"].as_str().unwrap(),
            r#"{"status": "done"}"#
        );
    }

    #[pg_test]
    fn test_if_creates_if_node() {
        let condition = crate::dsl::sql("SELECT true");
        let then_branch = crate::dsl::sql("SELECT 'yes'");
        let else_branch = crate::dsl::sql("SELECT 'no'");
        let json = crate::dsl::if_fn(&condition, &then_branch, &else_branch);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "IF");
    }

    #[pg_test]
    fn test_if_condition_embedded_in_config() {
        // Verify that if_fn embeds condition as a nested Durofut in the config JSON,
        // not as a string ID reference.
        let condition = crate::dsl::sql("SELECT count(*) > 0 FROM tasks");
        let then_branch = crate::dsl::sql("SELECT 'yes'");
        let else_branch = crate::dsl::sql("SELECT 'no'");
        let json = crate::dsl::if_fn(&condition, &then_branch, &else_branch);
        let fut = Durofut::from_json(&json);

        assert_eq!(fut.node_type, "IF");
        assert!(fut.left_node.is_some(), "then branch should be left_node");
        assert!(fut.right_node.is_some(), "else branch should be right_node");

        // Parse the config to verify condition_node structure
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        let cond_node = config
            .get("condition_node")
            .expect("config should have condition_node");

        // condition_node must be a nested Durofut object, not a string ID
        assert!(
            cond_node.is_object(),
            "condition_node should be an object, not a string"
        );
        assert_eq!(cond_node["node_type"], "SQL");
        assert_eq!(cond_node["query"], "SELECT count(*) > 0 FROM tasks");

        // Verify it round-trips through validation
        assert!(
            fut.validate_recursive().is_ok(),
            "IF with embedded condition should pass validation"
        );
    }

    #[pg_test]
    fn test_join3_extra_nodes_embedded_in_config() {
        // Verify that join3 embeds the third branch as a nested Durofut in extra_nodes,
        // not as a string ID reference.
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let c = crate::dsl::sql("SELECT 3");
        let json = crate::dsl::join3(&a, &b, &c);
        let fut = Durofut::from_json(&json);

        assert_eq!(fut.node_type, "JOIN");
        assert!(fut.left_node.is_some(), "first branch should be left_node");
        assert!(
            fut.right_node.is_some(),
            "second branch should be right_node"
        );

        // Parse the config to verify extra_nodes structure
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        let extras = config
            .get("extra_nodes")
            .and_then(|e| e.as_array())
            .expect("config should have extra_nodes array");

        assert_eq!(extras.len(), 1, "join3 should have exactly 1 extra node");

        // extra_nodes[0] must be a nested Durofut object, not a string ID
        let extra = &extras[0];
        assert!(
            extra.is_object(),
            "extra_nodes entry should be an object, not a string"
        );
        assert_eq!(extra["node_type"], "SQL");
        assert_eq!(extra["query"], "SELECT 3");

        // Verify it round-trips through validation
        assert!(
            fut.validate_recursive().is_ok(),
            "JOIN3 with embedded extra_nodes should pass validation"
        );
    }

    #[pg_test]
    fn test_join_creates_join_node() {
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let json = crate::dsl::join(&a, &b);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "JOIN");
    }

    // ========================================================================
    // Unit Tests - HTTP Node Creation (require an http feature to be enabled)
    // ========================================================================

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_creates_valid_node() {
        let json = crate::dsl::http("https://example.com/api", "GET", None, None, 30);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "HTTP");
        assert!(fut.query.is_some());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_post_with_body() {
        let json = crate::dsl::http(
            "https://api.example.com/data",
            "POST",
            Some(r#"{"key": "value"}"#),
            None,
            30,
        );
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "HTTP");

        // Parse config to verify body is stored
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["method"], "POST");
        assert_eq!(config["body"], r#"{"key": "value"}"#);
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_with_headers() {
        let headers = pgrx::JsonB(serde_json::json!({
            "Authorization": "Bearer token123",
            "Content-Type": "application/json"
        }));
        let json = crate::dsl::http(
            "https://api.example.com/secure",
            "POST",
            Some(r#"{"data": "test"}"#),
            Some(headers),
            60,
        );
        let fut = Durofut::from_json(&json);

        // Parse config to verify headers are stored
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["headers"]["Authorization"], "Bearer token123");
        assert_eq!(config["timeout_seconds"], 60);
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_config_parsing() {
        use crate::types::HttpConfig;

        let json = crate::dsl::http(
            "https://httpbin.org/post",
            "POST",
            Some(r#"{"test": true}"#),
            None,
            45,
        );
        let fut = Durofut::from_json(&json);
        let config: HttpConfig = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();

        assert_eq!(config.url, "https://httpbin.org/post");
        assert_eq!(config.method, "POST");
        assert_eq!(config.body, Some(r#"{"test": true}"#.to_string()));
        assert_eq!(config.timeout_seconds, 45);
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.http('https://example.com', 'GET')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "HTTP");
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_in_sequence() {
        let http_node = crate::dsl::http("https://api.example.com/data", "GET", None, None, 30);
        let sql_node = crate::dsl::sql("SELECT 1");
        let seq = crate::dsl::then_fn(&http_node, &sql_node);
        let fut = Durofut::from_json(&seq);
        assert_eq!(fut.node_type, "THEN");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_with_name() {
        let http_node = crate::dsl::http("https://api.example.com", "GET", None, None, 30);
        let named = crate::dsl::as_named(&http_node, "api_response");
        let fut = Durofut::from_json(&named);
        assert_eq!(fut.result_name, Some("api_response".to_string()));
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all",
    ))]
    #[pg_test]
    fn test_http_methods() {
        // Test all supported methods
        for method in &["GET", "POST", "PUT", "DELETE", "PATCH"] {
            let json = crate::dsl::http("https://example.com", method, None, None, 30);
            let fut = Durofut::from_json(&json);
            let config: serde_json::Value =
                serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
            assert_eq!(config["method"], *method);
        }
    }

    // ========================================================================
    // Unit Tests - Signals
    // ========================================================================

    #[pg_test]
    fn test_wait_for_signal_creates_valid_node() {
        let json = crate::dsl::wait_for_signal("approval", None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SIGNAL");
        assert!(fut.query.is_some());

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "approval");
        assert!(config["timeout_seconds"].is_null());
    }

    #[pg_test]
    fn test_wait_for_signal_with_timeout() {
        let json = crate::dsl::wait_for_signal("approval", Some(3600));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SIGNAL");

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "approval");
        assert_eq!(config["timeout_seconds"], 3600);
    }

    #[pg_test]
    fn test_wait_for_signal_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.wait_for_signal('test_signal')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "SIGNAL");

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "test_signal");
    }

    #[pg_test]
    fn test_wait_for_signal_with_timeout_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.wait_for_signal('test_signal', 60)")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "test_signal");
        assert_eq!(config["timeout_seconds"], 60);
    }

    #[pg_test]
    fn test_wait_for_signal_in_sequence() {
        let sql_node = crate::dsl::sql("SELECT 1");
        let signal_node = crate::dsl::wait_for_signal("go", None);
        let seq = crate::dsl::then_fn(&sql_node, &signal_node);
        let fut = Durofut::from_json(&seq);
        assert_eq!(fut.node_type, "THEN");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[pg_test]
    fn test_wait_for_signal_with_name() {
        let signal_node = crate::dsl::wait_for_signal("approval", None);
        let named = crate::dsl::as_named(&signal_node, "sig");
        let fut = Durofut::from_json(&named);
        assert_eq!(fut.result_name, Some("sig".to_string()));
    }

    // ========================================================================
    // Unit Tests - Instance Management
    // ========================================================================

    #[pg_test]
    fn test_start_returns_instance_id() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None, None);
        assert_eq!(instance_id.len(), 8);
        assert!(instance_id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[pg_test]
    fn test_start_with_label() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, Some("my-test-function"), None);
        assert_eq!(instance_id.len(), 8);
    }

    #[pg_test]
    fn test_start_creates_instance_row() {
        let fut = crate::dsl::sql("SELECT 42");
        let instance_id = crate::dsl::start(&fut, Some("test-instance-row"), None);
        let count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(*) FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(count, 1);
    }

    #[pg_test]
    fn test_status_returns_pending_for_new() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None, None);
        let status = crate::dsl::status(&instance_id);
        assert_eq!(status, Some("pending".to_string()));
    }

    // ========================================================================
    // Unit Tests - SQL Operators
    // ========================================================================

    #[pg_test]
    fn test_seq_operator_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_as_operator_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.sql('SELECT 1') |=> 'my_name'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.result_name, Some("my_name".to_string()));
    }

    #[pg_test]
    fn test_multiple_starts_different_ids() {
        // The same graph JSON can be reused with df.start() multiple times,
        // each producing a distinct instance with its own node IDs.
        let fut = crate::dsl::sql("SELECT 1");
        let id1 = crate::dsl::start(&fut, None, None);
        let id2 = crate::dsl::start(&fut, None, None);
        assert_ne!(id1, id2, "Each start should create a new instance");
    }

    #[pg_test]
    fn test_connection_info_builders() {
        use crate::types::{backend_duroxide_schema, postgres_connection_string};
        let conn = postgres_connection_string();
        assert!(!conn.is_empty());
        assert!(conn.contains("postgres://"));
        // Fresh installs use the "_duroxide" provider schema; upgraded installs
        // use the legacy "duroxide". Both contain "duroxide" as a substring.
        assert!(backend_duroxide_schema().contains("duroxide"));
    }

    #[pg_test]
    fn test_expired_instance_removal_respects_age_and_keep_count() {
        let conn = test_database_connection_string();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");

        let stats = rt.block_on(async {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(1)
                .connect(&conn)
                .await
                .expect("connect to test database");

            let test_ids = [
                "aa261001", "aa261002", "aa261003", "aa261004", "aa261005", "aa261006",
            ];
            let id_list = test_ids
                .iter()
                .map(|id| sql_literal(id))
                .collect::<Vec<_>>()
                .join(", ");

            delete_expired_test_rows(&pool, &id_list).await;

            let mut fixture_tx = pool.begin().await.expect("begin fixture transaction");
            sqlx::query("SET CONSTRAINTS ALL DEFERRED")
                .execute(&mut *fixture_tx)
                .await
                .expect("defer fixture constraints");
            sqlx::query(
                r#"
                -- max_keep=2, retention=30d. Terminal rows are ranked newest-first
                -- by COALESCE(completed_at, created_at):
                --   aa261001 (1d, r1)  -> keep (within cap, young)
                --   aa261002 (2d, r2)  -> keep (within cap, young)
                --   aa261003 (3d, r3)  -> REMOVE by the hard cap even though it is
                --                         only 3 days old (rank > max_keep)
                --   aa261004 (40d, r4) -> REMOVE (beyond cap and past retention)
                --   aa261005 (50d, r5) -> REMOVE (beyond cap and past retention)
                --   aa261006 (running) -> keep (non-terminal, never considered)
                -- aa261004/aa261005 are 'failed'/'cancelled' (NULL completed_at) with
                -- a forged far-future `updated_at`; they must still rank/age by their
                -- old `created_at`, proving `updated_at` is not trusted.
                WITH fixtures(id, label, root_node, status, age_days, has_completed_at, forge_future_updated_at) AS (
                    VALUES
                        ('aa261001', 'keep-recent-1', 'bb261001', 'completed', 1, true, false),
                        ('aa261002', 'keep-recent-2', 'bb261002', 'completed', 2, true, false),
                        ('aa261003', 'expire-young-over-cap', 'bb261003', 'completed', 3, true, false),
                        ('aa261004', 'expire-old-failed-forged', 'bb261004', 'failed', 40, false, true),
                        ('aa261005', 'expire-old-cancelled-forged', 'bb261005', 'cancelled', 50, false, true),
                        ('aa261006', 'keep-running', 'bb261006', 'running', 90, false, false)
                )
                INSERT INTO df.instances
                    (id, label, root_node, status, submitted_by, created_at, updated_at, completed_at)
                SELECT id,
                       label,
                       root_node,
                       status,
                       current_user::regrole,
                       pg_catalog.now() - (age_days::int * INTERVAL '1 day'),
                       CASE WHEN forge_future_updated_at
                            THEN pg_catalog.now() + INTERVAL '3650 days'
                            ELSE pg_catalog.now() - (age_days::int * INTERVAL '1 day')
                       END,
                       CASE WHEN has_completed_at
                            THEN pg_catalog.now() - (age_days::int * INTERVAL '1 day')
                            ELSE NULL
                       END
                FROM fixtures;
                "#,
            )
            .execute(&mut *fixture_tx)
            .await
            .expect("insert test instances");

            sqlx::query(
                r#"
                WITH fixtures(id, instance_id, status, age_days) AS (
                    VALUES
                        ('bb261001', 'aa261001', 'completed', 1),
                        ('bb261002', 'aa261002', 'completed', 2),
                        ('bb261003', 'aa261003', 'completed', 3),
                        ('bb261004', 'aa261004', 'failed', 40),
                        ('bb261005', 'aa261005', 'completed', 50),
                        ('bb261006', 'aa261006', 'running', 90)
                )
                INSERT INTO df.nodes
                    (id, instance_id, node_type, query, status, submitted_by, created_at, updated_at)
                SELECT id,
                       instance_id,
                       'SQL',
                       'SELECT 1',
                       status,
                       current_user::regrole,
                       pg_catalog.now() - (age_days::int * INTERVAL '1 day'),
                       pg_catalog.now() - (age_days::int * INTERVAL '1 day')
                FROM fixtures;
                "#,
            )
            .execute(&mut *fixture_tx)
            .await
            .expect("insert test nodes");

            let stats =
                crate::worker::delete_expired_instances_transaction(&mut fixture_tx, 30, 2)
                    .await
                    .expect("delete expired instances");

            let remaining_instances: i64 = sqlx::query_scalar(&format!(
                "SELECT pg_catalog.count(*)::bigint FROM df.instances WHERE id IN ({id_list})"
            ))
            .fetch_one(&mut *fixture_tx)
            .await
            .expect("count remaining instances");
            assert_eq!(remaining_instances, 3);

            let remaining_nodes: i64 = sqlx::query_scalar(&format!(
                "SELECT pg_catalog.count(*)::bigint FROM df.nodes WHERE instance_id IN ({id_list})"
            ))
            .fetch_one(&mut *fixture_tx)
            .await
            .expect("count remaining nodes");
            assert_eq!(remaining_nodes, 3);

            let remaining_ids: Vec<String> = sqlx::query_scalar(&format!(
                "SELECT id FROM df.instances WHERE id IN ({id_list}) ORDER BY id"
            ))
            .fetch_all(&mut *fixture_tx)
            .await
            .expect("load remaining ids");
            assert_eq!(remaining_ids, vec!["aa261001", "aa261002", "aa261006"]);

            fixture_tx
                .rollback()
                .await
                .expect("rollback test fixture");

            pool.close().await;
            stats
        });

        assert_eq!(stats.instances_deleted, 3);
        assert_eq!(stats.nodes_deleted, 3);
        assert_eq!(stats.deleted_ids.len(), 3);
    }

    #[pg_test]
    fn test_select_orphans_excludes_present_and_sub_orchestrations() {
        use std::collections::HashSet;

        // Failed engine instances reconciliation sees: a df-backed one, a genuine
        // orphan (rolled-back df.start), and two sub-orchestrations the engine
        // created internally for fan-out.
        let failed = vec![
            "inst-backed".to_string(),
            "inst-orphan".to_string(),
            "sub::inst-backed::0".to_string(),
            "inst-backed::sub::1".to_string(),
        ];
        // Only inst-backed still has a df.instances row.
        let present: HashSet<String> = ["inst-backed".to_string()].into_iter().collect();

        let orphans = crate::worker::select_orphans(failed, &present);

        // Only the df-less, non-sub instance is reclaimed.
        assert_eq!(orphans, vec!["inst-orphan".to_string()]);
    }

    // ========================================================================
    // Unit Tests - Workflow Variables
    // ========================================================================

    #[pg_test]
    fn test_setvar_sets_value() {
        crate::dsl::setvar("test_var", "test_value");
        let value = crate::dsl::getvar("test_var");
        assert_eq!(value, Some("test_value".to_string()));
    }

    #[pg_test]
    fn test_getvar_returns_value() {
        crate::dsl::setvar("my_var", "hello");
        let value = crate::dsl::getvar("my_var");
        assert_eq!(value, Some("hello".to_string()));
    }

    #[pg_test]
    fn test_getvar_returns_none_for_missing() {
        let value = crate::dsl::getvar("nonexistent_var_xyz");
        assert_eq!(value, None);
    }

    #[pg_test]
    fn test_unsetvar_removes_var() {
        crate::dsl::setvar("to_remove", "value");
        assert!(crate::dsl::getvar("to_remove").is_some());
        crate::dsl::unsetvar("to_remove");
        assert!(crate::dsl::getvar("to_remove").is_none());
    }

    #[pg_test]
    fn test_clearvars_removes_all() {
        crate::dsl::setvar("var1", "a");
        crate::dsl::setvar("var2", "b");
        crate::dsl::clearvars();
        assert!(crate::dsl::getvar("var1").is_none());
        assert!(crate::dsl::getvar("var2").is_none());
    }

    #[pg_test]
    fn test_setvar_via_sql() {
        Spi::run("SELECT df.setvar('sql_var', 'sql_value')").unwrap();

        let value = Spi::get_one::<String>("SELECT df.getvar('sql_var')").unwrap();
        assert_eq!(value, Some("sql_value".to_string()));
    }

    #[pg_test]
    fn test_setvar_overwrites() {
        crate::dsl::setvar("overwrite_var", "first");
        crate::dsl::setvar("overwrite_var", "second");
        let value = crate::dsl::getvar("overwrite_var");
        assert_eq!(value, Some("second".to_string()));
    }

    #[pg_test]
    fn test_vars_with_special_chars() {
        crate::dsl::setvar("special_var", "it's a \"test\"");
        let value = crate::dsl::getvar("special_var");
        assert_eq!(value, Some("it's a \"test\"".to_string()));
    }

    #[pg_test]
    fn test_setvar_works_in_user_session() {
        // In a normal user session, df.in_workflow is not set
        // so setvar should work
        crate::dsl::setvar("user_session_var", "works");

        // Verify the value was set
        let value = crate::dsl::getvar("user_session_var");
        assert_eq!(value, Some("works".to_string()));
    }

    #[pg_test]
    fn test_setvar_after_start_works() {
        // df.start() should not affect subsequent setvar calls
        let fut = crate::dsl::sql("SELECT 1");
        let _ = crate::dsl::start(&fut, None, None);

        // setvar should work fine after start returns
        crate::dsl::setvar("after_start_var", "works");
    }

    #[pg_test]
    fn test_setvar_cannot_be_used_in_seq_composition() {
        Spi::run(
            "CREATE OR REPLACE FUNCTION pg_temp.capture_error(sql_text text) RETURNS text
             LANGUAGE plpgsql AS $$
             BEGIN
               EXECUTE sql_text;
               RETURN NULL;
             EXCEPTION WHEN OTHERS THEN
               RETURN SQLERRM;
             END;
             $$;",
        )
        .unwrap();
        let msg = Spi::get_one::<String>(
            "SELECT pg_temp.capture_error($$SELECT df.seq(df.setvar('bad_var', 'x'), df.sql('SELECT 1'))$$)",
        )
        .unwrap()
        .unwrap();
        assert!(
            msg.contains("df.setvar cannot be used as a workflow step"),
            "Unexpected error: {msg}"
        );
    }

    #[pg_test]
    fn test_unsetvar_cannot_be_used_in_seq_composition() {
        Spi::run(
            "CREATE OR REPLACE FUNCTION pg_temp.capture_error(sql_text text) RETURNS text
             LANGUAGE plpgsql AS $$
             BEGIN
               EXECUTE sql_text;
               RETURN NULL;
             EXCEPTION WHEN OTHERS THEN
               RETURN SQLERRM;
             END;
             $$;",
        )
        .unwrap();
        let msg = Spi::get_one::<String>(
            "SELECT pg_temp.capture_error($$SELECT df.seq(df.unsetvar('bad_var'), df.sql('SELECT 1'))$$)",
        )
        .unwrap()
        .unwrap();
        assert!(
            msg.contains("df.unsetvar cannot be used as a workflow step"),
            "Unexpected error: {msg}"
        );
    }

    #[pg_test]
    fn test_clearvars_cannot_be_used_in_seq_composition() {
        Spi::run(
            "CREATE OR REPLACE FUNCTION pg_temp.capture_error(sql_text text) RETURNS text
             LANGUAGE plpgsql AS $$
             BEGIN
               EXECUTE sql_text;
               RETURN NULL;
             EXCEPTION WHEN OTHERS THEN
               RETURN SQLERRM;
             END;
             $$;",
        )
        .unwrap();
        let msg = Spi::get_one::<String>(
            "SELECT pg_temp.capture_error($$SELECT df.seq(df.clearvars(), df.sql('SELECT 1'))$$)",
        )
        .unwrap()
        .unwrap();
        assert!(
            msg.contains("df.clearvars cannot be used as a workflow step"),
            "Unexpected error: {msg}"
        );
    }

    #[pg_test]
    fn test_wait_for_completion_cannot_be_used_in_seq_composition() {
        // df.await_instance polls df.instances and would block on a
        // missing instance, so we can't actually call it in a unit test
        // (the background worker isn't running under pg_test). Instead we
        // exercise the same machinery directly: write the marker GUC that
        // await_instance would have written, then thread its plain-text
        // return value ("completed") into df.seq. Durofut::ensure should
        // detect the marker and reject the composition by name.
        Spi::run(
            "CREATE OR REPLACE FUNCTION pg_temp.capture_error(sql_text text) RETURNS text
             LANGUAGE plpgsql AS $$
             BEGIN
               EXECUTE sql_text;
               RETURN NULL;
             EXCEPTION WHEN OTHERS THEN
               RETURN SQLERRM;
             END;
             $$;",
        )
        .unwrap();
        let msg = Spi::get_one::<String>(
            "SELECT pg_temp.capture_error($body$
                 WITH _mark AS (
                     SELECT pg_catalog.set_config(
                         'df.non_future_helper',
                         'df.await_instance' || E'\\n' || pg_catalog.statement_timestamp()::text,
                         true
                     )
                 )
                 SELECT df.seq('completed', df.sql('SELECT 1')) FROM _mark
             $body$)",
        )
        .unwrap()
        .unwrap();
        assert!(
            msg.contains("df.await_instance cannot be used as a workflow step"),
            "Unexpected error: {msg}"
        );
    }

    // Note: Testing that setvar / await_instance fail in workflow context
    // requires E2E tests because it depends on the background worker setting
    // df.in_workflow='true' on its connections. See
    // tests/e2e/sql/04_variables_and_results.sql (setvar) and
    // tests/e2e/sql/09_graph_and_validation.sql (await_instance).

    // ========================================================================
    // Unit Tests - Explain Functionality
    // ========================================================================

    #[pg_test]
    fn test_explain_detects_instance_id() {
        // Create an instance first
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None, None);

        // Explain should recognize it as an instance ID
        let result = crate::explain::explain(&instance_id);
        // Should contain SQL node info, not an error
        assert!(
            result.contains("SQL") || result.contains("SELECT"),
            "Expected SQL visualization, got: {result}"
        );
    }

    #[pg_test]
    fn test_explain_expression_simple_sql() {
        // Dry-run explain of a simple SQL
        let result = crate::explain::explain("df.sql('SELECT 42')");
        assert!(result.contains("SQL"), "Expected SQL in output: {result}");
        assert!(result.contains("42"), "Expected query content: {result}");
    }

    #[pg_test]
    fn test_explain_expression_sequence() {
        // Dry-run explain of a sequence
        let result = crate::explain::explain("df.sql('SELECT 1') ~> df.sql('SELECT 2')");
        // Should show sequence with arrows
        assert!(
            result.contains("SELECT 1"),
            "Expected first query: {result}"
        );
        assert!(
            result.contains("SELECT 2"),
            "Expected second query: {result}"
        );
    }

    #[pg_test]
    fn test_explain_expression_sleep() {
        let result = crate::explain::explain("df.sleep(60)");
        assert!(result.contains("SLEEP"), "Expected SLEEP node: {result}");
        assert!(result.contains("60"), "Expected duration: {result}");
    }

    #[pg_test]
    fn test_explain_expression_loop() {
        let result = crate::explain::explain("df.loop(df.sql('SELECT 1'))");
        assert!(result.contains("LOOP"), "Expected LOOP: {result}");
        assert!(result.contains("body"), "Expected body section: {result}");
    }

    #[pg_test]
    fn test_explain_expression_if() {
        let result = crate::explain::explain(
            "df.if(df.sql('SELECT true'), df.sql('SELECT yes'), df.sql('SELECT no'))",
        );
        assert!(result.contains("IF"), "Expected IF: {result}");
        assert!(result.contains("then"), "Expected then branch: {result}");
        assert!(result.contains("else"), "Expected else branch: {result}");
    }

    #[pg_test]
    fn test_explain_expression_join() {
        let result = crate::explain::explain("df.join(df.sql('SELECT 1'), df.sql('SELECT 2'))");
        assert!(result.contains("JOIN"), "Expected JOIN: {result}");
        assert!(result.contains("branch"), "Expected branches: {result}");
    }

    #[pg_test]
    fn test_explain_no_side_effects() {
        // After explain, no orphan nodes should exist in df.nodes
        let before_count: i64 =
            Spi::get_one("SELECT COUNT(*) FROM df.nodes WHERE instance_id IS NULL")
                .unwrap()
                .unwrap_or(0);

        let _ = crate::explain::explain("df.sql('SELECT orphan_test') ~> df.sleep(999)");

        let after_count: i64 =
            Spi::get_one("SELECT COUNT(*) FROM df.nodes WHERE instance_id IS NULL")
                .unwrap()
                .unwrap_or(0);

        // Should be the same - no orphan nodes added
        assert_eq!(
            before_count, after_count,
            "Explain should not leave orphan nodes in df.nodes"
        );
    }

    #[pg_test]
    fn test_explain_invalid_instance_id() {
        // Test with non-existent instance ID
        let result = crate::explain::explain("deadbeef");
        assert!(
            result.contains("not found"),
            "Expected 'not found' error: {result}"
        );
    }

    #[pg_test]
    fn test_explain_complex_nested() {
        // Complex nested structure: loop with if inside
        let result = crate::explain::explain(
            "df.loop(df.if(df.sql('SELECT true'), df.sql('SELECT yes'), df.sql('SELECT no')))",
        );
        assert!(result.contains("LOOP"), "Expected LOOP: {result}");
        assert!(result.contains("IF"), "Expected IF: {result}");
    }

    // ========================================================================
    // Unit Tests - Auto-Wrap SQL Strings
    // ========================================================================

    #[pg_test]
    fn test_autowrap_sequence_plain_sql() {
        // Plain SQL strings should be auto-wrapped
        let result = crate::dsl::then_fn("SELECT 1", "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
        // Both children should exist as SQL nodes
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[pg_test]
    fn test_autowrap_sequence_mixed() {
        // Mix of explicit df.sql() and plain SQL
        let explicit = crate::dsl::sql("SELECT 1");
        let result = crate::dsl::then_fn(&explicit, "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_as_named_plain_sql() {
        // Plain SQL with naming
        let result = crate::dsl::as_named("SELECT 42 as answer", "my_result");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "SQL");
        assert_eq!(fut.result_name, Some("my_result".to_string()));
    }

    #[pg_test]
    fn test_autowrap_if_all_plain_sql() {
        // All three arguments as plain SQL
        let result = crate::dsl::if_fn("SELECT true", "SELECT 'yes'", "SELECT 'no'");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "IF");
    }

    #[pg_test]
    fn test_autowrap_join_plain_sql() {
        // Both branches as plain SQL
        let result = crate::dsl::join("SELECT 1", "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "JOIN");
    }

    #[pg_test]
    fn test_autowrap_loop_plain_sql() {
        // Loop body as plain SQL
        let result = crate::dsl::loop_fn("SELECT 1", None);
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "LOOP");
    }

    #[pg_test]
    fn test_autowrap_start_plain_sql() {
        // Start with plain SQL - simplest possible durable function
        let instance_id = crate::dsl::start("SELECT 42", Some("autowrap-test"), None);
        assert_eq!(instance_id.len(), 8);

        // Verify instance was created
        let count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(*) FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(count, 1);
    }

    #[pg_test]
    fn test_autowrap_via_sql_operator() {
        // Test that SQL operator ~> works with plain strings
        let result = Spi::get_one::<String>("SELECT 'SELECT 1' ~> 'SELECT 2'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_via_as_operator() {
        // Test that SQL operator |=> works with plain strings
        let result = Spi::get_one::<String>("SELECT 'SELECT 42' |=> 'my_var'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.result_name, Some("my_var".to_string()));
    }

    #[pg_test]
    fn test_is_durofut_detection() {
        // Test the detection logic
        let sql_node = crate::dsl::sql("SELECT 1");
        assert!(
            Durofut::is_durofut(&sql_node),
            "Should detect valid Durofut"
        );

        assert!(
            !Durofut::is_durofut("SELECT 1"),
            "Plain SQL should not be detected as Durofut"
        );
        assert!(
            !Durofut::is_durofut("{}"),
            "Empty JSON should not be Durofut"
        );
        assert!(
            !Durofut::is_durofut("{\"node_id\": \"short\"}"),
            "Invalid node_id should not be Durofut"
        );
    }

    // ========================================================================
    // Integration Tests - P0: Critical Path
    //
    // LIMITATION: pgrx test framework doesn't apply shared_preload_libraries,
    // so the background worker never starts. These tests timeout waiting for
    // functions that never get processed.
    //
    // To run E2E tests:
    //   1. cargo pgrx run pg17
    //   2. In psql, run the test SQL from USER_GUIDE.md
    //   3. Or use Docker: docker compose up -d && docker exec -it ...
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries - no background worker"]
    fn test_e2e_simple_sql() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_simple (id SERIAL PRIMARY KEY, val TEXT)")
            .unwrap();
        Spi::run("TRUNCATE test_e2e_simple").unwrap();

        // Start durable function
        let sql =
            crate::dsl::sql("INSERT INTO test_e2e_simple (val) VALUES ('hello') RETURNING id");
        let instance_id = crate::dsl::start(&sql, Some("test-e2e-simple"), None);

        // Wait for completion
        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify result contains the inserted row
        let output = result.unwrap();
        assert!(
            output.contains("row_count"),
            "Expected row_count in output: {output}"
        );

        // Verify data in table
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_simple WHERE val = 'hello'")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1, "Expected 1 row in table");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sequence() {
        // Create test table
        Spi::run(
            "CREATE TABLE IF NOT EXISTS test_e2e_seq (step INT, ts TIMESTAMPTZ DEFAULT now())",
        )
        .unwrap();
        Spi::run("TRUNCATE test_e2e_seq").unwrap();

        // Create sequence: step 1 then step 2
        let step1 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (1)");
        let step2 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (2)");
        let seq = crate::dsl::then_fn(&step1, &step2);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-seq"), None);

        // Wait for completion
        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify both rows exist in order
        let steps: Vec<i32> = Spi::connect(|client| {
            let mut steps = Vec::new();
            if let Ok(table) = client.select("SELECT step FROM test_e2e_seq ORDER BY ts", None, &[])
            {
                for row in table {
                    if let Ok(Some(step)) = row.get::<i32>(1) {
                        steps.push(step);
                    }
                }
            }
            steps
        });

        assert_eq!(steps, vec![1, 2], "Expected steps [1, 2], got {steps:?}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_variable_substitution() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_vars (source_id INT, copied_id INT)")
            .unwrap();
        Spi::run("TRUNCATE test_e2e_vars").unwrap();
        Spi::run("INSERT INTO test_e2e_vars (source_id) VALUES (42)").unwrap();

        // Create durable function: get value, use it in next query
        let get_val = crate::dsl::sql("SELECT source_id FROM test_e2e_vars LIMIT 1");
        let named = crate::dsl::as_named(&get_val, "src");
        let use_val = crate::dsl::sql(
            "INSERT INTO test_e2e_vars (copied_id) VALUES ($src) RETURNING copied_id",
        );
        let seq = crate::dsl::then_fn(&named, &use_val);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-vars"), None);

        // Wait for completion
        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify the value was copied
        let copied =
            Spi::get_one::<i32>("SELECT copied_id FROM test_e2e_vars WHERE copied_id IS NOT NULL")
                .unwrap();
        assert_eq!(copied, Some(42), "Expected copied_id = 42, got {copied:?}");
    }

    // ========================================================================
    // Integration Tests - P1: Important Features
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sleep() {
        let start_time = std::time::Instant::now();

        // Sleep for 2 seconds then select
        let sleep_node = crate::dsl::sleep(2);
        let sql_node = crate::dsl::sql("SELECT 'done'");
        let seq = crate::dsl::then_fn(&sleep_node, &sql_node);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-sleep"), None);

        // Wait for completion (with extra time for sleep)
        let result = poll_until_terminal(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let elapsed = start_time.elapsed();
        assert!(
            elapsed.as_secs() >= 2,
            "Expected at least 2s sleep, got {}s",
            elapsed.as_secs()
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_true_branch() {
        let condition = crate::dsl::sql("SELECT true");
        let then_branch = crate::dsl::sql("SELECT 'yes' as result");
        let else_branch = crate::dsl::sql("SELECT 'no' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-true"), None);

        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(output.contains("yes"), "Expected 'yes' in output: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_false_branch() {
        let condition = crate::dsl::sql("SELECT false");
        let then_branch = crate::dsl::sql("SELECT 'yes' as result");
        let else_branch = crate::dsl::sql("SELECT 'no' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-false"), None);

        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(output.contains("no"), "Expected 'no' in output: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_numeric_condition() {
        // 0 should be falsy
        let condition = crate::dsl::sql("SELECT 0");
        let then_branch = crate::dsl::sql("SELECT 'truthy' as result");
        let else_branch = crate::dsl::sql("SELECT 'falsy' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-zero"), None);

        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(
            output.contains("falsy"),
            "Expected 'falsy' for 0 condition: {output}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_join_parallel() {
        // Create test table
        Spi::run(
            "CREATE TABLE IF NOT EXISTS test_e2e_join (branch TEXT, ts TIMESTAMPTZ DEFAULT now())",
        )
        .unwrap();
        Spi::run("TRUNCATE test_e2e_join").unwrap();

        // Execute two branches in parallel
        let branch_a = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('A')");
        let branch_b = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('B')");
        let join_node = crate::dsl::join(&branch_a, &branch_b);

        let instance_id = crate::dsl::start(&join_node, Some("test-e2e-join"), None);

        let result = poll_until_terminal(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify both branches executed
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join")
            .unwrap()
            .unwrap();
        assert_eq!(count, 2, "Expected 2 rows from parallel branches");

        // Verify both A and B exist
        let a_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'A'")
            .unwrap()
            .unwrap();
        let b_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'B'")
            .unwrap()
            .unwrap();
        assert_eq!(a_count, 1, "Expected branch A");
        assert_eq!(b_count, 1, "Expected branch B");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_join3() {
        let a = crate::dsl::sql("SELECT 1 as val");
        let b = crate::dsl::sql("SELECT 2 as val");
        let c = crate::dsl::sql("SELECT 3 as val");
        let join_node = crate::dsl::join3(&a, &b, &c);

        let instance_id = crate::dsl::start(&join_node, Some("test-e2e-join3"), None);

        let result = poll_until_terminal(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Result should be an array of 3 results
        let output = result.unwrap();
        // The output is a JSON array of the branch results
        assert!(output.starts_with('['), "Expected array result: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_cancel_running() {
        // Start a long-running sleep
        let sleep_node = crate::dsl::sleep(300); // 5 minutes
        let instance_id = crate::dsl::start(&sleep_node, Some("test-e2e-cancel"), None);

        // Give it a moment to start
        std::thread::sleep(std::time::Duration::from_millis(500));

        // Check it's running
        let _status = get_duroxide_status(&instance_id);
        // Status might be Running or still pending

        // Cancel it
        let cancel_result = crate::dsl::cancel(&instance_id, "test cancellation");
        assert!(
            cancel_result.contains("cancelled") || cancel_result.contains("cancel"),
            "Expected cancellation confirmation: {cancel_result}"
        );

        // Verify it's cancelled
        std::thread::sleep(std::time::Duration::from_millis(500));
        let final_status = get_duroxide_status(&instance_id);
        assert!(
            final_status == Some("Canceled".to_string())
                || final_status == Some("Failed".to_string()),
            "Expected Canceled status, got {final_status:?}"
        );
    }

    // ========================================================================
    // Integration Tests - P2: Monitoring & Error Handling
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_list_instances() {
        // Start a few durable functions
        let sql1 = crate::dsl::sql("SELECT 1");
        let sql2 = crate::dsl::sql("SELECT 2");
        let id1 = crate::dsl::start(&sql1, Some("test-list-1"), None);
        let id2 = crate::dsl::start(&sql2, Some("test-list-2"), None);

        // Wait for both to complete
        let _ = poll_until_terminal(&id1, 10);
        let _ = poll_until_terminal(&id2, 10);

        // Query list_instances
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM df.list_instances()")
            .unwrap()
            .unwrap_or(0);
        assert!(count >= 2, "Expected at least 2 instances, got {count}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_metrics() {
        // Just verify the function works
        let total = Spi::get_one::<i64>("SELECT total_instances FROM df.metrics()");
        assert!(total.is_ok(), "metrics() should be callable");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_instance_info() {
        let sql = crate::dsl::sql("SELECT 'info-test'");
        let instance_id = crate::dsl::start(&sql, Some("test-info-label"), None);

        let _ = poll_until_terminal(&instance_id, 10);

        // Query instance_info
        let orch_name = Spi::get_one::<String>(&format!(
            "SELECT function_name FROM df.instance_info('{instance_id}')"
        ));

        assert!(orch_name.is_ok(), "instance_info should be callable");
        if let Ok(Some(name)) = orch_name {
            assert_eq!(name, "ExecuteWorkflow", "Expected ExecuteWorkflow function");
        }
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_instance_nodes() {
        // Create a sequence with 2 SQL nodes
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let seq = crate::dsl::then_fn(&a, &b);
        let instance_id = crate::dsl::start(&seq, None, None);

        let _ = poll_until_terminal(&instance_id, 10);

        // Query instance_nodes - should have 3 nodes (2 SQL + 1 THEN)
        let node_count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(DISTINCT node_id) FROM df.instance_nodes('{instance_id}')"
        ))
        .unwrap()
        .unwrap_or(0);

        assert!(
            node_count >= 3,
            "Expected at least 3 nodes, got {node_count}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sql_error() {
        // Try to select from a non-existent table
        let sql = crate::dsl::sql("SELECT * FROM nonexistent_table_xyz_12345");
        let instance_id = crate::dsl::start(&sql, Some("test-sql-error"), None);

        let result = poll_until_terminal(&instance_id, 10);

        // Should fail
        assert!(result.is_err(), "Expected function to fail");
        let err = result.unwrap_err();
        assert!(
            err.contains("Failed") || err.contains("does not exist"),
            "Expected error about non-existent table: {err}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_status_sync() {
        let sql = crate::dsl::sql("SELECT 'sync-test'");
        let instance_id = crate::dsl::start(&sql, Some("test-status-sync"), None);

        let result = poll_until_terminal(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Check PostgreSQL table status
        let pg_status = Spi::get_one::<String>(&format!(
            "SELECT status FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap();

        assert_eq!(
            pg_status,
            Some("completed".to_string()),
            "Expected 'completed' in PostgreSQL table, got {pg_status:?}"
        );
    }

    // ========================================================================
    // Negative-path tests: validation, malformed config, ensure_strict
    // ========================================================================

    #[pg_test]
    fn test_validate_rejects_malformed_condition_node_object() {
        // A condition_node that is a JSON object but not a valid Durofut
        // should be rejected by validate_recursive
        let durofut = Durofut {
            node_type: "IF".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'then'".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'else'".to_string()),
                ..Default::default()
            })),
            query: Some(r#"{"condition_node": {"foo": "bar"}}"#.to_string()),
            ..Default::default()
        };
        let result = durofut.validate_recursive();
        assert!(
            result.is_err(),
            "Should reject malformed condition_node object"
        );
        assert!(
            result.unwrap_err().contains("condition_node"),
            "Error should mention condition_node"
        );
    }

    #[pg_test]
    fn test_validate_rejects_condition_node_number() {
        // condition_node as a number should be rejected
        let durofut = Durofut {
            node_type: "LOOP".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 1".to_string()),
                ..Default::default()
            })),
            query: Some(r#"{"condition_node": 42}"#.to_string()),
            ..Default::default()
        };
        let result = durofut.validate_recursive();
        assert!(result.is_err(), "Should reject numeric condition_node");
    }

    #[pg_test]
    fn test_validate_rejects_condition_node_string_id() {
        // condition_node as a string ID (old format) should be rejected
        let durofut = Durofut {
            node_type: "IF".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'then'".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'else'".to_string()),
                ..Default::default()
            })),
            query: Some(r#"{"condition_node": "a1b2c3d4"}"#.to_string()),
            ..Default::default()
        };
        let result = durofut.validate_recursive();
        assert!(result.is_err(), "Should reject string ID condition_node");
    }

    #[pg_test]
    fn test_validate_rejects_deeply_nested_invalid_node_type() {
        // Valid outer graph but a deeply nested node has an invalid type
        let inner_bad = Durofut {
            node_type: "BOGUS".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        let middle = Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 1".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(inner_bad)),
            ..Default::default()
        };
        let root = Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 0".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(middle)),
            ..Default::default()
        };
        let result = root.validate_recursive();
        assert!(
            result.is_err(),
            "Should catch invalid node_type deep in the tree"
        );
        assert!(
            result.unwrap_err().contains("BOGUS"),
            "Error should mention the invalid type"
        );
    }

    #[pg_test]
    fn test_validate_rejects_malformed_extra_nodes() {
        // An extra_nodes entry that is not a valid Durofut
        let durofut = Durofut {
            node_type: "JOIN".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 1".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 2".to_string()),
                ..Default::default()
            })),
            query: Some(r#"{"extra_nodes": [{"not": "a durofut"}]}"#.to_string()),
            ..Default::default()
        };
        let result = durofut.validate_recursive();
        assert!(result.is_err(), "Should reject malformed extra_nodes entry");
        assert!(
            result.unwrap_err().contains("extra_nodes[0]"),
            "Error should identify the index"
        );
    }

    #[pg_test]
    fn test_ensure_strict_malformed_structure_valid_type() {
        // JSON with valid node_type but invalid structure (left_node as string)
        let input = r#"{"node_type": "THEN", "left_node": "not-an-object"}"#;
        let result = Durofut::ensure_strict(input);
        assert!(result.is_err(), "Should reject malformed Durofut structure");
        let err = result.unwrap_err();
        assert!(
            err.contains("Malformed"),
            "Error should say 'Malformed', got: {err}"
        );
        assert!(
            !err.contains("Unknown node_type"),
            "Error should NOT say 'Unknown node_type' for valid type, got: {err}"
        );
    }

    #[pg_test]
    fn test_ensure_strict_unknown_node_type() {
        // JSON with truly unknown node_type
        let input = r#"{"node_type": "BOGUS"}"#;
        let result = Durofut::ensure_strict(input);
        assert!(result.is_err(), "Should reject unknown node_type");
        assert!(
            result.unwrap_err().contains("Unknown node_type"),
            "Error should say 'Unknown node_type'"
        );
    }

    #[pg_test]
    fn test_ensure_strict_plain_sql() {
        // Non-JSON string should be treated as SQL
        let result = Durofut::ensure_strict("SELECT 1");
        assert!(result.is_ok());
        let d = result.unwrap();
        assert_eq!(d.node_type, "SQL");
        assert_eq!(d.query, Some("SELECT 1".to_string()));
    }

    #[pg_test]
    fn test_validate_accepts_valid_condition_node() {
        // A properly formed IF node with embedded Durofut condition should pass
        let condition = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT true".to_string()),
            ..Default::default()
        };
        let config = serde_json::json!({ "condition_node": condition });
        let durofut = Durofut {
            node_type: "IF".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'then'".to_string()),
                ..Default::default()
            })),
            right_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 'else'".to_string()),
                ..Default::default()
            })),
            query: Some(config.to_string()),
            ..Default::default()
        };
        assert!(
            durofut.validate_recursive().is_ok(),
            "Valid IF graph should pass validation"
        );
    }

    #[pg_test]
    fn test_connection_limit_guc_defaults() {
        use crate::types::{
            get_execution_acquire_timeout, get_max_duroxide_connections,
            get_max_management_connections, get_max_user_connections,
        };

        assert_eq!(get_max_management_connections(), 6);
        assert_eq!(get_max_duroxide_connections(), 10);
        assert_eq!(get_max_user_connections(), 10);
        assert_eq!(
            get_execution_acquire_timeout(),
            std::time::Duration::from_secs(30)
        );
    }

    // ========================================================================
    // Unit Tests - Superuser GUC
    // ========================================================================

    #[pg_test]
    fn test_superuser_guc_boot_default_is_off() {
        // The test postgresql.conf overrides enable_superuser_instances = on,
        // but the boot_val (before any config override) should still be 'off'.
        let boot_val = Spi::get_one::<String>(
            "SELECT boot_val FROM pg_catalog.pg_settings \
             WHERE name = 'pg_durable.enable_superuser_instances'",
        )
        .unwrap()
        .expect("GUC should exist in pg_settings");
        assert_eq!(
            boot_val, "off",
            "pg_durable.enable_superuser_instances boot default should be 'off'"
        );
    }

    #[pg_test]
    fn test_superuser_guc_context_is_postmaster() {
        // Verify the GUC requires a server restart to change.
        let context = Spi::get_one::<String>(
            "SELECT context FROM pg_catalog.pg_settings \
             WHERE name = 'pg_durable.enable_superuser_instances'",
        )
        .unwrap()
        .expect("GUC should exist in pg_settings");
        assert_eq!(
            context, "postmaster",
            "pg_durable.enable_superuser_instances should be postmaster-level"
        );
    }

    #[pg_test]
    fn test_is_role_superuser_oid_identifies_superuser() {
        // pg_test runs as postgres (superuser); GetUserId() returns its OID.
        let su_oid = unsafe { pgrx::pg_sys::GetUserId() };
        let result = crate::types::is_role_superuser_oid(su_oid)
            .expect("superuser check should not error for postgres");
        assert!(
            result,
            "current user (postgres) should be identified as a superuser"
        );
    }

    #[pg_test]
    fn test_is_role_superuser_oid_identifies_non_superuser() {
        Spi::run(
            "DO $$ BEGIN CREATE ROLE su_guc_unit_nonsuperuser NOLOGIN; \
             EXCEPTION WHEN duplicate_object THEN NULL; END $$",
        )
        .unwrap();
        // Use PostgreSQL's get_role_oid() to obtain the native Oid directly,
        // avoiding SPI datum type conversion issues with the oid type.
        let role_name = std::ffi::CString::new("su_guc_unit_nonsuperuser").unwrap();
        let role_oid = unsafe { pgrx::pg_sys::get_role_oid(role_name.as_ptr(), false) };
        let result = crate::types::is_role_superuser_oid(role_oid)
            .expect("superuser check should not error for non-superuser role");
        Spi::run("DROP ROLE IF EXISTS su_guc_unit_nonsuperuser").unwrap();
        assert!(
            !result,
            "su_guc_unit_nonsuperuser should not be identified as a superuser"
        );
    }

    #[pg_test]
    fn test_start_allows_superuser_when_guc_on() {
        // postgresql_conf_options() sets enable_superuser_instances = on.
        // Verify df.start() succeeds for superuser with GUC on.
        let instance_id =
            Spi::get_one::<String>("SELECT df.start('SELECT 1', 'unit-test-su-allowed')")
                .unwrap()
                .expect("df.start() should return an instance_id when GUC is on");
        assert!(!instance_id.is_empty(), "instance_id should not be empty");
        // Cancel immediately so the BGW does not attempt to execute this instance.
        Spi::run(&format!("SELECT df.cancel('{instance_id}')")).unwrap();
    }

    // ========================================================================
    // Regression Tests - Correctness Bugs from Reliability Audit
    // ========================================================================

    // --- C1: Empty result set must evaluate as false in conditions ---

    #[pg_test]
    fn test_evaluate_condition_empty_rows_is_false() {
        use crate::types::evaluate_condition;
        // Simulates a SQL condition query that returns zero rows
        let empty_result = r#"{"rows":[],"row_count":0}"#;
        assert_eq!(
            evaluate_condition(empty_result).unwrap(),
            false,
            "Empty result set should evaluate as false for conditions"
        );
    }

    #[pg_test]
    fn test_evaluate_condition_single_true_row() {
        use crate::types::evaluate_condition;
        let result = r#"{"rows":[{"col":true}],"row_count":1}"#;
        assert_eq!(
            evaluate_condition(result).unwrap(),
            true,
            "Single row with true value should be truthy"
        );
    }

    #[pg_test]
    fn test_evaluate_condition_single_false_row() {
        use crate::types::evaluate_condition;
        let result = r#"{"rows":[{"col":false}],"row_count":1}"#;
        assert_eq!(
            evaluate_condition(result).unwrap(),
            false,
            "Single row with false value should be falsy"
        );
    }

    #[pg_test]
    fn test_evaluate_condition_zero_count_is_falsy() {
        use crate::types::evaluate_condition;
        // A query like SELECT count(*) FROM empty_table returns 0
        let result = r#"{"rows":[{"count":0}],"row_count":1}"#;
        assert_eq!(
            evaluate_condition(result).unwrap(),
            false,
            "Row with zero value should be falsy"
        );
    }

    // --- H1: Recursion depth limit rejects overly deep graphs ---

    #[pg_test]
    fn test_validate_rejects_graph_exceeding_depth_limit() {
        use crate::types::MAX_GRAPH_DEPTH;
        // Build a chain deeper than MAX_GRAPH_DEPTH
        let mut node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        for _ in 0..MAX_GRAPH_DEPTH + 1 {
            node = Durofut {
                node_type: "THEN".to_string(),
                left_node: Some(Box::new(node)),
                right_node: Some(Box::new(Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                })),
                ..Default::default()
            };
        }
        let result = node.validate_recursive();
        assert!(
            result.is_err(),
            "Graph exceeding depth limit must be rejected"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("maximum nesting depth"),
            "Error should mention depth limit, got: {err}"
        );
    }

    #[pg_test]
    fn test_validate_accepts_graph_within_depth_limit() {
        // A moderately deep graph (10 levels) should be fine
        let mut node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        for _ in 0..10 {
            node = Durofut {
                node_type: "THEN".to_string(),
                left_node: Some(Box::new(node)),
                right_node: Some(Box::new(Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                })),
                ..Default::default()
            };
        }
        let result = node.validate_recursive();
        assert!(
            result.is_ok(),
            "Graph within depth limit should be accepted"
        );
    }

    // --- H2: Node count limit rejects overly large graphs ---

    #[pg_test]
    fn test_validate_rejects_graph_exceeding_node_count() {
        use crate::types::MAX_GRAPH_NODES;

        // Build a shallow-but-wide graph using a JOIN node with many extra_nodes.
        // This exceeds MAX_GRAPH_NODES without exceeding MAX_GRAPH_DEPTH (stays at depth 1).
        // Serialize the template node once and clone via vec![...; N] for predictable memory.
        let sql_node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };

        let sql_value = serde_json::to_value(&sql_node).unwrap();
        let extra_nodes: Vec<serde_json::Value> = vec![sql_value; MAX_GRAPH_NODES];
        let config = serde_json::json!({ "extra_nodes": extra_nodes });

        let join_node = Durofut {
            node_type: "JOIN".to_string(),
            left_node: Some(Box::new(sql_node.clone())),
            right_node: Some(Box::new(sql_node)),
            query: Some(config.to_string()),
            ..Default::default()
        };

        let result = join_node.validate_recursive();
        assert!(
            result.is_err(),
            "validate_recursive should reject graph exceeding node count limit"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("maximum node count"),
            "Error should mention node count limit, got: {err}"
        );
    }

    // --- H4: try_from_json returns error instead of panicking ---

    #[pg_test]
    fn test_try_from_json_invalid_json_returns_error() {
        let result = Durofut::try_from_json("not valid json at all");
        assert!(
            result.is_err(),
            "try_from_json should return Err on invalid JSON"
        );
        assert!(
            result.unwrap_err().contains("failed to deserialize"),
            "Error message should mention deserialization failure"
        );
    }

    #[pg_test]
    fn test_try_from_json_valid_json_succeeds() {
        let json = crate::dsl::sql("SELECT 42");
        let result = Durofut::try_from_json(&json);
        assert!(
            result.is_ok(),
            "try_from_json should succeed on valid Durofut JSON"
        );
        let d = result.unwrap();
        assert_eq!(d.node_type, "SQL");
        assert_eq!(d.query, Some("SELECT 42".to_string()));
    }

    #[pg_test]
    fn test_try_from_json_corrupted_node_type_returns_error() {
        // Valid JSON structure but missing required fields
        let corrupted = r#"{"not_a_durofut": true}"#;
        let result = Durofut::try_from_json(corrupted);
        assert!(
            result.is_err(),
            "try_from_json should return Err on structurally invalid Durofut"
        );
    }

    // --- C5: Client connection error detection ---

    #[pg_test]
    fn test_is_connection_error_detects_failures() {
        // Validates the heuristic used to reset the client on connection-level errors.
        assert!(crate::client::is_connection_error_for_test(
            "connection refused"
        ));
        assert!(crate::client::is_connection_error_for_test("broken pipe"));
        assert!(crate::client::is_connection_error_for_test(
            "pool timed out"
        ));
        assert!(crate::client::is_connection_error_for_test("reset by peer"));
        assert!(crate::client::is_connection_error_for_test(
            "connection closed"
        ));
        // Non-connection errors should NOT trigger a reset
        assert!(!crate::client::is_connection_error_for_test(
            "permission denied"
        ));
        assert!(!crate::client::is_connection_error_for_test(
            "Instance not found"
        ));
    }

    // --- H6: CGNAT SSRF blocklist ---

    #[pg_test]
    fn test_ssrf_blocks_cgnat_range() {
        use std::net::{IpAddr, Ipv4Addr};
        // 100.64.0.0/10 must be blocked
        assert!(
            crate::ssrf::check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))).is_some(),
            "100.64.0.1 (CGNAT) should be blocked"
        );
        assert!(
            crate::ssrf::check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 127, 255, 254))).is_some(),
            "100.127.255.254 (CGNAT) should be blocked"
        );
        // Outside CGNAT range should be allowed
        assert!(
            crate::ssrf::check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 128, 0, 1))).is_none(),
            "100.128.0.1 (NOT CGNAT) should be allowed"
        );
    }

    // --- M1: Row-set expansion limit ---

    #[pg_test]
    fn test_row_set_expansion_limit_via_dsl() {
        // The row-set expansion limit (10,000 rows) is enforced inside
        // expand_row_set(). This is tested thoroughly in the unit test
        // types::tests::test_row_set_expansion_rejects_oversized_result.
        // Here we just verify the types module is accessible and the limit works
        // at the substitution layer by checking a small expansion works.
        use crate::types::substitute_all;
        use std::collections::HashMap;

        let mut results = HashMap::new();
        let json = r#"{"rows":[{"id":1},{"id":2}],"row_count":2}"#;
        results.insert("batch".to_string(), json.to_string());

        let sys = crate::types::SystemVars {
            instance_id: "test1234".to_string(),
            label: None,
        };
        let vars = HashMap::new();
        let result = substitute_all("SELECT * FROM $batch.*", &results, &vars, &sys);
        assert!(result.is_ok(), "Small row-set should expand successfully");
        assert!(
            result.unwrap().contains("VALUES"),
            "Should produce a VALUES clause"
        );
    }

    // --- M7: Loop iteration counter persisted across continue_as_new ---

    #[pg_test]
    fn test_function_input_loop_iteration_serialization() {
        use crate::types::FunctionInput;

        // Verify loop_iteration is preserved through serialization
        let input = FunctionInput {
            instance_id: "test123".to_string(),
            label: Some("test".to_string()),
            vars: std::collections::HashMap::new(),
            loop_iteration: 42,
        };
        let json = serde_json::to_string(&input).unwrap();
        let deserialized: FunctionInput = serde_json::from_str(&json).unwrap();
        assert_eq!(
            deserialized.loop_iteration, 42,
            "loop_iteration must survive serialization round-trip"
        );
    }

    #[pg_test]
    fn test_function_input_loop_iteration_defaults_to_zero() {
        use crate::types::FunctionInput;

        // Verify backward compat: old FunctionInput JSON without loop_iteration
        // deserializes with loop_iteration = 0
        let json = r#"{"instance_id":"abc12345","label":"test","vars":{}}"#;
        let input: FunctionInput = serde_json::from_str(json).unwrap();
        assert_eq!(
            input.loop_iteration, 0,
            "Missing loop_iteration should default to 0 for backward compatibility"
        );
    }

    // --- M8: Malformed loop condition config detection ---

    #[pg_test]
    fn test_malformed_loop_condition_detected_at_validate() {
        // A LOOP node whose condition_node is a plain string (not a Durofut object)
        // should be rejected by validate_recursive because for_each_config_child
        // requires condition_node to deserialize as a valid Durofut.
        let node = Durofut {
            node_type: "LOOP".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 1".to_string()),
                ..Default::default()
            })),
            // Malformed config: valid JSON but condition_node is a string, not a Durofut object.
            query: Some(r#"{"condition_node": "nonexist"}"#.to_string()),
            ..Default::default()
        };
        // Validate should fail because condition_node is not a valid Durofut object
        let err = node.validate_recursive().unwrap_err();
        assert!(
            err.contains("condition_node"),
            "Error should mention condition_node, got: {err}"
        );

        // But if the config is totally not JSON, for_each_config_child skips it
        // (it's treated as a plain query string, not a config object).
        let non_json_node = Durofut {
            node_type: "LOOP".to_string(),
            left_node: Some(Box::new(Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT 1".to_string()),
                ..Default::default()
            })),
            query: Some("this is not json at all!!!".to_string()),
            ..Default::default()
        };
        assert!(
            non_json_node.validate_recursive().is_ok(),
            "LOOP with non-JSON config passes DSL validation (caught at execution time)"
        );
    }
}

/// Required by `cargo pgrx test`
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // Note: Cannot use pgrx SPI here as we're outside PostgreSQL
    }

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![
            "shared_preload_libraries = 'pg_durable'",
            "pg_durable.worker_role = 'postgres'",
            "pg_durable.database = 'postgres'",
            "pg_durable.enable_superuser_instances = on",
        ]
    }
}
