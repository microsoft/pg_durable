RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF current_setting('pg_durable.managed_identity_client_id') IS DISTINCT FROM '' THEN
        RAISE EXCEPTION 'TEST FAILED: standard phase must leave managed identity unconfigured';
    END IF;
END $$;

DROP SERVER IF EXISTS mi_unconfigured CASCADE;
CREATE SERVER mi_unconfigured FOREIGN DATA WRAPPER pg_durable_fdw
    OPTIONS (base_url 'https://pg-durable-mi.blob.core.windows.net', auth_scheme 'managed-identity');
GRANT USAGE ON FOREIGN SERVER mi_unconfigured TO df_e2e_user;
SELECT df.grant_usage('df_e2e_user', include_http => true);
SET SESSION AUTHORIZATION df_e2e_user;

CREATE TEMP TABLE _mi_unconfigured (instance_id text, expected text);
INSERT INTO _mi_unconfigured VALUES
    (df.start(df.http(df.endpoint('mi_unconfigured', '/data'), 'GET'), 'mi-unconfigured-http'), 'failed'),
    (df.start(df.http_multipart(df.endpoint('mi_unconfigured', '/upload'),
        parts => '[{"name":"file","data_b64":"aGVsbG8="}]'), 'mi-unconfigured-multipart'), 'failed'),
    (df.start(df.http('https://httpbingo.org/status/204', 'GET'), 'mi-unconfigured-ordinary-http'), 'completed');

DO $$
DECLARE
    test_case record;
    actual_status text;
    node_result text;
BEGIN
    FOR test_case IN SELECT * FROM _mi_unconfigured LOOP
        actual_status := df.await_instance(test_case.instance_id, 30);
        SELECT result::text INTO node_result FROM df.nodes
            WHERE instance_id = test_case.instance_id AND node_type IN ('HTTP', 'HTTP_MULTIPART');
        IF actual_status IS DISTINCT FROM test_case.expected THEN
            RAISE EXCEPTION 'TEST FAILED: unconfigured identity request expected %, got %, result %',
                test_case.expected, actual_status, node_result;
        END IF;
        IF test_case.expected = 'failed' AND (node_result IS NULL
            OR node_result NOT LIKE '%Managed identity is disabled%pg_durable.managed_identity_client_id%') THEN
            RAISE EXCEPTION 'TEST FAILED: request attempted ambient identity fallback: %', node_result;
        END IF;
        IF test_case.expected = 'completed' AND (df.result(test_case.instance_id)::jsonb->>'status')::integer IS DISTINCT FROM 204 THEN
            RAISE EXCEPTION 'TEST FAILED: unconfigured managed identity affected ordinary HTTP: %', node_result;
        END IF;
    END LOOP;
END $$;

DROP TABLE _mi_unconfigured;
RESET SESSION AUTHORIZATION;
DROP SERVER mi_unconfigured;
SELECT 'TEST PASSED' AS result;