# pg_durable for AI Workloads

**Declarative AI/ML pipelines in PostgreSQL, backed by durable execution**

This folder contains patterns and scenarios specifically designed for AI workloads. The `ai.*` pipeline API lets you describe sources, AI steps, sinks, and triggers in SQL; pg_durable turns those definitions into fault-tolerant durable executions.

---

## Why pg_durable for AI?

| Challenge | How pg_durable Helps |
|-----------|---------------------|
| **Embedding API failures** | Automatic retries with durable state |
| **Long-running ingestion** | Survives crashes, resumes from last checkpoint |
| **Rate limiting** | Built-in delays and scheduling |
| **Human review workflows** | Signal-based pausing and resumption |
| **Audit requirements** | Complete execution history in `df.nodes` |
| **Multi-step pipelines** | Declarative `ai.create_pipeline()` definitions translated into durable graphs |

---

## AI Scenarios

### [Scenario 1: Data Ingestion — Chunking & Embedding](SCENARIOS.md#scenario-1-data-ingestion--chunking--embedding)

> *"I'm building a RAG system and need fault-tolerant document ingestion with embeddings."*

```
document → chunk → generate embedding (Azure AI) → store vectors → update metadata
```

**Key features:** `ai.create_pipeline()`, table source, `ai.chunk()`, `ai.embed()`, incremental checkpointing

---

### [Scenario 2: Query Processing — Pre/Post LLM Orchestration](SCENARIOS.md#scenario-2-query-processing--prepost-llm-orchestration)

> *"I need to validate input, route queries, call an LLM, then extract/score the response."*

```
validate → classify → route to model → call LLM → extract → score
```

**Key features:** Filtered table sources, multiple model-specific pipelines, `ai.generate()`, `ai.extract()`

---

### [Scenario 3: Human Approval — Triage with Review Gate](SCENARIOS.md#scenario-3-human-approval---triage-with-review-gate)

> *"I want automated evaluation that pauses for human approval when confidence is low."*

```
extract triage → request approval → generate draft → embed → work queue
```

**Key features:** `ai.request_approval()`, signal-based resume, durable human-in-the-loop workflows

---

### [Scenario 4: AI Output Governance — Versioned & Governed Results](SCENARIOS.md#scenario-4-ai-output-governance--versioned--governed-results)

> *"I need AI results treated like first-class product data — versioned, governed, and auditable — not disposable one-shot responses."*

```
generate candidate → extract governance metadata → request approval → promote version → audit
```

**Key features:** `ai.generate()`, `ai.extract()`, `ai.request_approval()`, immutable version tables, rollback, audit trails

---

## Quick Start

```sql
-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_durable;
CREATE EXTENSION IF NOT EXISTS azure_ai;
CREATE EXTENSION IF NOT EXISTS vector;

-- Configure Azure OpenAI (one-time setup)
SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://YOUR_RESOURCE.openai.azure.com');
SELECT azure_ai.set_setting('azure_openai.subscription_key', 'YOUR_API_KEY');

-- Load the pipeline API once per database
\i sql/ai/ai_pipeline_functions.sql

CREATE TABLE documents (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Simple AI pipeline: documents -> chunks -> embeddings -> auto-created sink
SELECT ai.create_pipeline(
    name   => 'rag_pipeline',
    source => ai.table_source('documents', incremental_column => 'updated_at'),
    steps  => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text', dimensions => 1536)
    ],
    trigger => 'on_change'
);

SELECT ai.run('rag_pipeline');
SELECT ai.wait_for_completion('rag_pipeline', 300);
SELECT doc_id, chunk_index, left(chunk_text, 80) AS preview
FROM rag_pipeline_output;
```

---

## AI Use Case Categories

### Data Ingestion Tasks
- Embeddings & chunking at scale
- Unstructured → structured data conversion
- Automated graph construction (with Apache AGE)
- Multi-stage LLM transformations

### Index Build & Optimization
- Durable vector index construction
- Resumable long-running builds
- Progress tracking via orchestration history

### Auditability & Responsible AI
- Complete event logs per pipeline run
- Deterministic reconstruction of decision paths
- Compliance-ready audit trails

### Data Retrieval Tasks
- Complex pre/post-processing on AI queries
- Multi-model routing and orchestration
- Response scoring and refinement loops

---

## Learn More

- **[Full AI Scenarios Guide](SCENARIOS.md)** — Complete code samples for all 4 patterns
- **[Main Scenarios Guide](../SCENARIOS.md)** — All 8 scenarios (database + AI)
- **[User Guide](../../USER_GUIDE.md)** — Complete DSL reference

---

## Production Considerations

### Using pgvector and Azure AI Extension

```sql
-- Install required extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;

-- Configure Azure OpenAI endpoint (one-time setup)
SELECT azure_ai.set_setting('azure_openai.endpoint', 'https://YOUR_RESOURCE.openai.azure.com');
SELECT azure_ai.set_setting('azure_openai.subscription_key', 'YOUR_API_KEY');

-- Create table with vector column
CREATE TABLE document_chunks (
    id SERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536),  -- text-embedding-3-small dimension
    metadata JSONB,
    updated_at TIMESTAMPTZ DEFAULT now()
);
```

### Generating Embeddings with an AI Pipeline

```sql
SELECT ai.create_pipeline(
    name   => 'document_vectors_pipeline',
    source => ai.table_source('document_chunks', incremental_column => 'updated_at'),
    steps  => ARRAY[
        ai.embed(model => 'text-embedding-3-small', input_column => 'content', dimensions => 1536)
    ],
    trigger => 'on_change'
);

-- Auto-creates: public.document_vectors_pipeline_output
```

### Backfill After Pipeline Changes

```sql
-- Reprocess all source rows after changing model, chunking, or sink schema.
SELECT ai.backfill('document_vectors_pipeline');
SELECT ai.wait_for_completion('document_vectors_pipeline', 300);
```

### Handling Failures

```sql
-- pg_durable automatically retries failed steps
-- Azure AI extension handles transient errors internally
```
