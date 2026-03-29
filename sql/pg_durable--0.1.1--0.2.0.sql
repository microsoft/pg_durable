-- pg_durable upgrade: 0.1.1 → 0.2.0
--
-- Run with: ALTER EXTENSION pg_durable UPDATE TO '0.2.0';
--
-- Each schema-changing PR should add its DDL here.
-- See docs/upgrade-testing.md for the upgrade testing plan.

-- Changes:
--   - df.vars: Add per-user scoping via `owner` column + RLS
--     (Implements rls.md Decision 5, Option A)
--
-- Run with: ALTER EXTENSION pg_durable UPDATE TO '0.2.0';

-- ============================================================================
-- 1. Migrate df.vars schema: add owner column, change PK
-- ============================================================================

-- Add the owner column with a default. Existing rows get the current user
-- (the superuser running ALTER EXTENSION). Since vars are ephemeral
-- (set before df.start(), captured at start time), stale rows in this table
-- are unlikely to matter. If they do, admins should reassign ownership
-- manually before upgrading.
ALTER TABLE df.vars ADD COLUMN owner REGROLE NOT NULL DEFAULT current_user::regrole;

-- Change PK from (name) to (owner, name)
ALTER TABLE df.vars DROP CONSTRAINT vars_pkey;
ALTER TABLE df.vars ADD PRIMARY KEY (owner, name);

-- Keep direct INSERT on df.instances/df.nodes, but limit it to the columns
-- df.start() writes. Runtime-owned columns remain protected from direct INSERT.
REVOKE INSERT ON df.instances FROM PUBLIC;
REVOKE INSERT ON df.nodes FROM PUBLIC;
GRANT INSERT (id, label, root_node, submitted_by, login_role, database) ON df.instances TO PUBLIC;
GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, database) ON df.nodes TO PUBLIC;

