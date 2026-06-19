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
-- The sensitive functions (df.http, df.grant_usage, df.revoke_usage) had their
-- PUBLIC EXECUTE revoked at install time and were never in the list; they are
-- still granted explicitly here, so their protection is unchanged. The new
-- in-transaction enqueue wrappers are also private (REVOKE FROM PUBLIC below)
-- and are granted explicitly to df users because df.start()/df.cancel()/df.signal()
-- call them via SPI as the calling role.
--
-- This CREATE OR REPLACE brings pre-existing installs in line with fresh
-- 0.2.4 installs (see src/lib.rs). The new body works against the existing
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

    -- Admin helpers — only for delegated administrators.
    IF with_grant THEN
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    END IF;

    -- In-transaction enqueue wrappers — SECURITY DEFINER, revoked from PUBLIC at
    -- install. Granted unconditionally to every df user because df.start() /
    -- df.cancel() / df.signal() call them via SPI as the calling role; their own
    -- internal authorization checks gate access to other users' instances.
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df._enqueue_orchestrator_start(text, text, text) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df._enqueue_orchestrator_cancel(text, text) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
    EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df._enqueue_orchestrator_signal(text, text, text) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;

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
-- on the sensitive/admin functions, EXECUTE on the new enqueue wrappers, and
-- the table privileges. Note: a role granted under the OLD grant_usage()
-- (explicit per-function EXECUTE) may retain inert EXECUTE entries on ordinary
-- functions after this revoke; they are harmless because schema USAGE is gone,
-- and clear on the next drop/regrant cycle.
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
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.revoke_usage(text) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    -- In-transaction enqueue wrappers (granted unconditionally by grant_usage()).
    -- A delegated admin may not be the grantor of these; skip if so.
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_start(text, text, text) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_cancel(text, text) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_signal(text, text, text) FROM %I CASCADE', p_role);
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
-- In-transaction enqueue wrappers + reconciler (atomic df.start/cancel/signal,
-- and df.reconcile()).
--
-- df.start()/df.cancel()/df.signal() now enqueue the duroxide work item over SPI
-- inside the CALLER'S transaction (so a rollback undoes the enqueue), through
-- these SECURITY DEFINER wrappers. The orchestrator queue is owner-only, so the
-- wrappers perform the privileged INSERT; each builds the work item server-side
-- and authorizes the caller (df.start by brand-new-instance state; df.cancel /
-- df.signal by pg_has_role(session_user, <owner>, 'MEMBER')). They are revoked
-- from PUBLIC and granted to df users by df.grant_usage() (above).
--
-- df.reconcile() is the admin-only backstop that deletes orphaned duroxide
-- instance subtrees with no df.instances row and fails stuck df.instances rows.
--
-- The wrappers resolve the duroxide schema via df.duroxide_schema() (defined in
-- the 0.2.2→0.2.3 upgrade) and require the duroxide-pg provider; df.start /
-- df.cancel / df.signal fall back to the out-of-band path when it is absent, so
-- this upgrade is safe on a fresh '_duroxide' or a legacy 'duroxide' schema.
-- ============================================================================
CREATE FUNCTION df._enqueue_orchestrator_start(
    p_instance_id   text,
    p_orchestration text,
    p_input         text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
DECLARE
    sch       text := df.duroxide_schema();
    work_item text;
    v_blocked boolean;
BEGIN
    -- This wrapper is not a generic privileged "start any orchestration" entry
    -- point. df.start() passes the root graph-executor name and FunctionInput
    -- JSON; reject anything else so a caller cannot use the SECURITY DEFINER
    -- privilege to enqueue an internal sub-orchestration with crafted input.
    IF p_orchestration OPERATOR(pg_catalog.<>) 'pg_durable::orchestration::execute-function-graph' THEN
        RAISE EXCEPTION 'pg_durable: invalid start orchestration %', p_orchestration
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF (p_input::jsonb ->> 'instance_id') IS DISTINCT FROM p_instance_id THEN
        RAISE EXCEPTION 'pg_durable: start input instance_id does not match %', p_instance_id
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Authorization. This runs as the (privileged) definer, so it must not
    -- trust the caller to only target their own instance. Permit the enqueue
    -- only for a brand-new, not-yet-started instance: a 'pending' df.instances
    -- row with no orchestrator-queue entry and no duroxide instance. Under the
    -- atomic-start path a committed df.instances row always has its queue row in
    -- the same transaction, so this state is reachable only for the instance the
    -- caller (df.start) just inserted in the current transaction — never another
    -- user's committed instance. This is what stops a caller from forging work
    -- against a foreign instance.
    EXECUTE pg_catalog.format(
        'SELECT NOT EXISTS (SELECT 1 FROM df.instances i WHERE i.id = $1 AND i.status = ''pending'') '
        '    OR EXISTS (SELECT 1 FROM %I.orchestrator_queue q WHERE q.instance_id = $1) '
        '    OR EXISTS (SELECT 1 FROM %I.instances d WHERE d.instance_id = $1)',
        sch, sch)
    INTO v_blocked
    USING p_instance_id;

    IF v_blocked THEN
        RAISE EXCEPTION 'pg_durable: not authorized to enqueue a start for instance %', p_instance_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Build the StartOrchestration work item server-side so the caller cannot
    -- choose the work-item variant (no CancelInstance/ExternalRaised/etc.) or
    -- target a different instance. Mirrors duroxide's WorkItem::StartOrchestration.
    work_item := pg_catalog.json_build_object(
        'StartOrchestration', pg_catalog.json_build_object(
            'instance',        p_instance_id,
        'orchestration',   'pg_durable::orchestration::execute-function-graph',
            'input',           p_input,
            'version',         NULL,
            'parent_instance', NULL,
            'parent_id',       NULL,
            'execution_id',    1))::text;

    EXECUTE pg_catalog.format('SELECT %I.enqueue_orchestrator_work($1, $2, $3)', sch)
        USING p_instance_id, work_item, pg_catalog.now();
END;
$fn$;

REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_start(text, text, text) FROM PUBLIC;

CREATE FUNCTION df._enqueue_orchestrator_cancel(p_instance_id text, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
DECLARE
    sch       text := df.duroxide_schema();
    owner_oid oid;
BEGIN
    SELECT i.submitted_by::oid INTO owner_oid FROM df.instances i WHERE i.id = p_instance_id;
    IF owner_oid IS NULL OR NOT pg_catalog.pg_has_role(session_user, owner_oid, 'MEMBER') THEN
        RAISE EXCEPTION 'pg_durable: not authorized to cancel instance %', p_instance_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    EXECUTE pg_catalog.format('SELECT %I.enqueue_orchestrator_work($1, $2, $3)', sch)
        USING p_instance_id,
              pg_catalog.json_build_object('CancelInstance',
                  pg_catalog.json_build_object('instance', p_instance_id, 'reason', p_reason))::text,
              pg_catalog.now();
END;
$fn$;

REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_cancel(text, text) FROM PUBLIC;

CREATE FUNCTION df._enqueue_orchestrator_signal(p_instance_id text, p_name text, p_data text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
DECLARE
    sch       text := df.duroxide_schema();
    owner_oid oid;
BEGIN
    SELECT i.submitted_by::oid INTO owner_oid FROM df.instances i WHERE i.id = p_instance_id;
    IF owner_oid IS NULL OR NOT pg_catalog.pg_has_role(session_user, owner_oid, 'MEMBER') THEN
        RAISE EXCEPTION 'pg_durable: not authorized to signal instance %', p_instance_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Raise the event for the target instance and every RUNNING descendant
    -- (a sub-orchestration — JOIN/RACE branch or loop generation — may be the one
    -- waiting on the signal), mirroring the out-of-band fan-out. %1$I = schema.
    EXECUTE pg_catalog.format(
        'INSERT INTO %1$I.orchestrator_queue (instance_id, work_item, visible_at, created_at) '
        'SELECT t.instance_id, '
        '       pg_catalog.json_build_object(''ExternalRaised'', '
        '           pg_catalog.json_build_object(''instance'', t.instance_id, ''name'', $2, ''data'', $3))::text, '
        '       pg_catalog.now(), pg_catalog.now() '
        'FROM ( '
        '    WITH RECURSIVE tree AS ( '
        '        SELECT i.instance_id, i.current_execution_id, true AS is_root '
        '        FROM %1$I.instances i WHERE i.instance_id = $1 '
        '        UNION '
        '        SELECT c.instance_id, c.current_execution_id, false '
        '        FROM %1$I.instances c JOIN tree p ON c.parent_instance_id = p.instance_id '
        '    ) '
        '    SELECT tr.instance_id '
        '    FROM tree tr '
        '    LEFT JOIN %1$I.executions e '
        '      ON e.instance_id = tr.instance_id AND e.execution_id = tr.current_execution_id '
        '    WHERE tr.is_root OR pg_catalog.lower(COALESCE(e.status, '''')) = ''running'' '
        ') t',
        sch)
    USING p_instance_id, p_name, p_data;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION df._enqueue_orchestrator_signal(text, text, text) FROM PUBLIC;

CREATE FUNCTION df.reconcile(p_grace_seconds integer DEFAULT 60)
RETURNS TABLE(duroxide_orphans_deleted bigint, stuck_instances_failed bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
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
    --    queued start (lost enqueue) → mark failed. The duroxide queue row
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
