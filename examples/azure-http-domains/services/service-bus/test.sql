-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Service Bus domain test
-- Covers: .servicebus.windows.net
--
-- Sends a message to a queue using Azure AD bearer token.
--
-- Requires: AHD_SERVICEBUS_NAMESPACE, AHD_SERVICEBUS_QUEUE, AHD_SERVICEBUS_TOKEN

\getenv sb_namespace AHD_SERVICEBUS_NAMESPACE
\getenv sb_queue     AHD_SERVICEBUS_QUEUE
\getenv sb_token     AHD_SERVICEBUS_TOKEN

SELECT df.clearvars();
SELECT df.setvar('sb_namespace', :'sb_namespace');
SELECT df.setvar('sb_queue',     :'sb_queue');
SELECT df.setvar('sb_token',     :'sb_token');

-- ============================================================================
-- Test: Send a message to Service Bus queue (.servicebus.windows.net)
-- ============================================================================

CREATE TEMP TABLE _test_sb (instance_id TEXT);

INSERT INTO _test_sb SELECT df.start(
    df.http(
        'https://{sb_namespace}.servicebus.windows.net/{sb_queue}/messages',
        'POST',
        '{"test": "hello from pg_durable"}',
        '{"Authorization": "Bearer {sb_token}", "Content-Type": "application/json"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-service-bus'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_sb;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: service bus status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: service_bus (.servicebus.windows.net)';
END $$;

DROP TABLE _test_sb;

SELECT 'TEST PASSED' AS result;
