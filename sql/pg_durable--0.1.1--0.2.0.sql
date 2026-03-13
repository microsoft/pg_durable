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

-- ============================================================================
-- 2. Enable RLS on df.vars
-- ============================================================================

ALTER TABLE df.vars ENABLE ROW LEVEL SECURITY;

CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner = current_user::regrole)
    WITH CHECK (owner = current_user::regrole);

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
