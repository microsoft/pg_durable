-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Unrestricted mode permits plaintext, unlisted domains, and private networks.
-- An explicitly empty domain allowlist must not restrict this mode.

DO $$
BEGIN
    IF current_setting('pg_durable.http_security') IS DISTINCT FROM 'unrestricted' THEN
        RAISE EXCEPTION 'TEST FAILED: expected unrestricted startup policy';
    END IF;
    IF current_setting('pg_durable.http_allowed_domains') IS DISTINCT FROM '' THEN
        RAISE EXCEPTION 'TEST FAILED: http-allow-all phase requires an empty allowlist';
    END IF;
END $$;

SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _test_http_unrestricted (instance_id TEXT, node_type TEXT, url TEXT);

INSERT INTO _test_http_unrestricted
SELECT df.start(
    CASE node_type
        WHEN 'HTTP' THEN df.http(url, 'GET', NULL, NULL, 5)
        ELSE df.http_multipart(url, 'POST', '[{"name":"field","data_b64":"dmFsdWU="}]'::jsonb, NULL, 5)
    END,
    'test-http-unrestricted-' || node_type
), node_type, url
FROM (VALUES
    ('http://example.com/'),
    ('https://8.8.8.8/'),
    ('http://127.0.0.1:1/'),
    ('http://localhost:1/')
) AS destinations(url)
CROSS JOIN (VALUES ('HTTP'), ('HTTP_MULTIPART')) AS node_types(node_type);

DO $$
DECLARE
    test_case RECORD;
    status TEXT;
    node_result TEXT;
    http_status INT;
BEGIN
    FOR test_case IN SELECT * FROM _test_http_unrestricted ORDER BY node_type, url LOOP
        SELECT df.await_instance(test_case.instance_id, 30) INTO status;
        SELECT result::text INTO node_result
        FROM df.nodes
        WHERE instance_id = test_case.instance_id AND node_type = test_case.node_type;

        IF status IS NULL OR status NOT IN ('completed', 'failed') OR node_result IS NULL THEN
            RAISE EXCEPTION 'TEST FAILED: unrestricted % request to %: status = %, result = %',
                test_case.node_type, test_case.url, status, node_result;
        END IF;

        IF status = 'completed' THEN
            http_status := (node_result::jsonb->>'status')::int;
            IF http_status IS NULL OR http_status NOT BETWEEN 100 AND 599 THEN
                RAISE EXCEPTION 'TEST FAILED: expected an HTTP response: %', node_result;
            END IF;
        ELSIF NOT (node_result LIKE ANY (ARRAY[
            '%HTTP connection failed%', '%HTTP request failed%',
            '%HTTP timeout after%', '% returned 5__:%'
        ])) THEN
            RAISE EXCEPTION 'TEST FAILED: unrestricted % request to % did not reach HTTP transport: %',
                test_case.node_type, test_case.url, node_result;
        END IF;
    END LOOP;
END $$;

DROP TABLE _test_http_unrestricted;
RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED' AS result;
