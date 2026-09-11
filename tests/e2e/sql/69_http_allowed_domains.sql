-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Issue #375: the "http-custom-domains" phase restarts PostgreSQL with
-- pg_durable.http_allowed_domains = 'example.com' and http-allow-test-domains.
-- The local runner first checks rejection of a malformed postgresql.conf value,
-- restores the configuration, and starts PostgreSQL with this valid allowlist.
-- Allowed requests must reach HTTP transport; example.com need not provide a
-- working POST endpoint. All other requests must fail before DNS or networking.

SET SESSION AUTHORIZATION df_e2e_user;

DO $$
BEGIN
    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM 'example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: custom allowlist is not visible to an ordinary user';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_settings
        WHERE name = 'pg_durable.http_allowed_domains'
          AND setting = 'example.com'
          AND context = 'postmaster'
          AND vartype = 'string'
          AND source = 'configuration file'
          AND NOT pending_restart
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: expected a readable string GUC applied at server startup';
    END IF;
END $$;

RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    statement TEXT;
BEGIN
    FOREACH statement IN ARRAY ARRAY[
        'SET pg_durable.http_allowed_domains = ''api.github.com''',
        'SET LOCAL pg_durable.http_allowed_domains = ''api.github.com''',
        'ALTER ROLE df_e2e_user SET pg_durable.http_allowed_domains = ''api.github.com''',
        format('ALTER DATABASE %I SET pg_durable.http_allowed_domains = ''api.github.com''',
               current_database()),
        format('ALTER ROLE df_e2e_user IN DATABASE %I SET pg_durable.http_allowed_domains = ''api.github.com''',
               current_database())
    ] LOOP
        BEGIN
            EXECUTE statement;
            RAISE EXCEPTION 'TEST FAILED: accepted a runtime override of a postmaster GUC: %', statement;
        EXCEPTION WHEN cant_change_runtime_param THEN
            NULL;
        END;
    END LOOP;

    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM 'example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: runtime overrides changed the allowlist';
    END IF;
END $$;

-- ALTER SYSTEM must run outside a transaction block. Save its diagnostics
-- before issuing another query, and clean up even if it unexpectedly succeeds.
\set ON_ERROR_STOP off
ALTER SYSTEM SET pg_durable.http_allowed_domains = 'example.com,https://api.github.com';
\set invalid_domains_sqlstate :SQLSTATE
\set invalid_domains_message :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP on

CREATE TEMP TABLE _test_invalid_domains AS
SELECT :'invalid_domains_sqlstate'::text AS sqlstate,
       :'invalid_domains_message'::text AS message,
       EXISTS (
           SELECT 1 FROM pg_file_settings
           WHERE name = 'pg_durable.http_allowed_domains'
             AND sourcefile LIKE '%/postgresql.auto.conf'
       ) AS override_written;

ALTER SYSTEM RESET pg_durable.http_allowed_domains;

DO $$
DECLARE
    rejected RECORD;
BEGIN
    SELECT * INTO STRICT rejected FROM _test_invalid_domains;

    IF rejected.sqlstate IS DISTINCT FROM '22023'
       OR rejected.message IS NULL
       OR position('invalid value for parameter "pg_durable.http_allowed_domains"' IN rejected.message) = 0
       OR rejected.override_written THEN
        RAISE EXCEPTION 'TEST FAILED: invalid ALTER SYSTEM value was not rejected atomically: %', rejected;
    END IF;

    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM 'example.com' THEN
        RAISE EXCEPTION 'TEST FAILED: invalid ALTER SYSTEM value changed the running allowlist';
    END IF;
END $$;

DROP TABLE _test_invalid_domains;

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_http_allowed_domains (
    instance_id TEXT,
    hostname TEXT,
    node_type TEXT,
    allowed BOOLEAN
);

INSERT INTO _test_http_allowed_domains
SELECT df.start(
    CASE node_type
        WHEN 'HTTP' THEN df.http('https://' || hostname || '/', 'GET', NULL, NULL, 10)
        ELSE df.http_multipart(
            'https://' || hostname || '/', 'POST',
            '[{"name":"field","data_b64":"dmFsdWU="}]'::jsonb, NULL, 10
        )
    END,
    'custom-domains-' || node_type || '-' || hostname
), hostname, node_type, allowed
FROM (VALUES
    ('example.com', true),
    ('pg-durable-test-nonexistent.blob.core.windows.net', false),
    ('api.github.com', false),
    ('httpbingo.org', false)
) AS endpoints(hostname, allowed)
CROSS JOIN (VALUES ('HTTP'), ('HTTP_MULTIPART')) AS node_types(node_type);

DO $$
DECLARE
    test_case RECORD;
    status TEXT;
    node_result TEXT;
    http_status INT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_allowed_domains ORDER BY hostname, node_type LOOP
        SELECT df.await_instance(test_case.instance_id, 30) INTO status;
        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type = test_case.node_type;

        IF test_case.allowed THEN
            IF status IS NULL OR status NOT IN ('completed', 'failed') OR node_result IS NULL THEN
                RAISE EXCEPTION 'TEST FAILED: allowed % request to %: status = %, result = %',
                    test_case.node_type, test_case.hostname, status, node_result;
            END IF;

            IF status = 'completed' THEN
                http_status := (node_result::jsonb->>'status')::int;
                IF http_status IS NULL OR http_status NOT BETWEEN 100 AND 599 THEN
                    RAISE EXCEPTION 'TEST FAILED: expected an HTTP response for %: %',
                        test_case.node_type, node_result;
                END IF;
            -- Only errors from after the policy checks prove admission.
            ELSIF NOT (node_result LIKE ANY (ARRAY[
                '%HTTP connection failed%',
                '%HTTP request failed%',
                '%HTTP timeout after%',
                '% returned 5__:%'
            ])) THEN
                RAISE EXCEPTION 'TEST FAILED: allowed request did not reach HTTP transport for %: %',
                    test_case.node_type, node_result;
            END IF;
        ELSE
            IF status IS DISTINCT FROM 'failed'
               OR node_result IS NULL
               OR node_result NOT LIKE '%is not in the allowed endpoint list%'
               OR position('pg_durable.http_allowed_domains' IN node_result) = 0 THEN
                RAISE EXCEPTION 'TEST FAILED: built-in endpoint % was not denied for %: status = %, result = %',
                    test_case.hostname, test_case.node_type, status, node_result;
            END IF;
        END IF;
    END LOOP;
END $$;

DROP TABLE _test_http_allowed_domains;
RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
