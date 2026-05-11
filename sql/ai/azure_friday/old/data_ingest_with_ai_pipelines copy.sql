-- ---------------------------------------------------------------------------
-- ACT 1 — RAG Pipeline in Seconds
-- ---------------------------------------------------------------------------

SELECT ai.create_pipeline(
    name    => 'product_rag_pipeline',
    source  => ai.table_source('product_sample', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text',
                 dimensions => 1536)
    ],
    trigger => 'on_change'
);
-- Auto-creates: public.{pipeline_name}_output (doc_id, chunk_index, chunk_text, embedding, ...)

-- Run it once to backfill the existing rows.
SELECT ai.run('product_rag_pipeline');

-- ---------------------------------------------------------------------------
-- ACT 1B — Monitor Pipeline 
-- ---------------------------------------------------------------------------

SELECT * FROM ai.status('product_rag_pipeline');
SELECT * FROM ai.list_pipelines();

-- ---------------------------------------------------------------------------
-- ACT 1C — Vector Search
-- ---------------------------------------------------------------------------
-- Semantic search against the catalog.
CREATE INDEX IF NOT EXISTS idx_product_sample_hnsw ON public.product_rag_pipeline_output
USING hnsw (embedding vector_cosine_ops);

SELECT id, content FROM ai.search('Best chair that is comfortable for a living room',
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    embedding_model => 'text-embedding-3-small',
    search_type => 'vector');
    
-- ---------------------------------------------------------------------------
-- ACT 2 — Auto-Embedding on New Rows
-- ---------------------------------------------------------------------------

-- 2a. The most mundane thing imaginable: just add a new product.
--     Because trigger => 'on_change' + incremental_column => 'updated_at',
--     ONLY this row gets chunked and embedded — not the whole table.
INSERT INTO product_sample (id, title, content)
VALUES (
    99999,
    'New Chair for Living Room',
    'A comfortable and stylish chair perfect for any living room setting. Features ergonomic design, high-quality materials, and a modern aesthetic that complements various interior styles.'
);

SELECT * FROM ai.status('product_rag_pipeline');

-- 2b. Watch the new doc show up in the sink table within a few seconds.
--     Re-run this a couple of times during the narration.

SELECT content FROM ai.search('Best chair that is comfortable for a living room',
    source_table => 'product_rag_pipeline_output',
    content_column => 'chunk_text',
    embedding_model => 'text-embedding-3-small',
    search_type => 'vector');