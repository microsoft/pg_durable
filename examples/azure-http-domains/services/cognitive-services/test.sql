-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Cognitive Services domain test
-- Covers: .cognitiveservices.azure.com
--
-- Calls the Language Detection API with a simple text input.
--
-- Requires: AHD_COGNITIVE_ENDPOINT, AHD_COGNITIVE_KEY

\getenv cog_endpoint AHD_COGNITIVE_ENDPOINT
\getenv cog_key      AHD_COGNITIVE_KEY

SELECT df.clearvars();
SELECT df.setvar('cog_endpoint', :'cog_endpoint');
SELECT df.setvar('cog_key',      :'cog_key');

-- ============================================================================
-- Test: Detect language via Cognitive Services (.cognitiveservices.azure.com)
-- ============================================================================

CREATE TEMP TABLE _test_cog (instance_id TEXT);

INSERT INTO _test_cog SELECT df.start(
    df.http(
        '{cog_endpoint}/language/:analyze-text?api-version=2023-04-01',
        'POST',
        '{"kind": "LanguageDetection", "parameters": {"modelVersion": "latest"}, "analysisInput": {"documents": [{"id": "1", "text": "Hello, world! This is a test from pg_durable."}]}}',
        '{"Ocp-Apim-Subscription-Key": "{cog_key}", "Content-Type": "application/json"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-cognitive-services'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_cog;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: cognitive services status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: cognitive_services (.cognitiveservices.azure.com)';
END $$;

DROP TABLE _test_cog;

SELECT 'TEST PASSED' AS result;