-- Enforce a df.start-shaped graph for new direct writes without blocking
-- upgrades on legacy malformed rows that may already exist.
ALTER TABLE df.instances
    ADD CONSTRAINT instances_id_format_chk
        CHECK (id ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT instances_root_node_format_chk
        CHECK (root_node ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT instances_status_chk
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')) NOT VALID,
    -- Supports the composite FK from df.nodes that ties node identity to the instance row.
    ADD CONSTRAINT instances_identity_key
        UNIQUE (id, submitted_by, login_role);

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_instance_id_present_chk
        CHECK (instance_id IS NOT NULL) NOT VALID,
    ADD CONSTRAINT nodes_submitted_by_present_chk
        CHECK (submitted_by IS NOT NULL) NOT VALID,
    ADD CONSTRAINT nodes_login_role_present_chk
        CHECK (login_role IS NOT NULL) NOT VALID,
    ADD CONSTRAINT nodes_id_format_chk
        CHECK (id ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_instance_id_format_chk
        CHECK (instance_id ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_left_node_format_chk
        CHECK (left_node IS NULL OR left_node ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_right_node_format_chk
        CHECK (right_node IS NULL OR right_node ~ '^[0-9a-f]{8}$') NOT VALID,
    ADD CONSTRAINT nodes_node_type_chk
        CHECK (node_type IN ('SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'SIGNAL')) NOT VALID,
    ADD CONSTRAINT nodes_result_name_chk
        CHECK (result_name IS NULL OR result_name ~ '^[A-Za-z_][A-Za-z0-9_]*$') NOT VALID,
    ADD CONSTRAINT nodes_status_chk
        CHECK (status IN ('pending', 'running', 'completed', 'failed')) NOT VALID,
    ADD CONSTRAINT nodes_result_status_chk
        CHECK (result IS NULL OR status IN ('completed', 'failed')) NOT VALID,
    ADD CONSTRAINT nodes_structure_chk
        CHECK (
            CASE
                WHEN node_type IN ('SQL', 'SLEEP', 'WAIT_SCHEDULE', 'BREAK', 'HTTP', 'SIGNAL')
                    THEN left_node IS NULL AND right_node IS NULL AND query IS NOT NULL
                WHEN node_type = 'THEN'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
                WHEN node_type = 'IF'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NOT NULL
                WHEN node_type = 'LOOP'
                    THEN left_node IS NOT NULL AND right_node IS NULL
                WHEN node_type = 'JOIN'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL
                WHEN node_type = 'RACE'
                    THEN left_node IS NOT NULL AND right_node IS NOT NULL AND query IS NULL
                ELSE FALSE
            END
        ) NOT VALID,
    ADD CONSTRAINT nodes_instance_node_key
        UNIQUE (instance_id, id);

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_instance_identity_fkey
        FOREIGN KEY (instance_id, submitted_by, login_role)
        REFERENCES df.instances (id, submitted_by, login_role)
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

-- ============================================================================
-- 2. Enable RLS on df.vars
-- ============================================================================

ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;

CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner = current_user::regrole)
    WITH CHECK (owner = current_user::regrole);

DROP POLICY instances_user_isolation ON df.instances;
CREATE POLICY instances_user_isolation ON df.instances
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (
        submitted_by = current_user::regrole
        AND login_role = session_user::regrole
    );

DROP POLICY nodes_user_isolation ON df.nodes;
CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (submitted_by = current_user::regrole)
    WITH CHECK (
        submitted_by = current_user::regrole
        AND login_role = session_user::regrole
    );

-- ============================================================================
-- 3. Harden PL/pgSQL and SQL helper functions with SET search_path
--    (Defense-in-depth: all calls are already schema-qualified, but this
--    prevents future edits from accidentally introducing unqualified refs.)
-- ============================================================================

CREATE OR REPLACE FUNCTION df.as_op(fut text, name text) RETURNS text AS $$
    SELECT df.as(fut, name);
$$ LANGUAGE SQL IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OR REPLACE FUNCTION df.if_then_op(condition text, then_branch text) RETURNS text AS $$
DECLARE
    cond_fut jsonb;
    then_fut jsonb;
    result_obj jsonb;
BEGIN
    cond_fut := df.ensure_durofut(condition)::jsonb;
    then_fut := df.ensure_durofut(then_branch)::jsonb;
    result_obj := jsonb_build_object(
        '_partial_if', true,
        'condition', cond_fut,
        'then_branch', then_fut
    );
    RETURN result_obj::text;
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OR REPLACE FUNCTION df.if_else_op(partial_if text, else_branch text) RETURNS text AS $$
DECLARE
    partial jsonb;
    else_fut text;
    cond_text text;
    then_text text;
BEGIN
    partial := partial_if::jsonb;
    IF partial->>'_partial_if' IS NULL THEN
        RAISE EXCEPTION 'Invalid if-then-else: left side of !> must be a ?> expression';
    END IF;
    cond_text := partial->'condition'::text;
    then_text := partial->'then_branch'::text;
    else_fut := df.ensure_durofut(else_branch);
    RETURN df.if(cond_text, then_text, else_fut);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OR REPLACE FUNCTION df.ensure_durofut(val text) RETURNS text AS $$
DECLARE
    node_type_val text;
BEGIN
    BEGIN
        node_type_val := (val::jsonb)->>'node_type';
        IF node_type_val IS NOT NULL THEN
            IF node_type_val NOT IN ('SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'SIGNAL') THEN
                RAISE EXCEPTION 'Unknown node_type ''%''. Valid types: SQL, THEN, IF, JOIN, LOOP, BREAK, RACE, SLEEP, WAIT_SCHEDULE, HTTP, SIGNAL', node_type_val;
            END IF;
            RETURN val;
        END IF;
    EXCEPTION WHEN invalid_text_representation THEN
        NULL;
    WHEN raise_exception THEN
        RAISE;
    WHEN OTHERS THEN
        NULL;
    END;
    RETURN df.sql(val);
END;
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

CREATE OR REPLACE FUNCTION df.loop_prefix_op(body text) RETURNS text AS $$
    SELECT df.loop(body);
$$ LANGUAGE SQL IMMUTABLE SET search_path = pg_catalog, df, pg_temp;

-- ============================================================================
-- 4. Add df.if_rows() — branches on whether a named result has rows
-- ============================================================================

CREATE FUNCTION df."if_rows"(
    "result_name" TEXT,
    "then_branch" TEXT,
    "else_branch" TEXT
) RETURNS TEXT
STRICT
LANGUAGE c
AS 'MODULE_PATHNAME', 'if_rows_fn_wrapper';
