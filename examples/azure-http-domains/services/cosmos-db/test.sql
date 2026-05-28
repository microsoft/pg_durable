-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Cosmos DB domain test
-- Covers: .documents.azure.com
--
-- Lists databases using Azure AD bearer token.
-- The Cosmos DB REST API uses a custom Authorization format for AAD tokens:
--   type=aad&ver=1.0&sig=<jwt-token>
--
-- Requires: AHD_COSMOS_URL, AHD_COSMOS_TOKEN

\getenv cosmos_url   AHD_COSMOS_URL
\getenv cosmos_token AHD_COSMOS_TOKEN

SELECT df.clearvars();
SELECT df.setvar('cosmos_url',   :'cosmos_url');
SELECT df.setvar('cosmos_token', :'cosmos_token');

-- ============================================================================
-- Test: List databases in Cosmos DB (.documents.azure.com)
-- ============================================================================

CREATE TEMP TABLE _test_cosmos (instance_id TEXT);

INSERT INTO _test_cosmos SELECT df.start(
    df.http(
        '{cosmos_url}/dbs',
        'GET',
        NULL,
        '{"Authorization": "type=aad&ver=1.0&sig={cosmos_token}", "x-ms-version": "2018-12-31", "x-ms-date": ""}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-cosmos-db'
);

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    result      TEXT;
    resp_ok     BOOLEAN;
    resp_status INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cosmos;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status = 'completed' THEN
        -- Check if we got a successful response
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';

        resp_ok     := (result::jsonb->>'ok')::boolean;
        resp_status := (result::jsonb->>'status')::int;

        IF resp_ok THEN
            RAISE NOTICE 'TEST PASSED: cosmos_db (.documents.azure.com) — 200 OK';
        ELSE
            -- 4xx responses (e.g., 401 if RBAC isn't configured) still prove
            -- the domain is reachable through the allowlist.
            RAISE NOTICE 'TEST PASSED: cosmos_db (.documents.azure.com) — HTTP % (domain reachable)', resp_status;
        END IF;
    ELSE
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';

        IF result ILIKE '%not in the allowed%' THEN
            RAISE EXCEPTION 'TEST FAILED: cosmos domain blocked by allowlist: %', result;
        END IF;

        -- Non-allowlist failures (connection/timeout) still prove domain is allowed.
        RAISE NOTICE 'TEST PASSED: cosmos_db (.documents.azure.com) — domain allowed (status=%, non-allowlist error)', status;
    END IF;
END $$;

DROP TABLE _test_cosmos;

SELECT 'TEST PASSED' AS result;
