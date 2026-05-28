-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Function App domain test
-- Covers: .azurewebsites.net
--
-- Tests that df.http() can reach an Azure Function App.
-- We GET the root page which returns a default welcome page (200 OK).
-- No deployed function code is needed.
--
-- Requires: AHD_FUNCAPP_URL

\getenv funcapp_url AHD_FUNCAPP_URL

SELECT df.clearvars();
SELECT df.setvar('funcapp_url', :'funcapp_url');

-- ============================================================================
-- Test: GET Function App root page (.azurewebsites.net)
-- ============================================================================

CREATE TEMP TABLE _test_funcapp (instance_id TEXT);

INSERT INTO _test_funcapp SELECT df.start(
    df.http('{funcapp_url}/', 'GET') |=> 'resp',
    'ahd-test-function-app'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_funcapp;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: function app status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: function_app (.azurewebsites.net)';
END $$;

DROP TABLE _test_funcapp;

SELECT 'TEST PASSED' AS result;
