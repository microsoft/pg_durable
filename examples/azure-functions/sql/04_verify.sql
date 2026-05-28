-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Poll for completion (up to ~30 seconds)
DO $$
DECLARE
    inst_id TEXT;
    st TEXT;
    attempts INT := 0;
BEGIN
    SELECT id INTO inst_id
    FROM df.instances
    WHERE label = 'azure-functions-chunk-text'
    ORDER BY created_at DESC
    LIMIT 1;

    IF inst_id IS NULL THEN
        RAISE EXCEPTION 'No instance found with label azure-functions-chunk-text';
    END IF;

    LOOP
        SELECT s INTO st FROM df.status(inst_id) AS s;
        EXIT WHEN lower(st) IN ('completed', 'failed', 'cancelled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    RAISE NOTICE 'Instance % status: % (attempts=%)', inst_id, st, attempts;
END $$;

SELECT id, status, total_tokens, processed_at, left(coalesce(last_error, ''), 160) AS last_error
FROM demo.af_documents
ORDER BY id;

SELECT document_id, chunk_index, token_count, left(chunk_text, 100) AS preview
FROM demo.af_document_chunks
ORDER BY document_id, chunk_index;
