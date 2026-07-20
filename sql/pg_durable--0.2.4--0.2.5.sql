-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.4 → 0.2.5
--
-- Adds df.http_multipart() for multipart/form-data requests (file uploads,
-- form posts). It builds an HTTP_MULTIPART node whose payload is a JSON array
-- of parts (name / filename / content_type / data_b64); the execute_multipart
-- activity base64-decodes each part and posts a reqwest::multipart::Form. The
-- existing df.http() path is unchanged.
--
-- Security: df.http_multipart() is gated identically to df.http() — PUBLIC
-- EXECUTE is revoked at upgrade time, and df.grant_usage() grants it only when
-- include_http => true (HTTP egress is one privilege). The execute_multipart
-- activity runs the same 4-layer gate as execute_http (privilege, scheme,
-- allow-list, SSRF-safe DNS resolver, no redirects).
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).

-- ============================================================================
-- Register the new df.http_multipart() C function.
--
-- pgrx emits this for fresh installs from the #[pg_extern] in src/dsl.rs; the
-- upgrade script must create it explicitly so pre-existing installs gain the
-- function on ALTER EXTENSION UPDATE. The C symbol http_multipart_wrapper is
-- compiled into the new .so (matching the dsl::http_multipart Rust function).
-- ============================================================================
CREATE FUNCTION df."http_multipart"(
    "url" TEXT,
    "method" TEXT DEFAULT 'POST',
    "parts" jsonb DEFAULT NULL,
    "headers" jsonb DEFAULT NULL,
    "timeout_seconds" INT DEFAULT 30
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'http_multipart_wrapper';

-- ============================================================================
-- Admit the HTTP_MULTIPART node type into the schema constraints and the
-- df.ensure_durofut() validator. These mirror VALID_NODE_TYPES in src/types.rs
-- (the Rust constant is the canonical source). The constraints are NOT VALID,
-- so re-adding them does not rewrite existing rows.
-- ============================================================================
ALTER TABLE df.nodes DROP CONSTRAINT nodes_node_type_chk;
ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_node_type_chk
    CHECK (node_type OPERATOR(pg_catalog.=) ANY (ARRAY['SQL', 'THEN', 'IF', 'JOIN', 'LOOP', 'BREAK', 'RACE', 'SLEEP', 'WAIT_SCHEDULE', 'HTTP', 'HTTP_MULTIPART', 'SIGNAL'])) NOT VALID;

ALTER TABLE df.nodes DROP CONSTRAINT nodes_structure_chk;
ALTER TABLE df.nodes
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
    ) NOT VALID;

-- Helper to ensure a value is a durofut (returns JSON string)
-- Rejects JSON with unknown node_type values.
-- NOTE: The valid node type list here must be kept in sync with
-- VALID_NODE_TYPES in src/types.rs (the Rust constant is the canonical source).
-- search_path omits df on purpose: the body only touches pg_catalog builtins
-- (jsonb, ->>, <>) and the schema-qualified df.sql(), so df is not needed.
-- Including df here makes pgspot deem the path insecure (an upgrade script has
-- no CREATE SCHEMA df, so df is not provably extension-owned), which re-enables
-- CVE-2018-1058-style search_path hijack warnings (PS005/PS001/PS017). The
-- fresh-install DDL in src/lib.rs matches for upgrade parity (Scenario A).
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
$$ LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp;

-- ============================================================================
-- Grant/revoke plumbing for df.http_multipart().
--
-- grant_usage() / revoke_usage() are re-emitted in full so upgraded installs
-- match fresh 0.2.5 installs (see src/lib.rs). The signature is unchanged
-- (df.grant_usage(text, boolean, boolean)); http_multipart rides on the
-- existing include_http flag.
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

-- df.http_multipart() is sensitive (network access), so revoke PostgreSQL's
-- default PUBLIC EXECUTE — same treatment as df.http(). df.grant_usage()
-- re-grants it explicitly to authorized roles (include_http => true).
REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) FROM PUBLIC;
