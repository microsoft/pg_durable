# AI Scenarios for pg_durable

**4 production-ready AI pipeline patterns**

Declarative AI pipelines run entirely inside PostgreSQL. You define a source table, a list of AI steps, and an optional sink table; `ai.run()` turns that definition into a durable `pg_durable` execution graph.

> Prerequisites:
> - `CREATE EXTENSION pg_durable;`
> - `CREATE EXTENSION vector;` for pgvector embeddings
> - `CREATE EXTENSION azure_ai;` for embedding and LLM calls
> - `\i sql/ai/ai_pipeline_functions.sql`

## AI Pipeline API Reference

| Function | Purpose |
|---|---|
| `ai.create_pipeline()` | Define a pipeline with source, steps, sink, and trigger |
| `ai.run()` | Manually trigger a pipeline run |
| `ai.status()` | Check pipeline status and latest run |
| `ai.explain()` | Show the generated execution plan |
| `ai.wait_for_completion()` | Block until the current run finishes |
| `ai.backfill()` | Reprocess all data from scratch |
| `ai.pause()` / `ai.resume()` | Pause or resume change-triggered runs |
| `ai.drop()` | Remove a pipeline definition and trigger |
| `ai.list_pipelines()` | List registered pipelines |

## Step Types

| Step | Purpose | Key Parameters |
|---|---|---|
| `ai.chunk()` | Split text into overlapping segments | `input_column`, `chunk_size`, `overlap` |
| `ai.embed()` | Generate vector embeddings | `model`, `input_column`, `dimensions` |
| `ai.extract()` | Extract structured fields via LLM | `model`, `input_column`, `data` |
| `ai.generate()` | Generate text via LLM | `model`, `prompt_template`, `input_column` |
| `ai.rank()` | Score or rank documents | `model`, `query_column`, `doc_column` |
| `ai.request_approval()` | Pause for human review | `content`, `notify`, `timeout` |

## Table of Contents

