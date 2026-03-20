# pg_durable for AI Workloads

**Durable orchestration patterns for AI/ML pipelines in PostgreSQL**

This folder contains patterns and scenarios specifically designed for AI workloads. pg_durable provides fault-tolerant execution that's essential for AI pipelines involving external API calls, long-running computations, and human-in-the-loop workflows.

---

## Why pg_durable for AI?

| Challenge | How pg_durable Helps |
|-----------|---------------------|
| **Embedding API failures** | Automatic retries with durable state |
| **Long-running ingestion** | Survives crashes, resumes from last checkpoint |
| **Rate limiting** | Built-in delays and scheduling |
| **Human review workflows** | Signal-based pausing and resumption |
| **Audit requirements** | Complete execution history in `df.nodes` |
| **Multi-step pipelines** | Sequential, parallel, and conditional orchestration |

---

## AI Scenarios

### [Scenario 1: Data Ingestion — Chunking & Embedding](SCENARIOS.md#scenario-1-data-ingestion--chunking--embedding)

> *"I'm building a RAG system and need fault-tolerant document ingestion with embeddings."*

```
document → chunk → generate embedding (Azure AI) → store vectors → update metadata
```

**Key features:** Sequential pipeline, Azure AI extension for embeddings, blob storage ingestion, variable passing

---

### [Scenario 2: Query Processing — Pre/Post LLM Orchestration](SCENARIOS.md#scenario-2-query-processing--prepost-llm-orchestration)

> *"I need to validate input, route queries, call an LLM, then extract/score the response."*

```
validate → classify → route to model → call LLM → extract → score
```

**Key features:** Conditional routing, external API calls, multi-stage processing

---

### [Scenario 3: Evaluation Loop with Human Review](SCENARIOS.md#scenario-3-evaluation-loop-with-human-review)

> *"I want automated evaluation that pauses for human approval when confidence is low."*

```
loop(
  evaluate → score
    ?> high confidence → approve → exit
    !> low confidence → wait for human signal → process decision
)
```

**Key features:** Loops, signals, human-in-the-loop workflows

---

### [Scenario 4: AI Output Governance — Versioned & Governed Results](SCENARIOS.md#scenario-4-ai-output-governance--versioned--governed-results)

> *"I need AI results treated like first-class product data — versioned, governed, and auditable — not disposable one-shot responses."*

```
generate → version → log provenance → apply governance policy
  ?> confidence ≥ threshold → auto-approve → publish
  !> needs review → wait for human → approve / reject / rollback
```

**Key features:** Immutable versioning, provenance tracking, governance policies, rollback, audit trails

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

-- Simple AI pipeline: get document → generate embedding → store
SELECT df.start(
    'SELECT id, content FROM documents WHERE status = ''pending'' LIMIT 1' |=> 'doc'
    ~> 'UPDATE documents 
        SET embedding = azure_openai.create_embeddings(''text-embedding-3-small'', ($doc::jsonb->>''content''))::vector,
            status = ''done''
        WHERE id = ($doc::jsonb->>''id'')::int',
    'ai-pipeline'
);
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

- **[Full AI Scenarios Guide](SCENARIOS.md)** — Complete code samples for all 3 patterns
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
    metadata JSONB
);
```

### Generating Embeddings with Azure AI

```sql
-- Generate embedding directly in SQL (no HTTP needed!)
UPDATE document_chunks 
SET embedding = azure_openai.create_embeddings(
    'text-embedding-3-small',  -- your Azure OpenAI deployment name
    content
)::vector
WHERE id = $chunk_id;

-- Or inline in a durable function step:
~> 'UPDATE document_chunks 
    SET embedding = azure_openai.create_embeddings(''text-embedding-3-small'', content)::vector
    WHERE id = ($chunk::jsonb->>''id'')::int'
```

### Rate Limiting with Delays

```sql
-- Add delay between embedding calls to respect rate limits
'UPDATE chunks SET embedding = azure_openai.create_embeddings(...) WHERE id = 1' 
~> df.sleep(1)  -- 1 second delay
~> 'UPDATE chunks SET embedding = azure_openai.create_embeddings(...) WHERE id = 2'
```

### Handling Failures

```sql
-- pg_durable automatically retries failed steps
-- Azure AI extension handles transient errors internally
```
