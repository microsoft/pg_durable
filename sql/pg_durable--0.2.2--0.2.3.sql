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
