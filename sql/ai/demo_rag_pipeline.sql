-- =============================================================================
-- RAG Pipeline Example — built on pg_durable
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Set up the source table with some documents
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS demo_documents CASCADE;
CREATE TABLE demo_documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO demo_documents (title, content) VALUES
    ('Intro to pgvector',
     'pgvector is a PostgreSQL extension for vector similarity search. '
     'It supports exact and approximate nearest neighbor search using '
     'IVFFlat and HNSW indexes. Vectors can be stored alongside regular '
     'relational data, enabling hybrid queries that combine semantic '
     'similarity with traditional SQL filters. The extension is widely '
     'used for building retrieval-augmented generation (RAG) systems, '
     'recommendation engines, and semantic search applications. pgvector '
     'integrates seamlessly with PostgreSQL''s existing infrastructure '
     'including MVCC, WAL, and logical replication, making it '
     'production-ready for enterprise workloads. Index types include '
     'IVFFlat for fast approximate search and HNSW for higher recall '
     'at the cost of more memory. Both index types support inner product, '
     'cosine distance, and L2 distance metrics.'),
    ('Durable Execution with pg_durable',
     'Durable execution ensures that long-running workflows survive '
     'crashes, restarts, and network failures. pg_durable brings this '
     'pattern into PostgreSQL by persisting function graphs and replaying '
     'them through a background worker powered by the duroxide runtime. '
     'Each workflow step is recorded as a node in a directed acyclic '
     'graph (DAG), and the runtime guarantees exactly-once execution '
     'semantics. If the database crashes mid-workflow, the background '
     'worker automatically resumes from the last completed step. This '
     'is particularly useful for AI pipelines that involve expensive '
     'LLM calls, embedding generation, and multi-step data '
     'transformations. pg_durable supports sequential chains, parallel '
     'fan-out with join, conditional branching, loops, HTTP calls, '
     'and human approval gates via signals.'),
    ('AI Pipelines in PostgreSQL',
     'AI pipelines bring machine learning workflows directly into the '
     'database, eliminating the need for external orchestrators like '
     'Airflow or Dagster. By combining chunking, embedding, and '
     'extraction steps with durable execution, pg_durable ensures that '
     'even complex multi-step AI workflows complete reliably. The '
     'declarative pipeline API lets users define sources, transformation '
     'steps, and sinks using simple SQL function calls. Pipelines can '
     'be triggered manually, on data changes, or on a schedule. Each '
     'run creates a durable function instance that can be monitored, '
     'paused, resumed, or cancelled. The pipeline captures intermediate '
     'results at each step, making it easy to debug and understand the '
     'data flow. Cost tracking and built-in monitoring provide visibility '
     'into token usage and processing throughput.');

-- ---------------------------------------------------------------------------
-- Step 2: Create the pipeline — no sink table needed, it's auto-created
-- ---------------------------------------------------------------------------

-- SELECT ai.drop('demo_rag_pipeline');

SELECT ai.create_pipeline(
    name    => 'demo_rag_pipeline',
    source  => ai.table_source('demo_documents', incremental_column => 'updated_at'),
    steps   => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text', dimensions => 1536)
    ],
    trigger => 'on_change'
);
-- Auto-creates: public.demo_rag_pipeline_output (doc_id, chunk_index, chunk_text, embedding, ...)

-- Trigger fires automatically (on_change), or run manually:
SELECT ai.run('demo_rag_pipeline');

-- ---------------------------------------------------------------------------
-- Step 3: Retrieve relevant chunks for a user query using azure_ai + pgvector
-- ---------------------------------------------------------------------------

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
