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
