-- =============================================================================
-- RAG Pipeline Example — built on pg_durable
-- =============================================================================
--
-- Demonstrates a declarative AI pipeline that:
--   1. Reads new/updated rows from a documents table
--   2. Chunks document content into overlapping segments
--   3. Generates embeddings via Azure OpenAI
--   4. Auto-creates an output table and writes vectors there
--   5. Reacts to changes automatically via trigger
--
-- Prerequisites:
--   CREATE EXTENSION pg_durable;
--   \i sql/ai/ai_pipeline.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Set up the source table with some documents
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO documents (title, content) VALUES
    ('Intro to pgvector',
     'pgvector is a PostgreSQL extension for vector similarity search. '
     'It supports exact and approximate nearest neighbor search using '
     'IVFFlat and HNSW indexes. Vectors can be stored alongside regular '
     'relational data, enabling hybrid queries that combine semantic '
     'similarity with traditional SQL filters.'),
    ('Durable Execution',
     'Durable execution ensures that long-running workflows survive '
     'crashes, restarts, and network failures. pg_durable brings this '
     'pattern into PostgreSQL by persisting function graphs and replaying '
     'them through a background worker powered by the duroxide runtime.');

-- ---------------------------------------------------------------------------
-- Step 2: Create the pipeline — no sink table needed, it's auto-created
-- ---------------------------------------------------------------------------

-- SELECT ai.drop('rag_pipeline');

SELECT ai.create_pipeline(
    name    => 'rag_pipeline',
    source  => ai.file_source('documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text', dimensions => 1536)
    
    ],
    trigger => 'on_change'
);
-- Auto-creates: public.rag_pipeline_output (doc_id, chunk_index, chunk_text, embedding, ...)
-- [optional] sink    => ai.table_sink('rag_pipeline_output'),

-- ---------------------------------------------------------------------------
-- Step 3: Inspect the execution plan
-- ---------------------------------------------------------------------------

SELECT ai.explain('demo_rag_pipeline');

-- Output:
--   Pipeline: rag_pipeline
--   Trigger:  on_change
--   ──────────────────────────────
--     [SOURCE] public.documents (incremental: updated_at)
--        │
--        ▼
--     [STEP 1] CHUNK (column=content, method=recursive, size=512, overlap=64)
--        │
--        ▼
--     [STEP 2] EMBED (model=text-embedding-3-small, column=chunk_text, batch=100)
--        │
--        ▼
--     [SINK] public.rag_pipeline_output

-- ---------------------------------------------------------------------------
-- Step 4: Run the pipeline
-- ---------------------------------------------------------------------------

-- Trigger fires automatically (on_change), or run manually:
SELECT ai.run('rag_pipeline');

-- ---------------------------------------------------------------------------
-- Step 5: Monitor pipeline status
-- ---------------------------------------------------------------------------

-- Quick status check
SELECT * FROM ai.status('demo_rag_pipeline');

-- Wait for the current run to finish (up to 60s)
SELECT ai.wait_for_completion('demo_rag_pipeline', 60);

-- Check the auto-created output table
SELECT doc_id, chunk_index, left(chunk_text, 60) AS chunk_preview
  FROM demo_rag_pipeline_output
 ORDER BY doc_id, chunk_index;

-- List all registered pipelines
SELECT * FROM ai.list_pipelines();

-- View run history and results
SELECT * FROM ai.result('demo_rag_pipeline');

-- ---------------------------------------------------------------------------
-- Step 6: Backfill — reprocess all data after model or strategy changes
-- ---------------------------------------------------------------------------

-- Reset the checkpoint and run from scratch
SELECT ai.backfill('demo_rag_pipeline');
SELECT ai.wait_for_completion('demo_rag_pipeline', 300);

-- ---------------------------------------------------------------------------
-- Step 7: Pause / resume / drop
-- ---------------------------------------------------------------------------

-- Pause pipeline (on_change trigger still fires but runs are skipped)
SELECT ai.pause('demo_rag_pipeline');

-- Resume when ready
SELECT ai.resume('demo_rag_pipeline');

-- Remove pipeline entirely (drops trigger, deletes metadata)
-- SELECT ai.drop('demo_rag_pipeline');

-- ---------------------------------------------------------------------------
-- Step 8: Retrieve relevant chunks for a user query using azure_ai + pgvector
-- ---------------------------------------------------------------------------

SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://<your-endpoint>.openai.azure.com/');
SELECT azure_ai.set_setting('azure_openai.subscription_key', '<your-subscription-key>');

SELECT azure_ai.get_setting('azure_openai.endpoint');

-- Semantic search: embed the user's question, then find the closest chunks
WITH query AS (
    SELECT azure_openai.create_embeddings(
        'text-embedding-3-small',
        'How does pg_durable handle crash recovery?',
        dimensions => 1536
    )::vector(1536) AS embedding
)
SELECT
    dv.doc_id,
    dv.chunk_index,
    dv.chunk_text,
    1 - (dv.embedding <=> q.embedding) AS similarity
FROM demo_rag_pipeline_output dv, query q
ORDER BY dv.embedding <=> q.embedding
LIMIT 5;

-- ---------------------------------------------------------------------------
-- Step 9: Add some new documents and see them processed automatically
-- ---------------------------------------------------------------------------

INSERT INTO documents (title, content) VALUES
    ('HNSW Indexing',
     'HNSW (Hierarchical Navigable Small World) is an approximate nearest '
     'neighbor algorithm that builds a multi-layer graph for fast similarity '
     'search. In pgvector, you create an HNSW index with '
     'CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops). '
     'It offers better query performance than IVFFlat at the cost of slower '
     'index build times and higher memory usage.'),
    ('Background Workers in PostgreSQL',
     'PostgreSQL background workers are auxiliary processes registered via '
     'shared_preload_libraries. They can connect to databases, run '
     'transactions, and perform maintenance tasks independently of user '
     'sessions. pg_durable uses a background worker to run the duroxide '
     'runtime, polling for queued function-graph instances and executing '
     'them durably.');

-- The on_change trigger fires automatically — wait and check results
SELECT ai.wait_for_completion('rag_pipeline', 60);

SELECT doc_id, chunk_index, left(chunk_text, 60) AS chunk_preview
  FROM rag_pipeline_output
 ORDER BY doc_id, chunk_index;
WITH query AS (
    SELECT azure_openai.create_embeddings(
        'text-embedding-3-small',
        'How is HNSW',
        dimensions => 1536
    )::vector(1536) AS embedding
)
SELECT
    dv.doc_id,
    dv.chunk_index,
    dv.chunk_text,
    1 - (dv.embedding <=> q.embedding) AS similarity
FROM document_vectors dv, query q
ORDER BY dv.embedding <=> q.embedding
LIMIT 5;