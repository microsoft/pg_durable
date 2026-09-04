-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.7 -> 0.2.8
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
-- Adds a trailing `options jsonb DEFAULT NULL` parameter to df.http() and
-- df.http_multipart(). No option key is supported in this version (NULL and an
-- empty object are the only accepted values); the parameter exists so future
-- modifiers never have to change the signature again. A function's argument
-- list is its privilege identity, so every future signature change would
-- otherwise orphan existing EXECUTE grants.
--
-- An argument list cannot be altered in place, so each function is dropped and
-- recreated. Dropping a function drops its grants, so this script copies the
-- EXECUTE ACL of each old function onto its replacement before the drop,
-- preserving WITH GRANT OPTION. The grantor of the re-applied grants becomes
-- the role running ALTER EXTENSION (the original grantor cannot be restored
-- through a GRANT statement).

-- ============================================================================
-- 1. Create the new signatures alongside the old ones.
--
-- These match the SQL pgrx generates for the #[pg_extern] functions in
-- src/dsl.rs on a fresh install (cargo pgrx schema pg17), so the upgraded
-- schema matches a fresh 0.2.8 install (Scenario A).
-- ============================================================================
CREATE FUNCTION df."http"(
    "url" TEXT,
    "method" TEXT DEFAULT 'POST',
    "body" TEXT DEFAULT NULL,
    "headers" jsonb DEFAULT NULL,
    "timeout_seconds" INT DEFAULT 30,
    "options" jsonb DEFAULT NULL
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'http_wrapper';

CREATE FUNCTION df."http_multipart"(
    "url" TEXT,
    "method" TEXT DEFAULT 'POST',
    "parts" jsonb DEFAULT NULL,
    "headers" jsonb DEFAULT NULL,
    "timeout_seconds" INT DEFAULT 30,
    "options" jsonb DEFAULT NULL
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'http_multipart_wrapper';

-- ============================================================================
-- 2. Both functions are sensitive (outbound network access), so drop the
--    default PUBLIC EXECUTE that a freshly created function carries. Step 3
--    re-grants PUBLIC only when the function being replaced still had it (an
--    install upgraded from v0.1.1, where that grant is intentionally kept).
-- ============================================================================
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer, jsonb) FROM PUBLIC;

-- ============================================================================
-- 3. Copy the EXECUTE grants of the old signatures onto the new ones.
--
-- A NULL proacl means the catalog default is in effect (owner + PUBLIC), so it
-- is expanded with acldefault() rather than read as "no grants".
-- ============================================================================
DO $do$
DECLARE
    old_http pg_catalog.regprocedure;
    old_multipart pg_catalog.regprocedure;
    g record;
BEGIN
    old_http := pg_catalog.to_regprocedure('df.http(text,text,text,jsonb,integer)');
    old_multipart := pg_catalog.to_regprocedure('df.http_multipart(text,text,jsonb,jsonb,integer)');

    FOR g IN
        SELECT CASE
                   WHEN a.grantee OPERATOR(pg_catalog.=) 0::pg_catalog.oid THEN 'PUBLIC'
                   ELSE pg_catalog.quote_ident(r.rolname)
               END AS grantee,
               a.is_grantable AS is_grantable,
               CASE
                   WHEN p.oid OPERATOR(pg_catalog.=) old_http::pg_catalog.oid
                       THEN 'df.http(text, text, text, jsonb, integer, jsonb)'
                   ELSE 'df.http_multipart(text, text, jsonb, jsonb, integer, jsonb)'
               END AS target
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL pg_catalog.aclexplode(
            COALESCE(p.proacl, pg_catalog.acldefault('f', p.proowner))
        ) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid OPERATOR(pg_catalog.=) a.grantee
        WHERE p.oid OPERATOR(pg_catalog.=) ANY (
                  ARRAY[old_http::pg_catalog.oid, old_multipart::pg_catalog.oid]
              )
          AND a.privilege_type OPERATOR(pg_catalog.=) 'EXECUTE'
        ORDER BY 3, 1, 2
    LOOP
        EXECUTE pg_catalog.format(
            'GRANT EXECUTE ON FUNCTION %s TO %s%s',
            g.target,
            g.grantee,
            CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
        );
    END LOOP;
END
$do$;

-- ============================================================================
-- 4. Drop the pre-0.2.8 signatures.
-- ============================================================================
DROP FUNCTION IF EXISTS df.http(text, text, text, jsonb, integer);
DROP FUNCTION IF EXISTS df.http_multipart(text, text, jsonb, jsonb, integer);

-- ============================================================================
-- 5. Re-emit df.grant_usage() / df.revoke_usage() so they name the new
--    signatures. The bodies are otherwise identical to 0.2.7 and to the
--    fresh-install SQL in src/lib.rs.
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

    -- Schema access — the access gate for ordinary df.* functions.
    EXECUTE pg_catalog.format('GRANT USAGE ON SCHEMA df TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;

    -- df.http() — opt-in because it makes outbound network requests.
    IF include_http THEN
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer, jsonb) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        -- df.http_multipart() shares the same opt-in (HTTP egress is one privilege).
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer, jsonb) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
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
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer, jsonb) FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.metrics() FROM %I CASCADE', p_role);
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer, jsonb) FROM %I CASCADE', p_role);
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
