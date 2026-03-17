-- Start one workflow instance that:
-- 1) Reads one pending document
-- 2) Calls Azure Function via df.http()
-- 3) Stores returned chunks
-- 4) Marks document processed/failed

SELECT df.start(
    -- 1. Fetch one pending document
    $$SELECT id, content FROM demo.af_documents
        WHERE status = 'pending'
        ORDER BY id
        LIMIT 1
    $$ |=> 'doc'

    ~> df.if_rows('doc',

        -- 2. Build & send HTTP request
        ($$SELECT jsonb_build_object(
                'document_id', $doc.id,
                'text',        $doc.content,
                'max_tokens',  20,
                'overlap_tokens', 5,
                'language',    'en'
            )::text$$ |=> 'requestbody')

        ~> (
            df.http(
                '{azure_function_base_url}/api/chunk_text',
                'POST',
                '$requestbody',
                '{"Content-Type":"application/json","x-functions-key":"{azure_function_key}"}'::jsonb,
                60
            ) |=> 'resp')

        -- 3. Parse response fields
        ~> ($$SELECT ($resp::jsonb->>'ok')::boolean AS ok,
                     $resp::jsonb->>'body' AS body$$ |=> 'r')

        -- 4. Branch on success/failure
        ~> df.if(
            $$SELECT $r.ok$$,

            -- Success: insert chunks, then mark processed
            $$INSERT INTO demo.af_document_chunks (document_id, chunk_index, chunk_text, token_count)
                SELECT $doc.id,
                (c->>'chunk_index')::int,
                c->>'text',
                (c->>'token_count')::int
            FROM jsonb_array_elements(($r.body)::jsonb->'chunks') AS c$$
            ~> $$UPDATE demo.af_documents
                SET status = 'processed',
                processed_at = now(),
                total_tokens = (($r.body)::jsonb->>'total_tokens')::int,
                last_error = NULL
                WHERE id = $doc.id$$,

            -- Failure: mark failed
            $$UPDATE demo.af_documents
                SET status = 'failed',
                processed_at = now(),
                last_error = 'HTTP ' || ($resp::jsonb->>'status') || ': ' || coalesce($r.body, '')
                WHERE id = $doc.id$$
        ),

        -- No pending documents
        $$SELECT 'no pending documents'$$
    ),
    'azure-functions-chunk-text'
) AS instance_id;
