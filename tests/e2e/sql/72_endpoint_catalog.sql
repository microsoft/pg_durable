RESET SESSION AUTHORIZATION;
DROP SERVER IF EXISTS ec_server CASCADE;
DROP ROLE IF EXISTS ec_owner, ec_caller;
CREATE ROLE ec_owner LOGIN;
CREATE ROLE ec_caller LOGIN;
SELECT df.grant_usage('ec_owner', include_http => true, with_grant => true);
SELECT df.grant_usage('ec_caller', include_http => true);

DO $$
BEGIN
    IF pg_catalog.has_foreign_data_wrapper_privilege('ec_owner', 'pg_durable_fdw', 'USAGE') THEN
        RAISE EXCEPTION 'TEST FAILED: endpoint creation was granted implicitly';
    END IF;
END $$;

GRANT USAGE ON FOREIGN DATA WRAPPER pg_durable_fdw TO ec_owner;
SET SESSION AUTHORIZATION ec_owner;
CREATE SERVER ec_server FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://api.github.com', auth_scheme 'none');
ALTER SERVER ec_server OPTIONS (SET auth_scheme 'header', ADD header_name 'x-api-key');
GRANT USAGE ON FOREIGN SERVER ec_server TO ec_caller;

DO $$
DECLARE
    rejected BOOLEAN := false;
BEGIN
    BEGIN
        ALTER SERVER ec_server OPTIONS (DROP header_name);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%header_name%required%' THEN RAISE; END IF;
        rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'TEST FAILED: invalid merged options accepted'; END IF;

    rejected := false;
    BEGIN
        ALTER SERVER ec_server OPTIONS (SET auth_scheme 'managed-identity', DROP header_name);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%not supported in this version%' THEN RAISE; END IF;
        rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'TEST FAILED: managed identity enabled without controls'; END IF;

    rejected := false;
    BEGIN
        ALTER SERVER ec_server OPTIONS (ADD resource 'https://vault.azure.net');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%Unsupported endpoint server option%' THEN RAISE; END IF;
        rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'TEST FAILED: unknown server option accepted'; END IF;
END $$;

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION ec_caller;
CREATE USER MAPPING FOR CURRENT_USER SERVER ec_server OPTIONS (header_value 'CATALOG_SENTINEL');
ALTER USER MAPPING FOR CURRENT_USER SERVER ec_server OPTIONS (SET header_value 'ROTATED_SENTINEL');

DO $$
DECLARE
    rejected BOOLEAN := false;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_user_mappings
        WHERE srvname = 'ec_server' AND usename = CURRENT_USER
          AND umoptions = ARRAY['header_value=ROTATED_SENTINEL']
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: caller cannot read its rotated mapping';
    END IF;
    BEGIN
        ALTER USER MAPPING FOR CURRENT_USER SERVER ec_server OPTIONS (SET header_value E'SHOULD_NOT_LEAK\r\n');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%SHOULD_NOT_LEAK%' OR SQLERRM NOT LIKE '%Invalid endpoint credential header value%' THEN RAISE; END IF;
        rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'TEST FAILED: invalid header credential accepted'; END IF;
END $$;

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION ec_owner;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_user_mappings
        WHERE srvname = 'ec_server' AND usename = 'ec_caller' AND umoptions IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: server owner can read another role mapping';
    END IF;
END $$;

REVOKE USAGE ON FOREIGN SERVER ec_server FROM ec_caller;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION ec_caller;
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_user_mappings
        WHERE srvname = 'ec_server' AND usename = CURRENT_USER AND umoptions IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: revoked caller still sees credential options';
    END IF;
END $$;

RESET SESSION AUTHORIZATION;
DROP SERVER ec_server CASCADE;
DROP OWNED BY ec_owner, ec_caller;
DROP ROLE ec_owner, ec_caller;
SELECT 'TEST PASSED' AS result;