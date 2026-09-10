-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Issue #375: the "http-empty-domains" phase restarts PostgreSQL with an
-- explicitly empty pg_durable.http_allowed_domains and http-allow-test-domains.
-- The previous phase's custom hostname and the built-in defaults must all be
-- denied, not restored as a fallback. No request needs a live endpoint.

SET SESSION AUTHORIZATION df_e2e_user;

DO $$
BEGIN
    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM '' THEN
        RAISE EXCEPTION 'TEST FAILED: expected an explicitly empty allowlist';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_settings
        WHERE name = 'pg_durable.http_allowed_domains'
          AND setting = ''
          AND context = 'postmaster'
          AND source = 'configuration file'
          AND NOT pending_restart
    ) THEN
        RAISE EXCEPTION 'TEST FAILED: empty allowlist was not applied at server startup';
    END IF;
END $$;

CREATE TEMP TABLE _test_http_empty_domains (
    instance_id TEXT,
    hostname TEXT,
    node_type TEXT
);

INSERT INTO _test_http_empty_domains
SELECT df.start(
    CASE node_type
        WHEN 'HTTP' THEN df.http('https://' || hostname || '/', 'GET', NULL, NULL, 5)
        ELSE df.http_multipart(
            'https://' || hostname || '/', 'POST',
            '[{"name":"field","data_b64":"dmFsdWU="}]'::jsonb, NULL, 5
        )
    END,
    'empty-domains-' || node_type || '-' || hostname
), hostname, node_type
FROM (VALUES
    ('example.com'),
    ('pg-durable-test-nonexistent.blob.core.windows.net'),
    ('api.github.com'),
    ('httpbingo.org')
) AS endpoints(hostname)
CROSS JOIN (VALUES ('HTTP'), ('HTTP_MULTIPART')) AS node_types(node_type);

DO $$
DECLARE
    test_case RECORD;
    status TEXT;
    node_result TEXT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_empty_domains ORDER BY hostname, node_type LOOP
        SELECT df.await_instance(test_case.instance_id, 30) INTO status;
        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type = test_case.node_type;

        IF status IS DISTINCT FROM 'failed'
           OR node_result IS NULL
           OR node_result NOT LIKE '%is not in the allowed endpoint list%'
           OR position('pg_durable.http_allowed_domains' IN node_result) = 0 THEN
            RAISE EXCEPTION 'TEST FAILED: empty allowlist did not deny % for %: status = %, result = %',
                test_case.hostname, test_case.node_type, status, node_result;
        END IF;
    END LOOP;
END $$;

DROP TABLE _test_http_empty_domains;
RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
