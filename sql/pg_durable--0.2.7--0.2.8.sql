-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- pg_durable upgrade: 0.2.7 -> 0.2.8
--
-- See docs/upgrade-testing.md for the upgrade-script and backward-compatibility
-- requirements (Scenario A / B1 / B2).
--
ALTER FUNCTION df."loop"(TEXT, TEXT) RENAME TO "_loop_legacy";

CREATE FUNCTION df."loop"(
    "body" TEXT,
    "condition" TEXT DEFAULT NULL,
    "continue_on_failure" bool DEFAULT false
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'loop_with_policy_wrapper';

-- HTTP options are additive; existing function ABIs, OIDs and ACLs stay unchanged.
CREATE FUNCTION df."with_http_options"(
    "fut" TEXT,
    "options" jsonb
) RETURNS TEXT
LANGUAGE c
AS 'MODULE_PATHNAME', 'with_http_options_wrapper';

CREATE FUNCTION df.endpoint_option_validator(
    "options" pg_catalog.text[],
    "catalog" pg_catalog.oid
) RETURNS pg_catalog.void
LANGUAGE c STRICT
AS 'MODULE_PATHNAME', 'endpoint_option_validator_wrapper';

CREATE FOREIGN DATA WRAPPER pg_durable_fdw
    NO HANDLER VALIDATOR df.endpoint_option_validator;
REVOKE ALL ON FOREIGN DATA WRAPPER pg_durable_fdw FROM PUBLIC;

CREATE TYPE df.http_endpoint AS (server pg_catalog.text, path pg_catalog.text);

CREATE FUNCTION df.endpoint("server" pg_catalog.text, "path" pg_catalog.text)
RETURNS df.http_endpoint
LANGUAGE c IMMUTABLE STRICT PARALLEL SAFE
AS 'MODULE_PATHNAME', 'endpoint_wrapper';

CREATE FUNCTION df.http(
    "url" df.http_endpoint,
    "method" pg_catalog.text DEFAULT 'POST',
    "body" pg_catalog.text DEFAULT NULL,
    "headers" pg_catalog.jsonb DEFAULT NULL,
    "timeout_seconds" pg_catalog.int4 DEFAULT 30
) RETURNS pg_catalog.text
LANGUAGE c
AS 'MODULE_PATHNAME', 'http_endpoint_wrapper';

CREATE FUNCTION df.http_multipart(
    "url" df.http_endpoint,
    "method" pg_catalog.text DEFAULT 'POST',
    "parts" pg_catalog.jsonb DEFAULT NULL,
    "headers" pg_catalog.jsonb DEFAULT NULL,
    "timeout_seconds" pg_catalog.int4 DEFAULT 30
) RETURNS pg_catalog.text
LANGUAGE c
AS 'MODULE_PATHNAME', 'http_multipart_endpoint_wrapper';

REVOKE EXECUTE ON FUNCTION df.http(df.http_endpoint, text, text, jsonb, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.http_multipart(df.http_endpoint, text, jsonb, jsonb, integer) FROM PUBLIC;

CREATE FUNCTION df.secret("server" pg_catalog.text, "key" pg_catalog.text)
RETURNS pg_catalog.jsonb
LANGUAGE c IMMUTABLE STRICT PARALLEL SAFE
AS 'MODULE_PATHNAME', 'secret_wrapper';

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
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http(df.http_endpoint, text, text, jsonb, integer) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        -- df.http_multipart() shares the same opt-in (HTTP egress is one privilege).
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
        EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION df.http_multipart(df.http_endpoint, text, jsonb, jsonb, integer) TO %I', p_role) OPERATOR(pg_catalog.||) grant_opt;
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
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http(df.http_endpoint, text, text, jsonb, integer) FROM %I CASCADE', p_role);
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
        EXECUTE pg_catalog.format('REVOKE EXECUTE ON FUNCTION df.http_multipart(df.http_endpoint, text, jsonb, jsonb, integer) FROM %I CASCADE', p_role);
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