- [Scenario 1: Data Ingestion - Chunking and Embedding](#scenario-1-data-ingestion---chunking-and-embedding)
- [Scenario 2: Query Processing - Pre/Post LLM Orchestration](#scenario-2-query-processing---prepost-llm-orchestration)
- [Scenario 3: Human Approval - Triage with Review Gate](#scenario-3-human-approval---triage-with-review-gate)
- [Scenario 4: AI Output Governance - Versioned and Governed Results](#scenario-4-ai-output-governance---versioned-and-governed-results)

---

## Scenario 1: Data Ingestion - Chunking and Embedding

### Use This Pattern When...

> *"I'm building a RAG system and need fault-tolerant document ingestion. I want to chunk text, generate embeddings, and store vectors with metadata."*

**Business examples:**
- Document ingestion for semantic search
- Knowledge base population for chatbots
- Processing uploaded PDFs or documents for AI retrieval
- Building vector indexes from unstructured data
- Incrementally processing changed rows without re-ingesting everything

### The Problem

Traditional document ingestion fails silently:
- Embedding API calls timeout or rate-limit
- Partial ingestion leaves corrupted indexes
- No visibility into what succeeded vs failed
- Restarts mean re-processing everything

### The Solution

Define the ingestion as an AI pipeline. The source table is the system of record, `ai.chunk()` expands each document into chunks, and `ai.embed()` creates vectors. If no sink is provided, the pipeline creates `public.rag_pipeline_output` automatically.

```sql
-- ============================================================================
-- Setup: source documents
-- ============================================================================

CREATE TABLE IF NOT EXISTS documents (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO documents (title, content) VALUES
    ('Intro to pg_durable',
     'pg_durable brings durable execution to PostgreSQL. It enables fault-tolerant SQL functions that survive crashes and restarts.'),
    ('Vector embeddings',
     'Vector embeddings transform text into numerical representations for semantic search across large document collections.');

-- ============================================================================
-- Pipeline: documents -> chunks -> embeddings -> vector sink
-- ============================================================================

SELECT ai.create_pipeline(
    name   => 'rag_pipeline',
    source => ai.table_source(
        table_name => 'documents',
        incremental_column => 'updated_at'
    ),
    steps  => ARRAY[
        ai.chunk(
            input_column => 'content',
            chunk_size   => 512,
            overlap      => 64
        ),
        ai.embed(
            model        => 'text-embedding-3-small',
            input_column => 'chunk_text',
            dimensions   => 1536
        )
    ],
    trigger => 'on_change'
);

SELECT ai.explain('rag_pipeline');

-- Triggered automatically on changes, or run manually:
SELECT ai.run('rag_pipeline');
SELECT ai.wait_for_completion('rag_pipeline', 300);

SELECT doc_id, chunk_index, left(chunk_text, 80) AS preview, embedding IS NOT NULL AS has_embedding
FROM rag_pipeline_output
ORDER BY doc_id, chunk_index;
```

### How It Works

```
documents table -> ai.chunk(content) -> ai.embed(chunk_text) -> rag_pipeline_output
```

1. `ai.create_pipeline()` stores a declarative pipeline definition in `ai.pipelines`.
2. `ai.run()` builds a durable graph and starts it through `df.start()` internally.
3. The incremental checkpoint uses `documents.updated_at` to skip already-processed rows.
4. The `on_change` trigger debounces source table writes and launches new runs automatically.
5. Run history, status, and the backing durable instance are visible through `ai.status()` and `ai.result()`.

### Production: Explicit Sink and Backfill

Use an explicit sink when you want a stable table name.

```sql
CREATE TABLE IF NOT EXISTS document_vectors (
    doc_id INT,
    chunk_index INT,
    chunk_text TEXT,
    embedding vector(1536),
    extracted JSONB,
    generated TEXT,
    rank_score NUMERIC,
    metadata JSONB,
    PRIMARY KEY (doc_id, chunk_index)
);

SELECT ai.create_pipeline(
    name   => 'document_ingestion',
    source => ai.table_source('documents', incremental_column => 'updated_at'),
    steps  => ARRAY[
        ai.chunk(input_column => 'content', chunk_size => 768, overlap => 96),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text', dimensions => 1536)
    ],
    sink => ai.table_sink('document_vectors'),
    trigger => 'on_change'
);

-- Reprocess all source data after changing model, chunk size, or sink schema.
TRUNCATE document_vectors;
SELECT ai.backfill('document_ingestion');
SELECT ai.wait_for_completion('document_ingestion', 300);
```

### Ingesting from Azure Blob Storage

The current AI pipeline source implementation processes database tables. For blob storage, land fetched content into a table first, then let the AI pipeline handle chunking, embedding, checkpointing, and sink writes.

```sql
CREATE TABLE IF NOT EXISTS blob_documents (
    id SERIAL PRIMARY KEY,
    blob_url TEXT NOT NULL,
    blob_name TEXT NOT NULL,
    content TEXT NOT NULL,
    content_type TEXT,
    fetched_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Your ingestion job, COPY process, or application fetches blobs and inserts rows here.
INSERT INTO blob_documents (blob_url, blob_name, content, content_type) VALUES
    ('https://myaccount.blob.core.windows.net/documents/report.txt?...', 'report.txt', 'Fetched report content...', 'text/plain'),
    ('https://myaccount.blob.core.windows.net/documents/manual.txt?...', 'manual.txt', 'Fetched manual content...', 'text/plain');

SELECT ai.create_pipeline(
    name   => 'blob_rag_pipeline',
    source => ai.table_source('blob_documents', incremental_column => 'updated_at'),
    steps  => ARRAY[
        ai.chunk(input_column => 'content'),
        ai.embed(model => 'text-embedding-3-small', input_column => 'chunk_text', dimensions => 1536)
    ],
    trigger => 'on_change'
);

SELECT ai.run('blob_rag_pipeline');
SELECT ai.wait_for_completion('blob_rag_pipeline', 300);
```

### Verify It Worked

```sql
SELECT * FROM ai.status('rag_pipeline');
SELECT * FROM ai.result('rag_pipeline');

SELECT doc_id, chunk_index, left(chunk_text, 80) AS preview
FROM rag_pipeline_output
ORDER BY doc_id, chunk_index;

SELECT pipeline_name, last_value, last_run_at, total_processed
FROM ai.pipeline_checkpoints
WHERE pipeline_name = 'rag_pipeline';
```

---

## Scenario 2: Query Processing - Pre/Post LLM Orchestration

### Use This Pattern When...

> *"I need to validate input, route queries to different models, call an LLM, then extract and score the response."*

**Business examples:**
- RAG response generation with structured citation extraction
- Safety filtering before generation
- Multi-model routing by query complexity
- Response scoring and audit reporting

### The Problem

AI queries are not just "call the model":
- Input needs validation and classification
- Different queries need different models
- Responses need post-processing and scoring
- Failures at any stage need proper run history

### The Solution

Pipeline definitions are static, so model routing is best represented as multiple pipelines over the same source table, each with a source filter. A small SQL classifier updates the route, then each pipeline handles its own generate/extract/embed steps durably.

```sql
-- ============================================================================
-- Setup: query source and sink tables
-- ============================================================================

CREATE TABLE IF NOT EXISTS ai_queries (
    id SERIAL PRIMARY KEY,
    user_query TEXT NOT NULL,
    query_type TEXT,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_query_responses (
    id INT,
    user_query TEXT,
    query_type TEXT,
    status TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    generated TEXT,
    extracted JSONB,
    embedding vector(1536)
);

INSERT INTO ai_queries (user_query) VALUES
    ('What is pg_durable?'),
    ('Explain how durable execution helps a RAG ingestion system recover from embedding API failures.');

-- Pre-processing: classify and route in SQL.
UPDATE ai_queries
SET query_type = CASE
        WHEN length(user_query) < 80 THEN 'simple'
        ELSE 'complex'
    END,
    status = 'classified',
    updated_at = now()
WHERE status = 'pending';

-- ============================================================================
-- Pipeline A: fast path for simple queries
-- ============================================================================

SELECT ai.create_pipeline(
    name   => 'simple_query_pipeline',
    source => ai.table_source(
        table_name => 'ai_queries',
        incremental_column => 'updated_at',
        filter => 'query_type = ''simple'' AND status = ''classified'''
    ),
    steps => ARRAY[
        ai.generate(
            model => 'gpt-5-mini',
            input_column => 'user_query',
            prompt_template => 'Answer this question concisely: {user_query}',
            max_tokens => 512
        ),
        ai.extract(
            model => 'gpt-5-mini',
            input_column => 'generated',
            data => ARRAY[
                'answer: string - final answer',
                'confidence: number - confidence from 0 to 1'
            ]
        ),
        ai.embed(
            model => 'text-embedding-3-small',
            input_column => 'generated',
            dimensions => 1536
        )
    ],
    sink => ai.table_sink('ai_query_responses'),
    trigger => 'manual'
);

-- ============================================================================
-- Pipeline B: quality path for complex queries
-- ============================================================================

SELECT ai.create_pipeline(
    name   => 'complex_query_pipeline',
    source => ai.table_source(
        table_name => 'ai_queries',
        incremental_column => 'updated_at',
        filter => 'query_type = ''complex'' AND status = ''classified'''
    ),
    steps => ARRAY[
        ai.generate(
            model => 'gpt-5.2-codex',
            input_column => 'user_query',
            prompt_template => 'Give a precise technical answer with assumptions and citations where available: {user_query}',
            max_tokens => 2048
        ),
        ai.extract(
            model => 'gpt-5.2-codex',
            input_column => 'generated',
            data => ARRAY[
                'answer: string - final answer',
                'citations: array - cited sources or database objects',
                'confidence: number - confidence from 0 to 1'
            ]
        ),
        ai.embed(
            model => 'text-embedding-3-small',
            input_column => 'generated',
            dimensions => 1536
        )
    ],
    sink => ai.table_sink('ai_query_responses'),
    trigger => 'manual'
);

SELECT ai.run('simple_query_pipeline');
SELECT ai.run('complex_query_pipeline');

SELECT ai.wait_for_completion('simple_query_pipeline', 300);
SELECT ai.wait_for_completion('complex_query_pipeline', 300);
```

### How It Works

```
ai_queries -> classify route
  simple  -> simple_query_pipeline  -> generate -> extract -> ai_query_responses
  complex -> complex_query_pipeline -> generate -> extract -> embed -> ai_query_responses
```

1. SQL pre-processing classifies rows using rules you can audit and change.
2. Each pipeline has a `table_source(..., filter => ...)` route.
3. `ai.generate()` performs the LLM call.
4. `ai.extract()` stores a structured answer, citations, and confidence fields.
5. `ai.embed()` makes complex responses searchable for future reuse.

### Verify It Worked

```sql
SELECT * FROM ai.status('simple_query_pipeline');
SELECT * FROM ai.status('complex_query_pipeline');

SELECT id, query_type, left(generated, 120) AS response_preview, extracted
FROM ai_query_responses
ORDER BY id;

SELECT name, step_name, model, total_input, total_output, total_cost
FROM ai.cost_summary()
WHERE name IN ('simple_query_pipeline', 'complex_query_pipeline');
```

---

## Scenario 3: Human Approval - Triage with Review Gate

### Use This Pattern When...

> *"I want automated AI triage that pauses for a human before taking the next step."*

**Business examples:**
- Customer support triage with manager approval
- Content moderation where low-trust decisions need review
- Compliance summaries that must be reviewed before publishing
- Draft responses that should not be sent until approved

### The Problem

Fully automated AI is not always appropriate:
- Low-confidence outputs need human verification
- Compliance requires human-in-the-loop for certain decisions
- Edge cases should pause rather than guess
- Review decisions need an audit trail

### The Solution

Use `ai.request_approval()` as a first-class pipeline step. The durable run pauses until the reviewer sends the pipeline approval signal, then continues with generation, embedding, and sink writes.

```sql
-- ============================================================================
-- Setup: support tickets and work queue
-- ============================================================================

CREATE TABLE IF NOT EXISTS support_tickets (
    id SERIAL PRIMARY KEY,
    customer TEXT NOT NULL,
    product TEXT NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_work_queue (
    id INT,
    customer TEXT,
    product TEXT,
    subject TEXT,
    body TEXT,
    created_at TIMESTAMPTZ,
    extracted JSONB,
    generated TEXT,
    embedding vector(1536)
);

INSERT INTO support_tickets (customer, product, subject, body) VALUES
    ('Maria Chen', 'AcmePro Wireless Headphones', 'Left earcup stopped working',
     'The left earcup stopped producing sound after two weeks. I need a replacement or refund.'),
    ('Priya Sharma', 'AcmePro Running Shoes', 'Wrong size shipped',
     'I ordered size 8 but received size 10. I need the correct size before a marathon.');

-- ============================================================================
-- Pipeline: triage -> human approval -> draft reply -> searchable queue
-- ============================================================================

SELECT ai.create_pipeline(
    name   => 'support_triage',
    source => ai.table_source('support_tickets', incremental_column => 'created_at'),
    steps  => ARRAY[
        ai.extract(
            model        => 'gpt-4.1',
            input_column => 'body',
            data         => ARRAY[
                'sentiment: string - positive, neutral, or negative',
                'urgency: string - low, medium, high, or critical',
                'category: string - billing, product_defect, shipping, general_inquiry, or feature_request',
                'next_action: string - recommended next action for the support agent'
            ]
        ),
        ai.request_approval(
            content => 'body',
            notify  => 'support-leads',
            timeout => 3600
        ),
        ai.generate(
            model           => 'gpt-4.1',
            input_column    => 'body',
            prompt_template => 'Write a concise, empathetic draft reply. Customer: {customer}. Product: {product}. Subject: {subject}. Message: {body}',
            max_tokens      => 512
        ),
        ai.embed(
            model        => 'text-embedding-3-small',
            input_column => 'body',
            dimensions   => 1536
        )
    ],
    sink    => ai.table_sink('ticket_work_queue'),
    trigger => 'on_change'
);

SELECT ai.run('support_triage');

-- The run pauses at ai.request_approval().
SELECT * FROM ai.status('support_triage');

-- A reviewer approves the latest run.
WITH latest_run AS (
    SELECT instance_id
    FROM ai.pipeline_runs
    WHERE pipeline_name = 'support_triage'
    ORDER BY started_at DESC
    LIMIT 1
)
SELECT df.signal(instance_id, 'pipeline_support_triage_approval')
FROM latest_run;

SELECT ai.wait_for_completion('support_triage', 300);
```

### How It Works

```
support_tickets -> extract triage -> request approval -> generate draft -> embed -> ticket_work_queue
```

1. `ai.extract()` writes structured triage data into the staging batch.
2. `ai.request_approval()` maps to `df.wait_for_signal('pipeline_support_triage_approval')` internally.
3. The durable instance remains running while it waits for the signal.
4. After approval, generation and embedding continue in the same durable run.
5. The sink table becomes the reviewable work queue for agents.

### Building a Review Dashboard

```sql
-- Latest run waiting for approval.
SELECT pr.pipeline_name, pr.instance_id, pr.status, pr.started_at, df.status(pr.instance_id) AS df_status
FROM ai.pipeline_runs pr
WHERE pr.pipeline_name = 'support_triage'
ORDER BY pr.started_at DESC
LIMIT 1;

-- Triage outputs after approval.
SELECT id, customer, product,
       extracted->>'sentiment' AS sentiment,
       extracted->>'urgency' AS urgency,
       extracted->>'category' AS category,
       extracted->>'next_action' AS next_action,
       left(generated, 120) AS draft_reply_preview
FROM ticket_work_queue;
```

### Signal Pattern Reference

| Action | SQL |
|---|---|
| Find latest instance | `SELECT instance_id FROM ai.pipeline_runs WHERE pipeline_name = 'support_triage' ORDER BY started_at DESC LIMIT 1;` |
| Approve the gate | `SELECT df.signal('<instance_id>', 'pipeline_support_triage_approval');` |
| Check run status | `SELECT * FROM ai.status('support_triage');` |

---

## Scenario 4: AI Output Governance - Versioned and Governed Results

### Use This Pattern When...

> *"I need AI results treated like first-class product data: versioned, governed, and auditable, not disposable one-shot responses."*

**Business examples:**
- AI-generated product descriptions that require approval before publishing
- Compliance summaries that must be retained for audit
- Recommendation outputs tracked with provenance, scoring, and rollback
- Moderation verdicts retained with full version history

### The Problem

When AI outputs live only in the app layer, they are ephemeral:
- No version history
- No governance policy
- No provenance for model, prompt, or input
- No rollback to a previous approved result
- No single source of truth for downstream applications

### The Solution

Use an AI pipeline to generate and review candidate outputs, then promote those candidates into governed version tables. The pipeline handles durable generation and the human gate; SQL tables enforce versioning, approval state, and audit history.

```sql
-- ============================================================================
-- Setup: source products, pipeline sink, version store, and audit log
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    raw_specs TEXT NOT NULL,
    current_description_version INT,
    updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_output_candidates (
    id INT,
    name TEXT,
    raw_specs TEXT,
    current_description_version INT,
    updated_at TIMESTAMPTZ,
    generated TEXT,
    extracted JSONB
);

CREATE TABLE IF NOT EXISTS ai_outputs (
    id SERIAL PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id INT NOT NULL,
    output_type TEXT NOT NULL,
    version INT NOT NULL,
    content TEXT NOT NULL,
    model_id TEXT NOT NULL,
    prompt_hash TEXT NOT NULL,
    confidence NUMERIC(5,4),
    status TEXT NOT NULL DEFAULT 'draft',
    approved_by TEXT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    metadata JSONB DEFAULT '{}',
    UNIQUE (entity_type, entity_id, output_type, version)
);

CREATE TABLE IF NOT EXISTS ai_output_audit (
    id SERIAL PRIMARY KEY,
    output_id INT REFERENCES ai_outputs(id),
    action TEXT NOT NULL,
    actor TEXT,
    reason TEXT,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO products (name, raw_specs) VALUES
    ('Widget Pro', 'Titanium frame, 120g, waterproof IP68, 10hr battery'),
    ('Sensor Max', '0.01mm precision, -40C to 85C range, USB-C, NIST traceable');

-- ============================================================================
-- Pipeline: generate a reviewed candidate description
-- ============================================================================

SELECT ai.create_pipeline(
    name   => 'product_description_governance',
    source => ai.table_source('products', incremental_column => 'updated_at'),
    steps  => ARRAY[
        ai.generate(
            model           => 'gpt-4.1',
            input_column    => 'raw_specs',
            prompt_template => 'Write a concise product description for {name}. Specs: {raw_specs}',
            max_tokens      => 512
        ),
        ai.extract(
            model        => 'gpt-4.1',
            input_column => 'generated',
            data         => ARRAY[
                'confidence: number - confidence from 0 to 1',
                'claims: array - factual product claims made in the description',
                'review_reason: string - why this should be auto-approved or reviewed'
            ]
        ),
        ai.request_approval(
            content => 'generated',
            notify  => 'product-content-reviewers',
            timeout => 86400
        )
    ],
    sink    => ai.table_sink('ai_output_candidates'),
    trigger => 'manual'
);

SELECT ai.run('product_description_governance');

WITH latest_run AS (
    SELECT instance_id
    FROM ai.pipeline_runs
    WHERE pipeline_name = 'product_description_governance'
    ORDER BY started_at DESC
    LIMIT 1
)
SELECT df.signal(instance_id, 'pipeline_product_description_governance_approval')
FROM latest_run;

SELECT ai.wait_for_completion('product_description_governance', 300);

-- ============================================================================
-- Promote reviewed candidates into immutable versions
-- ============================================================================

WITH versioned AS (
    INSERT INTO ai_outputs (
        entity_type,
        entity_id,
        output_type,
        version,
        content,
        model_id,
        prompt_hash,
        confidence,
        status,
        approved_by,
        approved_at,
        metadata
    )
    SELECT
        'product',
        c.id,
        'description',
        COALESCE((
            SELECT max(version) + 1
            FROM ai_outputs existing
            WHERE existing.entity_type = 'product'
              AND existing.entity_id = c.id
              AND existing.output_type = 'description'
        ), 1),
        c.generated,
        'gpt-4.1',
        md5('product-description-v1:' || c.raw_specs),
        COALESCE((c.extracted->>'confidence')::numeric, 0.75),
        'approved',
        'pipeline:product_description_governance',
        now(),
        jsonb_build_object('claims', c.extracted->'claims', 'source_specs', c.raw_specs)
    FROM ai_output_candidates c
    WHERE c.generated IS NOT NULL
    RETURNING id, entity_id, version
)
INSERT INTO ai_output_audit (output_id, action, actor, reason, details)
SELECT id, 'approved', 'pipeline:product_description_governance', 'reviewed candidate promoted', jsonb_build_object('version', version)
FROM versioned;

-- Mark older approved versions as superseded after publishing the latest one.
WITH latest AS (
    SELECT entity_id, max(version) AS version
    FROM ai_outputs
    WHERE entity_type = 'product' AND output_type = 'description'
    GROUP BY entity_id
)
UPDATE ai_outputs ao
SET status = 'superseded'
FROM latest
WHERE ao.entity_type = 'product'
  AND ao.output_type = 'description'
  AND ao.entity_id = latest.entity_id
  AND ao.version < latest.version
  AND ao.status = 'approved';

UPDATE products p
SET current_description_version = latest.version,
    updated_at = now()
FROM (
    SELECT entity_id, max(version) AS version
    FROM ai_outputs
    WHERE entity_type = 'product' AND output_type = 'description' AND status = 'approved'
    GROUP BY entity_id
) latest
WHERE p.id = latest.entity_id;
```

### How It Works

```
products -> generate description -> extract governance metadata -> request approval -> ai_output_candidates
ai_output_candidates -> immutable ai_outputs versions -> ai_output_audit -> products.current_description_version
```

1. `ai.generate()` creates the governed candidate output.
2. `ai.extract()` captures confidence, claims, and review metadata.
3. `ai.request_approval()` ensures a reviewer approves before promotion.
4. Promotion SQL writes immutable versions into `ai_outputs`.
5. Audit rows record every approval and version publication.

### Why DB-Layer Control Matters

| App-layer AI | DB-layer controlled AI with pg_durable |
|---|---|
| Results vanish after response | Every output is versioned |
| No audit trail | Provenance includes model, prompt hash, confidence, and actor |
| Governance scattered in code | Review and publish state lives in tables |
| Rollback requires regeneration | Rollback points to a previous approved version |
| Hard to reproduce decisions | Inputs, outputs, and approvals are queryable |

### Rolling Back to a Previous Version

```sql
-- View all versions for a product description.
SELECT version, status, confidence, model_id, approved_by, created_at
FROM ai_outputs
WHERE entity_type = 'product' AND entity_id = 1 AND output_type = 'description'
ORDER BY version DESC;

-- Roll back product 1 to version 1.
WITH previous_current AS (
    UPDATE ai_outputs
    SET status = 'superseded'
    WHERE entity_type = 'product'
      AND entity_id = 1
      AND output_type = 'description'
      AND status = 'approved'
    RETURNING id, version
), restored AS (
    UPDATE ai_outputs
    SET status = 'approved', approved_by = 'user:admin', approved_at = now()
    WHERE entity_type = 'product'
      AND entity_id = 1
      AND output_type = 'description'
      AND version = 1
    RETURNING id, version
)
INSERT INTO ai_output_audit (output_id, action, actor, reason, details)
SELECT id, 'rolled_back', 'user:admin', 'Model regression detected', jsonb_build_object('restored_version', version)
FROM restored;

UPDATE products
SET current_description_version = 1, updated_at = now()
WHERE id = 1;
```

### Governance Dashboard Queries

```sql
-- Candidate outputs produced by the pipeline.
SELECT id, name, left(generated, 120) AS generated_preview, extracted
FROM ai_output_candidates
ORDER BY id;

-- Version history for a specific product.
SELECT ao.version, ao.status, ao.confidence, ao.model_id,
       ao.approved_by, ao.created_at, ao.approved_at,
       a.action, a.actor, a.reason, a.created_at AS audit_time
FROM ai_outputs ao
LEFT JOIN ai_output_audit a ON a.output_id = ao.id
WHERE ao.entity_type = 'product' AND ao.entity_id = 1 AND ao.output_type = 'description'
ORDER BY ao.version DESC, a.created_at;

-- Approval rate and confidence by output type.
SELECT output_type,
       COUNT(*) FILTER (WHERE status = 'approved') AS approved,
       COUNT(*) FILTER (WHERE status = 'superseded') AS superseded,
       ROUND(AVG(confidence), 4) AS avg_confidence
FROM ai_outputs
GROUP BY output_type;
```

### Verify It Worked

```sql
SELECT * FROM ai.status('product_description_governance');

SELECT entity_type, entity_id, output_type, version, status,
       confidence, model_id, approved_by, created_at
FROM ai_outputs
ORDER BY entity_type, entity_id, output_type, version;

SELECT ao.entity_type, ao.entity_id, ao.output_type, ao.version,
       a.action, a.actor, a.reason, a.created_at
FROM ai_output_audit a
JOIN ai_outputs ao ON ao.id = a.output_id
ORDER BY a.created_at;
```

---

## Next Steps

- [Database Scenarios](../SCENARIOS.md) - ETL, parallel processing, scheduling
- [User Guide](../../USER_GUIDE.md) - Complete DSL reference
- [AI Pipeline API Reference](../../sql/ai/API_REFERENCE.md) - Function signatures and lifecycle details

These patterns are production-oriented. For real deployments, add appropriate security controls, reviewer identity handling, model configuration, and monitoring.
