-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.2 → 0.2.3
--
-- 1. Introduces df.duroxide_schema(), a helper that reports which schema holds
--    the duroxide provider objects for this install. Fresh 0.2.3 installs create
--    the provider objects in the '_duroxide' schema (see lib.rs). Installs
--    upgrading from <= 0.2.2 already have their provider objects in the legacy
--    'duroxide' schema and must keep using it — renaming an in-use schema would
--    orphan the background worker's durable state. This upgrade therefore defines
--    df.duroxide_schema() to return 'duroxide' for pre-existing installs.
--
--    Backend sessions and the background worker call df.duroxide_schema() to learn
--    which schema to use, falling back to 'duroxide' when the helper is absent
--    (installs predating it). No schema rename, drop, or data movement occurs.
--
-- 2. Moves the seven DSL operators from public into df (issue #202). See the
--    operator block below for the rationale and the search_path implication.
--
-- 3. Redefines df.grant_usage() / df.revoke_usage() to manage the role's
--    search_path. Because the operators move into df (item 2), df must be on a
--    role's search_path for the unqualified operator syntax to resolve.
--    df.grant_usage() gains a set_search_path argument (default true) that adds
--    df to the role's search_path during onboarding, and df.revoke_usage()
--    removes it again — so existing installs get the ergonomic syntax without
--    every user editing search_path by hand. grant_usage's signature changes
--    (a fourth argument is appended), so it is dropped and recreated; any
--    EXECUTE grants on the old signature are reissued the next time an admin
--    calls df.grant_usage(..., with_grant => true).

CREATE FUNCTION df.duroxide_schema() RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path = pg_catalog, pg_temp
    AS $$ SELECT 'duroxide'::text $$;

-- ---------------------------------------------------------------------------
-- Move the DSL operators from the public schema into df (issue #202).
--
-- pg_durable <= 0.2.2 created its seven DSL operators in the public schema,
-- polluting the public namespace (and flagged by pgspot). Fresh 0.2.3 installs
-- create them in df (see src/lib.rs); this block relocates them for installs
-- upgrading from <= 0.2.2.
--
-- The helper functions the operators bind to (df.as_op, df.if_then_op,
-- df.if_else_op, df.loop_prefix_op) already live in df from earlier versions,
-- so only the operators themselves move.
--
-- Behavior change: because an expression like `'a' ~> 'b'` is resolved in the
-- caller's session before df.start()/df.explain() see it, the unqualified
-- operator syntax now requires `df` on the session search_path (for example,
-- `SET search_path = "$user", public, df;`). The schema-qualified df.*()
-- functions (df.seq, df.as, df.join, df.race, df.if, df.loop) are unaffected.
-- ---------------------------------------------------------------------------
DROP OPERATOR IF EXISTS public.~> (text, text);
DROP OPERATOR IF EXISTS public.|=> (text, text);
DROP OPERATOR IF EXISTS public.& (text, text);
DROP OPERATOR IF EXISTS public.| (text, text);
DROP OPERATOR IF EXISTS public.?> (text, text);
DROP OPERATOR IF EXISTS public.!> (text, text);
DROP OPERATOR IF EXISTS public.@> (none, text);

-- Sequencing: a ~> b means "run a, then run b"
CREATE OPERATOR df.~> (
    FUNCTION = df.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Naming: fut |=> 'name' means "name this result as $name"
CREATE OPERATOR df.|=> (
    FUNCTION = df.as_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Parallel join: a & b means "run a and b in parallel, wait for both"
CREATE OPERATOR df.& (
    FUNCTION = df.join,
    LEFTARG = text,
    RIGHTARG = text
);

-- Race: a | b means "run a and b in parallel, first wins"
CREATE OPERATOR df.| (
    FUNCTION = df.race,
    LEFTARG = text,
    RIGHTARG = text
);

-- If-then / if-else: cond ?> then_branch !> else_branch
CREATE OPERATOR df.?> (
    FUNCTION = df.if_then_op,
    LEFTARG = text,
    RIGHTARG = text
);

CREATE OPERATOR df.!> (
    FUNCTION = df.if_else_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Loop (prefix): @> body means "repeat body forever"
CREATE OPERATOR df.@> (
    FUNCTION = df.loop_prefix_op,
    RIGHTARG = text
);

-- ---------------------------------------------------------------------------
-- Redefine df.grant_usage() / df.revoke_usage() to manage search_path
-- (issue #202 follow-up).
--
-- Now that the DSL operators live in df (above), df must be on a role's
-- search_path for the unqualified operator syntax to resolve.  df.grant_usage()
-- gains a set_search_path argument (default true) that adds df to the role's
-- search_path during onboarding, and df.revoke_usage() removes it again — so
-- existing installs get the ergonomic syntax without every user editing
-- search_path by hand.
--
-- These definitions are kept in sync with src/lib.rs (the upgrade test compares
-- function signatures and non-PUBLIC ACLs, not bodies).  grant_usage gains a
-- fourth argument, so it must be dropped and recreated: DROP also discards the
-- old function's EXECUTE grants (including any delegated-admin WITH GRANT OPTION
-- grants), so the REVOKE below re-secures the recreated function against PUBLIC
-- and superusers re-grant delegated admins by calling df.grant_usage(...,
-- with_grant => true) again.  df.revoke_usage() keeps its signature, so
-- CREATE OR REPLACE preserves its existing ACL.
--
-- The CREATE SCHEMA IF NOT EXISTS below is a runtime no-op (df already exists,
-- created by the original install) — it is present so the pgspot security gate
-- recognises df as a created schema and treats the functions' "SET search_path =
-- pg_catalog, df, pg_temp" as secure, exactly as it does for the generated
-- fresh-install SQL (pgrx emits CREATE SCHEMA IF NOT EXISTS df there). This lets
-- the function bodies stay byte-identical to their src/lib.rs definitions instead
-- of being hand-qualified only here. The resulting PS010 finding is allowlisted
-- in scripts/run-pgspot.sh.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS df;

DROP FUNCTION IF EXISTS df.grant_usage(text, boolean, boolean);

CREATE OR REPLACE FUNCTION df.grant_usage(
    p_role TEXT,
    include_http boolean DEFAULT false,
    with_grant boolean DEFAULT false,
    set_search_path boolean DEFAULT true
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
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean, boolean) TO %I', p_role) || grant_opt;
        EXECUTE format('GRANT EXECUTE ON FUNCTION df.revoke_usage(text) TO %I', p_role) || grant_opt;
    END IF;

    -- Table privileges
    EXECUTE format('GRANT SELECT ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT UPDATE (status, updated_at) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, label, root_node, submitted_by, database) ON df.instances TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes TO %I', p_role) || grant_opt;
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO %I', p_role) || grant_opt;

    -- Ensure df is on the role's search_path so the unqualified DSL operators
    -- (which live in df and are resolved in the caller's session) work without
    -- each user setting search_path by hand.  Opt out with
    -- set_search_path => false.  Append-only and idempotent: df is added at the
    -- end (lowest precedence) and only when not already present.
    IF set_search_path THEN
        DECLARE
            v_path text;
        BEGIN
            SELECT substring(opt FROM 13)  -- strip leading 'search_path='
            INTO v_path
            FROM pg_db_role_setting s
            JOIN pg_roles r ON r.oid = s.setrole
            CROSS JOIN LATERAL unnest(s.setconfig) AS o(opt)
            WHERE r.rolname = p_role
              AND s.setdatabase = 0
              AND opt LIKE 'search_path=%'
            LIMIT 1;

            IF v_path IS NULL THEN
                -- No per-role search_path yet: set the standard default plus df.
                EXECUTE format('ALTER ROLE %I SET search_path = %s', p_role, '"$user", public, df');
                RAISE NOTICE 'pg_durable: set search_path for "%" to "$user", public, df', p_role;
            ELSIF NOT EXISTS (
                SELECT 1 FROM unnest(string_to_array(v_path, ',')) AS t(tok)
                WHERE lower(btrim(tok, ' "')) = 'df'
            ) THEN
                EXECUTE format('ALTER ROLE %I SET search_path = %s', p_role, v_path || ', df');
                RAISE NOTICE 'pg_durable: added df to search_path for "%"', p_role;
            END IF;
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'pg_durable: could not set search_path for "%" (insufficient privilege); add df to search_path manually', p_role;
        END;
    END IF;

    RAISE NOTICE 'pg_durable: granted df usage privileges to "%"', p_role;
END;
$fn$;

-- df.grant_usage() is an admin-only helper: revoke PUBLIC's default EXECUTE on
-- the recreated function (DROP above also dropped the prior REVOKE entry).
REVOKE EXECUTE ON FUNCTION df.grant_usage(text, boolean, boolean, boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION df.revoke_usage(p_role TEXT)
RETURNS VOID
LANGUAGE plpgsql
SET search_path = pg_catalog, df, pg_temp
AS $fn$
DECLARE
    func_oid oid;
BEGIN
    -- Validate the role exists
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'role "%" does not exist', p_role;
    END IF;

    -- Prevent accidentally revoking your own access.  pg_has_role checks
    -- both direct identity (current_user = p_role) and inherited membership
    -- (current_user is a member of p_role), so revoking a parent role that
    -- the caller depends on is also caught.
    -- Superusers are exempt: pg_has_role returns true for all roles when the
    -- caller is a superuser, and superusers can always re-grant themselves.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = current_user
          AND rolsuper
    )
       AND pg_has_role(current_user, p_role, 'MEMBER') THEN
        RAISE EXCEPTION 'cannot revoke df privileges from "%" because the current role ("%") is a member of it — use a different administrator', p_role, current_user;
    END IF;

    -- CASCADE: if the target role granted sub-grants (via WITH GRANT OPTION),
    -- CASCADE ensures those dependent privileges are also revoked.
    -- Column-level revokes must match the column-level grants from grant_usage().
    EXECUTE format('REVOKE SELECT, INSERT, UPDATE, DELETE ON df.vars FROM %I CASCADE', p_role);
    EXECUTE format('REVOKE INSERT (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) ON df.nodes FROM %I CASCADE', p_role);
    EXECUTE format('REVOKE SELECT ON df.nodes FROM %I CASCADE', p_role);
    EXECUTE format('REVOKE INSERT (id, label, root_node, submitted_by, database) ON df.instances FROM %I CASCADE', p_role);
    EXECUTE format('REVOKE UPDATE (status, updated_at) ON df.instances FROM %I CASCADE', p_role);
    EXECUTE format('REVOKE SELECT ON df.instances FROM %I CASCADE', p_role);

    -- Revoke EXECUTE per-function rather than using the blanket
    -- REVOKE ON ALL FUNCTIONS.  A delegated admin may lack privilege on
    -- some functions (e.g. df.http); per-function revokes let us skip those.
    FOR func_oid IN
        SELECT p.oid FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'df'
    LOOP
        BEGIN
            EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM %I CASCADE', func_oid::regprocedure, p_role);
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
    END LOOP;

    EXECUTE format('REVOKE USAGE ON SCHEMA df FROM %I CASCADE', p_role);

    -- Mirror df.grant_usage()'s search_path setup: remove the df entry this
    -- extension manages from the role's search_path.  Idempotent (a no-op when
    -- df is absent) and gracefully skipped if the caller lacks privilege to
    -- ALTER the role.
    DECLARE
        v_path text;
        v_newpath text;
    BEGIN
        SELECT substring(opt FROM 13)  -- strip leading 'search_path='
        INTO v_path
        FROM pg_db_role_setting s
        JOIN pg_roles r ON r.oid = s.setrole
        CROSS JOIN LATERAL unnest(s.setconfig) AS o(opt)
        WHERE r.rolname = p_role
          AND s.setdatabase = 0
          AND opt LIKE 'search_path=%'
        LIMIT 1;

        IF v_path IS NOT NULL AND EXISTS (
            SELECT 1 FROM unnest(string_to_array(v_path, ',')) AS t(tok)
            WHERE lower(btrim(tok, ' "')) = 'df'
        ) THEN
            SELECT string_agg(btrim(tok), ', ')
            INTO v_newpath
            FROM unnest(string_to_array(v_path, ',')) AS t(tok)
            WHERE lower(btrim(tok, ' "')) <> 'df';

            IF v_newpath IS NULL OR btrim(v_newpath) = '' THEN
                EXECUTE format('ALTER ROLE %I RESET search_path', p_role);
            ELSE
                EXECUTE format('ALTER ROLE %I SET search_path = %s', p_role, v_newpath);
            END IF;
            RAISE NOTICE 'pg_durable: removed df from search_path for "%"', p_role;
        END IF;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'pg_durable: could not adjust search_path for "%" (insufficient privilege)', p_role;
    END;

    RAISE NOTICE 'pg_durable: revoked df usage privileges granted by "%" from "%"', current_user, p_role;
END;
$fn$;
