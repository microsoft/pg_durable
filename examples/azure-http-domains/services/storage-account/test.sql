-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Azure Storage Account domain tests
--
-- Covers: .blob.core.windows.net, .blob.storage.azure.net,
--         .queue.core.windows.net, .table.core.windows.net,
--         .file.core.windows.net
--
-- Requires environment variables:
--   AHD_STORAGE_ACCOUNT, AHD_STORAGE_SAS, AHD_STORAGE_CONTAINER,
--   AHD_STORAGE_BLOB, AHD_STORAGE_QUEUE, AHD_STORAGE_TABLE,
--   AHD_STORAGE_SHARE

\getenv storage_account AHD_STORAGE_ACCOUNT
\getenv storage_sas     AHD_STORAGE_SAS
\getenv storage_container AHD_STORAGE_CONTAINER
\getenv storage_blob    AHD_STORAGE_BLOB
\getenv storage_queue   AHD_STORAGE_QUEUE
\getenv storage_table   AHD_STORAGE_TABLE
\getenv storage_share   AHD_STORAGE_SHARE

SELECT df.clearvars();
SELECT df.setvar('acct',      :'storage_account');
SELECT df.setvar('sas',       :'storage_sas');
SELECT df.setvar('container', :'storage_container');
SELECT df.setvar('blob',      :'storage_blob');
SELECT df.setvar('queue',     :'storage_queue');
SELECT df.setvar('tbl',       :'storage_table');
SELECT df.setvar('share',     :'storage_share');

-- ============================================================================
-- Test 1: Blob Storage — GET blob (.blob.core.windows.net)
-- ============================================================================

CREATE TEMP TABLE _test_blob (instance_id TEXT);

INSERT INTO _test_blob SELECT df.start(
    df.http(
        'https://{acct}.blob.core.windows.net/{container}/{blob}?{sas}',
        'GET',
        NULL,
        '{"x-ms-version": "2023-01-03"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-blob-storage'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_blob;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: blob storage status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: blob_storage (.blob.core.windows.net)';
END $$;

DROP TABLE _test_blob;

-- ============================================================================
-- Test 2: Queue Storage — peek messages (.queue.core.windows.net)
-- ============================================================================

CREATE TEMP TABLE _test_queue (instance_id TEXT);

INSERT INTO _test_queue SELECT df.start(
    df.http(
        'https://{acct}.queue.core.windows.net/{queue}/messages?peekonly=true&{sas}',
        'GET',
        NULL,
        '{"x-ms-version": "2023-01-03"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-queue-storage'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_queue;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: queue storage status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: queue_storage (.queue.core.windows.net)';
END $$;

DROP TABLE _test_queue;

-- ============================================================================
-- Test 3: Table Storage — insert entity (.table.core.windows.net)
-- ============================================================================

CREATE TEMP TABLE _test_table (instance_id TEXT);

INSERT INTO _test_table SELECT df.start(
    df.http(
        'https://{acct}.table.core.windows.net/{tbl}?{sas}',
        'POST',
        '{"PartitionKey": "pgdtest", "RowKey": "1", "Value": "hello from pg_durable"}',
        '{"x-ms-version": "2023-01-03", "Content-Type": "application/json", "Accept": "application/json;odata=nometadata", "Prefer": "return-no-content"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-table-storage'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_table;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: table storage status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: table_storage (.table.core.windows.net)';
END $$;

DROP TABLE _test_table;

-- ============================================================================
-- Test 4: File Storage — list share root (.file.core.windows.net)
-- ============================================================================

CREATE TEMP TABLE _test_file (instance_id TEXT);

INSERT INTO _test_file SELECT df.start(
    df.http(
        'https://{acct}.file.core.windows.net/{share}?restype=directory&comp=list&{sas}',
        'GET',
        NULL,
        '{"x-ms-version": "2023-01-03"}'::jsonb,
        30
    ) |=> 'resp',
    'ahd-test-file-storage'
);

DO $$
DECLARE
    inst_id TEXT;
    status  TEXT;
    result  TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_file;
    SELECT df.wait_for_completion(inst_id) INTO status;

    IF status != 'completed' THEN
        SELECT r.result::text INTO result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';
        RAISE EXCEPTION 'TEST FAILED: file storage status=%, result=%', status, result;
    END IF;

    RAISE NOTICE 'TEST PASSED: file_storage (.file.core.windows.net)';
END $$;

DROP TABLE _test_file;

-- ============================================================================
-- Test 5: Blob Storage alternate domain (.blob.storage.azure.net)
--
-- Azure Storage supports an alternate domain form:
--   https://<account>.z<N>.blob.storage.azure.net
-- The zone number depends on the region; we query it via the primary endpoint.
-- For simplicity we attempt zone 6 which is common for eastus — a connection
-- error (not an allowlist block) is also a passing result since it proves the
-- domain suffix passes the allowlist.
-- ============================================================================

CREATE TEMP TABLE _test_blob_alt (instance_id TEXT);

INSERT INTO _test_blob_alt SELECT df.start(
    df.http(
        'https://{acct}.z6.blob.storage.azure.net/{container}/{blob}?{sas}',
        'GET',
        NULL,
        '{"x-ms-version": "2023-01-03"}'::jsonb,
        15
    ) |=> 'resp',
    'ahd-test-blob-alt'
);

DO $$
DECLARE
    inst_id     TEXT;
    status      TEXT;
    node_result TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_blob_alt;
    SELECT df.wait_for_completion(inst_id, 30) INTO status;

    -- Success or a non-allowlist failure both count as passing.
    IF status = 'completed' THEN
        RAISE NOTICE 'TEST PASSED: blob_storage_alt (.blob.storage.azure.net) — 200 OK';
    ELSE
        SELECT r.result::text INTO node_result
        FROM df.nodes r WHERE r.instance_id = inst_id AND r.node_type = 'HTTP';

        IF node_result ILIKE '%not in the allowed%' THEN
            RAISE EXCEPTION 'TEST FAILED: blob alt domain blocked by allowlist: %', node_result;
        END IF;

        -- Connection/DNS/timeout errors are acceptable — the domain passed the allowlist.
        RAISE NOTICE 'TEST PASSED: blob_storage_alt (.blob.storage.azure.net) — domain allowed (status=%)', status;
    END IF;
END $$;

DROP TABLE _test_blob_alt;

SELECT 'TEST PASSED' AS result;
