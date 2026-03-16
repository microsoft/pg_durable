-- Start one workflow instance that:
-- 1) Reads one pending document
-- 2) Calls Azure Function via df.http()
-- 3) Stores returned chunks
-- 4) Marks document processed/failed

SELECT df.start(
    $$SELECT COALESCE(
          (
            SELECT jsonb_build_object('id', id, 'content', content)::text
            FROM demo.af_documents
            WHERE status = 'pending'
            ORDER BY id
            LIMIT 1
          ),
          'null'
      )$$ |=> 'doc'
    ~> df.if(
      $$SELECT (($doc)::jsonb) IS NOT NULL$$,
      (
        ($$SELECT jsonb_build_object(
              'document_id', ((($doc)::jsonb->>'id')::bigint),
              'text', (($doc)::jsonb->>'content'),
            'max_tokens', 20,
            'overlap_tokens', 5,
              'language', 'en'
          )::text$$ |=> 'requestbody')
        ~> (df.http(
            '{azure_function_base_url}/api/chunk_text',
            'POST',
            '$requestbody',
            ('{"Content-Type":"application/json","x-functions-key":"{azure_function_key}"}')::jsonb,
            60
        ) |=> 'chunkresponse')
        ~> df.if(
            $$SELECT ($chunkresponse::jsonb->>'ok')::boolean$$,
            (
                $$WITH payload AS (
                      SELECT (($chunkresponse::jsonb->>'body')::jsonb) AS body_json
                  )
                  INSERT INTO demo.af_document_chunks (document_id, chunk_index, chunk_text, token_count)
                  SELECT
                      (payload.body_json->>'document_id')::bigint,
                      (c->>'chunk_index')::int,
                      c->>'text',
                      (c->>'token_count')::int
                  FROM payload, jsonb_array_elements(payload.body_json->'chunks') AS c$$
                ~> $$UPDATE demo.af_documents
                    SET status = 'processed',
                        processed_at = now(),
                        total_tokens = ((($chunkresponse::jsonb->>'body')::jsonb->>'total_tokens')::int),
                        last_error = NULL
                    WHERE id = ((($doc)::jsonb->>'id')::bigint)$$
            ),
            $$UPDATE demo.af_documents
              SET status = 'failed',
                  processed_at = now(),
                  last_error = 'HTTP ' || ($chunkresponse::jsonb->>'status') || ': ' || coalesce(($chunkresponse::jsonb->>'body'), '')
              WHERE id = ((($doc)::jsonb->>'id')::bigint)$$
        )
      ),
      $$SELECT 'no pending documents'$$
    ),
    'azure-functions-chunk-text'
) AS instance_id;
