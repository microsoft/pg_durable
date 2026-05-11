-- ---------------------------------------------------------------------------
-- ACT 1 — RAG Pipeline in Seconds
-- ---------------------------------------------------------------------------

SELECT ai.create_pipeline(
    name    => 'rag_pipeline',
    source  => ai.table_source('documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                 dimensions => 1536)
    ],
    trigger => 'on_change'
);
-- Auto-creates: public.{pipeline_name}_output (doc_id, chunk_index, chunk_text, embedding, ...)

-- Run it once to backfill the existing rows.
SELECT ai.run('rag_pipeline');

-- ---------------------------------------------------------------------------
-- ACT 1B — Monitor Pipeline 
-- ---------------------------------------------------------------------------

SELECT ai.explain()
SELECT ai.status('product_rag_pipeline');
SELECT ai.list_pipelines()

-- ---------------------------------------------------------------------------
-- ACT 1B — Vector Search
-- ---------------------------------------------------------------------------
-- Semantic search against the catalog.
SELECT doc_id, chunk_text, chunk_index
     FROM rag_pipeline_output
     ORDER BY embedding <=> azure_openai.create_embeddings(
                                'text-embedding-3-small',
                                'wireless headphones for travel and focused work')::vector
     LIMIT 5;

-- ---------------------------------------------------------------------------
-- ACT 2 — Auto-Embedding on New Rows
-- ---------------------------------------------------------------------------

-- 2a. The most mundane thing imaginable: just add a new product.
--     Because trigger => 'on_change' + incremental_column => 'updated_at',
--     ONLY this row gets chunked and embedded — not the whole table.
INSERT INTO documents (title, content)
VALUES (
    'Apple AirPods Pro (2nd Gen, USB-C)',
    'Apple Airpod, best Active noise-cancelling wireless earbuds with adaptive transparency, '
    'personalized spatial audio, USB-C MagSafe charging case, and up to '
    '6 hours of listening time per charge. Tuned for music, calls, and '
    'all-day wear.'
);

-- 2b. Watch the new doc show up in the sink table within a few seconds.
--     Re-run this a couple of times during the narration.
SELECT doc_id, chunk_text, chunk_index
     FROM rag_pipeline_output
     ORDER BY embedding <=> azure_openai.create_embeddings(
                                'text-embedding-3-small',
                                'Best Apple headphones for travel')::vector
     LIMIT 5;
-- ---------------------------------------------------------------------------
-- ACT 3 — What Else Can Pipelines Do?  
-- ---------------------------------------------------------------------------
-- Same array. Same durable graph. Same crash safety. Just more steps:

SELECT ai.create_pipeline(
    name    => 'rag_pipeline_plus',
    source  => ai.table_source('documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),

        -- Enrichment: pull structured fields out of the chunk.
        ai.extract(
                model        => 'gpt-5-mini',
                input_column => 'chunk_text',
                data         => ARRAY[
                    'category - product category such as audio, input, furniture, power, or accessory',
                    'audience - who this product is for',
                    'price_tier - budget, mid, or premium'
                ]
        ),

        -- Human-in-the-loop: pipeline literally pauses here until approved.
        ai.request_approval(content => 'chunk_text', timeout => 3600),

        -- Embeddings for retrieval.
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                     dimensions => 1536),

        -- Generation: e.g. SEO blurb or summary.
        ai.generate(
            model           => 'gpt-5-mini',
            input_column    => 'chunk_text',
            prompt_template => 'Write a one-sentence customer-friendly summary of: {chunk_text}'
            )
        ],
        trigger => 'on_change'
    );

SELECT ai.run('rag_pipeline_plus');
    -- Parallel branches, schedules, and event triggers all compose the same way.

-- ---------------------------------------------------------------------------
-- (Optional) Cleanup
-- ---------------------------------------------------------------------------

-- SELECT ai.drop('rag_pipeline');
-- SELECT ai.drop('rag_pipeline_plus');
-- DROP TABLE IF EXISTS documents CASCADE;
-- DROP TABLE IF EXISTS rag_pipeline_output CASCADE;

