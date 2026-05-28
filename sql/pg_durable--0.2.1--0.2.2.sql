-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.1 → 0.2.2
--
-- Fix: RLS policies and the `df.vars.owner` default cast `current_user::regrole`
-- directly, which reparses the role name as an unquoted SQL identifier and
-- case-folds it. For a role like "labUser" the lookup becomes `labuser`,
-- triggering `ERROR: role "labuser" does not exist` on INSERT into df.nodes
-- / df.instances / df.vars (and similar for variable reads).
--
-- The fix runs the name through quote_ident() first so regrole_in() sees a
-- properly quoted identifier and resolves the role without case folding.
-- See issue #161 / PR #162.

-- ----------------------------------------------------------------------------
-- df.instances policy
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS instances_user_isolation ON df.instances;
CREATE POLICY instances_user_isolation ON df.instances
    FOR ALL
    USING (submitted_by = quote_ident(current_user)::regrole)
    WITH CHECK (submitted_by = quote_ident(current_user)::regrole);

-- ----------------------------------------------------------------------------
-- df.nodes policy
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS nodes_user_isolation ON df.nodes;
CREATE POLICY nodes_user_isolation ON df.nodes
    FOR ALL
    USING (submitted_by = quote_ident(current_user)::regrole)
    WITH CHECK (submitted_by = quote_ident(current_user)::regrole);

-- ----------------------------------------------------------------------------
-- df.vars policy + default
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS vars_user_isolation ON df.vars;
CREATE POLICY vars_user_isolation ON df.vars
    FOR ALL
    USING (owner = quote_ident(current_user)::regrole)
    WITH CHECK (owner = quote_ident(current_user)::regrole);

ALTER TABLE df.vars
    ALTER COLUMN owner SET DEFAULT quote_ident(current_user)::regrole;
