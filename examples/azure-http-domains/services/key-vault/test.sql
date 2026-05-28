-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Key Vault domain test
-- Covers: .vault.azure.net
--
-- Uses Azure AD bearer token (fetched by run-test.sh) to GET a secret.
--
-- Requires: AHD_KEYVAULT_URL, AHD_KEYVAULT_SECRET_NAME, AHD_KEYVAULT_TOKEN

\getenv kv_url         AHD_KEYVAULT_URL
\getenv kv_secret_name AHD_KEYVAULT_SECRET_NAME
\getenv kv_token       AHD_KEYVAULT_TOKEN

SELECT df.clearvars();
SELECT df.setvar('kv_url',         :'kv_url');
SELECT df.setvar('kv_secret_name', :'kv_secret_name');
SELECT df.setvar('kv_token',       :'kv_token');

-- ============================================================================
-- Test: GET a secret from Key Vault (.vault.azure.net)
-- ============================================================================

CREATE TEMP TABLE _test_kv (instance_id TEXT);

INSERT INTO _test_kv SELECT df.start(
    df.http(
        '{kv_url}/secrets/{kv_secret_name}?api-version=7.4',
        'GET',
        NULL,
        '{"Authorization": "Bearer {kv_token}"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-key-vault'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_kv;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: key vault status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: key_vault (.vault.azure.net)';
END $$;

DROP TABLE _test_kv;

SELECT 'TEST PASSED' AS result;
