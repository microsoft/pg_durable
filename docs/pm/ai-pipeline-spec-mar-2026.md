# PG AI Pipelines — Specification

**Program Manager:** Abe Omorogbe | **Engineering Manager:** Krishnakumar Ravi (KK) | **Engineer:** TBD

**Status:** Draft | **Last Modified:** March 2026 | **Phase:** Phase 3 (after pg_durable + Data Pipelines)

---

## 1. What & Why

PG AI Pipelines extends the Data Pipeline runtime with AI-native operators — enabling developers to define, deploy, and monitor AI data preparation workflows entirely inside PostgreSQL. This includes chunking, embedding generation, LLM-based extraction, vector retrieval, re-ranking, and human-in-the-loop approval — all with durable execution, incremental processing, and crash recovery.

Today, building an AI data pipeline on PostgreSQL requires:

- 3–5 external services stitched together (embedding API, vector store, re-ranker, orchestrator, blob storage)
- Custom Python glue code for chunking, batching, retry, and state tracking
- No crash recovery — if an embedding batch fails at row 5,000 of 100,000, you restart from scratch
- Manual re-embedding when models change or new data arrives

PG AI Pipelines solves this by providing declarative, durable, incremental AI pipelines that run inside your database.

### Customer Problems We Need to Solve

| Pri | Problem | Why It Matters | Evidence |
|-----|---------|----------------|----------|
| 0 | RAG and AI prep pipelines are still glue-code projects | Teams must stitch together ingestion, chunking, embedding, retrieval, and generation across multiple libraries and services. | Market analysis: boilerplate-heavy RAG pipelines are the default; BMW and Walmart both describe unnecessary custom code. |
| 0 | Chunking, parsing, and multimodal prep are too bespoke | Retrieval quality depends on chunking strategy and richer content types, but most teams re-implement this logic per app. | NetApp needs auto-chunking; Eastman and SubgenAI call out images and "any type of file" as major gaps. |
| 0 | AI execution is not durable or production-safe enough | Rate limits, API failures, and long-running batches require checkpointing, retries, throttling, and cost awareness. | Market analysis highlights no durable AI workflow execution; 3Cloud rejected primitives that were harder to operationalize than SDKs. |
| 1 | Embedding sync, freshness, and backfill are fragile | When source data or models change, most teams have to re-embed manually and hope their pipelines do not drift. | Walmart needs retroactive embedding with throttling and restartability; market analysis calls out fragile embedding synchronization. |
| 2 | Advanced teams need quality loops, versioning, and approval | Production AI is not just chunk and embed; teams need evaluation, model comparison, and human review before publishing outputs. | Market analysis calls out human-in-the-loop as unserved; Opsin was looking for Data versioning on any AI generated code. |

**Customers Interested in AI Pipeline Capabilities:** See [Appendix A](#appendix-a--interested-customers)

## 2. Goals

- **AI-native pipeline operators** — chunk, embed, extract, generate, retrieve, rank, and approve as first-class pipeline steps
- **Declarative pipeline definition** — define the "what" (source, model, strategy), not the "how" (retry, batching, state). User can define once, run anywhere with pg_durable; the extension handles execution mechanics
- **Durable AI execution** — survive rate limits, API timeouts, server crashes at any step
- **Incremental + reactive** — process new/changed data automatically; backfill when model or strategy changes
- **Multi-modal extension path** — provide a credible route for PDFs, forms, charts, images, and richer document preprocessing
- **Built on Data Pipeline runtime** — reuse source, sink, state management, scheduling, and pg_durable execution
- **Extensible** — community can add custom chunking strategies, model providers, and transform operators
- **Visual pipeline designer** (VS Code monitoring only, not authoring)

### 2.2. Non-Goals

- Standard abstraction for GenAI data prep — provide a stable DSL + SDK layer above bespoke framework glue. [Out of Scope]
- Multi-database pipeline orchestration [Out of Scope]
- Training or fine-tuning models inside PostgreSQL
- Building a general-purpose AI/ML framework (not competing with LangChain/LlamaIndex)

## 3. Scope

pg_durable and AI Pipelines are separate releases with distinct scopes. AI-specific functionality (chunking, embedding, LLM calls) is purposely descoped from the pg_durable release. To mainly avoid premature customer expectations, and build the right foundations before layering more advanced capabilities.

| Product | Release Date | Scope | Interface |
|---------|-------------|-------|-----------|
| Phase 1: pg_durable | March 2026 (PrP) | General Database operation. Durable orchestration foundation | SQL Extension only |
| Phase 2: PG Data Pipelines | ?? (PuP) | State management workflows for Data processing with explicit state modeling | SQL Extension only |
| Phase 3: PG AI Pipeline | June 2026 (PrP) | AI Specifications. AI native declarative abstractions | SQL Extension only |

## 4. Functional Details

The three implementation patterns (DSL, SDK, SQL Extension) are fully detailed in the SPEC. This section shows how this will work in an SQL Extension (scope for //Build).

**AI Pipelines define intent. pg_durable executes that intent safely.**

Customers want two things:

- A DSL/SDK to define what they want to build
- A SQL/extension experience to run, manage, and trust those pipelines day‑to‑day

SDK/DSL helps customers design + build. SQL helps customers run. We need both.

These solve different problems and should be treated as complementary layers, not competing bets.

### VSCode Extension Copilot CLI — AI Pipeline [Dev Defines with Coding Agent]

Using the Azure Database Postgres Skill:

> Build me an AI pipeline in Postgres called PIPELINE_NAME. Use the DOCUMENT_TABLE table, use the EMBEDDING_MODEL.

### Python SDK — AI Pipeline [Dev Defines here in Python]

```python
# Declarative AI pipeline in python
from ai_pipeline import Pipeline, models, operators

embedding = models.AzureOpenAI(deployment="text-embedding-3-small")

pipeline = Pipeline('invoices')
pipeline.source("documents")
pipeline.chunk(column="content", strategy='sentence', max_tokens=512)
pipeline.embed(column="chunk_text", model=embedding, output='vector')
pipeline.sink("document_vectors")
pipeline.on_change("documents")
pipeline.run()  # Runs on pg_durable — no external infra
```

### SQL Extension — AI Pipeline [For DBA to read and monitor – generated by SDK]

```sql
-- Declarative AI pipeline in pure SQL
SELECT ai.create(
    name => 'rag_pipeline',
    source => ai.table_source('documents', incremental_column => 'updated_at'),
    steps => ARRAY[
        ai.chunk(column => 'content'),
        ai.embed(model => 'text-embedding-3-small', column => 'chunk_text')
    ],
    sink => ai.table_sink('document_vectors'),
    trigger => 'on_change'
);

-- Monitor the AI pipeline
SELECT * FROM ai.status('rag_pipeline');
```

Details in [Appendix B](#appendix-b-sample-pipeline-definition-with-details)

## 5. AI Pipeline Operators

These operators extend the Data Pipeline runtime with AI-specific capabilities. They run on pg_durable and inherit durable execution, checkpointing, and crash recovery.

### Core Operators (P0)

| Operator | Parameters | Description | Customer Need |
|----------|-----------|-------------|---------------|
| `ai.chunk(column, method, chunk_size, overlap)` | column: text column to chunk. method: 'recursive', 'sentence', 'token', 'paragraph'. chunk_size: max tokens per chunk. overlap: token overlap between chunks. | Split documents into chunks. Produces 1→N row expansion. | All RAG customers |
| `ai.create_embeddings` | See azure_ai | See azure_ai | All RAG customers |
| `ai.extract` | See Semantic Operators | See Semantic Operators | SATS Ltd (entity extraction from flight data), DHS (email metadata) |
| `ai.generate` | See Semantic Operators | See Semantic Operators | DHS, Sompo (claims analysis), EY.AI (agent marketplace) |

### Extended Operators (P1)

| Operator | Parameters | Description | Customer Need |
|----------|-----------|-------------|---------------|
| `ai.rank(model, query_column, doc_column, top_k)` | See Semantic Operators | See Semantic Operators | HLS/Incyte (Cohere rerank), Truveta (Hugging Face), EY.AI, Insight Global |
| `ai.search(index, query_column, top_k)` | index: vector index name. query_column: query text or embedding. top_k: number of results. | Batch vector similarity search. For pipelines that need retrieval as a step. | Freeport-McMoRan (enterprise search), DHS (email search) |
| `ai.request_approval(content, notify, timeout)` | content: column with data to review. notify: email/webhook endpoint. timeout: max wait time. | Pause pipeline for human review. Resume on approve/reject signal. | No direct customer ask yet — but proactive for regulated industries (HLS, UBS, Legora compliance) |
| `ai.parse_document(source, format, options)` | source: file/blob column or URI. format: pdf, docx, pptx, image, html, form. | Extract structured content from richer inputs before chunking and embedding. | Eastman (images / diagrams), RAND (forms), SubgenAI ("any type of file"), PIMCO |

### Future Operators (P2)

| Operator | Parameters | Description | Customer Need |
|----------|-----------|-------------|---------------|
| `ai.evaluate(metric_set, dataset)` | metric_set: dataset: | Run evaluation metrics over pipeline outputs and retrieval quality | Eastman, PIMCO, SubgenAI want quality loops, not only mechanics |

## 6. AI Pipeline Use Cases

### Customer Jobs to Be Done

| Pri | Job | User Story | Success Looks Like |
|-----|-----|------------|-------------------|
| 0 | Declarative RAG setup | "Define my source, chunking strategy, embedding model, and target tables once, and keep them in sync automatically." | A single pipeline definition owns chunking, embedding, sync, and monitoring. |
| 0 | Incremental AI processing on change | "When a new or updated document lands, automatically parse, chunk, embed, and enrich only what changed." | Freshness is built-in rather than re-created in app code. |
| 1 | Bulk AI enrichment at scale | "Run embeddings, extraction, and metadata enrichment across large existing datasets with checkpointing and retry." | Large backfills survive rate limits and resume after failures. |
| 1 | Multi-modal enterprise ingestion | "Handle PDFs, slides, images, forms, and other enterprise formats before retrieval or indexing." | Pipelines support parsing and metadata normalization before chunking/embedding. |

### Use Case 1: RAG Pipeline + Chunking (P0)

**Pattern:** Documents Table → Chunk → Embed → Store

**Customers:** Walmart, NetApp, Legora, Sompo, Nasdaq

```sql
-- Declarative AI pipeline in pure SQL
SELECT ai.create(
    name => 'rag_pipeline',
    source => ai.table_source('documents', incremental_column => 'updated_at'),
    steps => ARRAY[
        ai.chunk(column => 'content'),
        ai.embed(model => 'text-embedding-3-small', column => 'chunk_text')
    ],
    sink => ai.table_sink('document_vectors'),
    trigger => 'on_change'
);

-- Monitor the AI pipeline
SELECT * FROM ai.status('rag_pipeline');
```

### Use Case 1B: Multi-Modal RAG Pipeline + Chunking (P1)

**Pattern:** Unstructured Data → parse → Use Case 1A [Documents Table → Chunk → Embed → Store]

**Customers:** Eastman, RAND, PIMCO, SubgenAI

```sql
-- Declarative AI pipeline in pure SQL
SELECT ai.create(
    name => 'unstructured_rag_pipeline',
    source => ai.file_source('blob://enterprise-dropbox/', formats => ARRAY['pdf', 'pptx', 'png', 'jpg']),
    steps => ARRAY[
        ai.parse_document(source => 'file_uri', format => 'auto'),
        ai.chunk(column => 'parsed_text'),
        ai.embed(model => 'text-embedding-3-small', column => 'chunk_text')
    ],
    sink => ai.table_sink('multimodel_vectors'),
    trigger => 'on_change'
);

-- Monitor the AI pipeline
SELECT * FROM ai.status('unstructured_rag_pipeline');
```

### Use Case 2: Bulk Data Ingestions with Feature Extractions (P0)

**Pattern:** Products → Embed + Extract Features → Store

**Customers:** Walmart (300M products), RefiBuy (e-commerce catalog), SaxoBank (recommender)

```sql
-- Declarative AI pipeline in pure SQL
SELECT ai.create(
    name => 'product_enrichment',
    source => ai.table_source('products', incremental_column => 'updated_at'),
    steps => ARRAY[
        ai.embed(model => 'text-embedding-3-small', input => 'description',
                 batch_size => 200),
        ai.extract(model => 'gpt-4o', input => 'description',
                   data => ARRAY[
                       'category: Product category',
                       'brand: Brand name',
                       'key_features: Top 3 features as JSON array'])
    ],
    sink => ai.table_sink('document_vectors',
                on_conflict => ARRAY['product_id'],
                on_conflict_action => 'update'),
    trigger => 'on_change'
);

-- Monitor the AI pipeline
SELECT * FROM ai.status('product_enrichment');
```

## 7. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Azure AI extension growth | Accelerate from +15% to +40%+ per semester | TPID adoption tracking |
| Pipeline adoption | 100+ TPIDs within 6 months of launch | New telemetry for AI pipeline usage |
| Time-to-first-pipeline | < 30 minutes from docs to working pipeline | User study + onboarding funnel |
| Customer unblock | Walmart, Esposure4all, NetApp using AI pipelines in production | Named customer tracking |
| Consolidation displacement | 5+ customers replacing external AI pipeline services | Customer interview validation |
| Design-partner validation | Positive rollout feedback from Avanade, Eastman, PIMCO, Incyte, Saxo Bank, and UBS | Partner validation against the Nitro discovery cohort |

## 8. Relationship to Data Pipelines & pg_durable

| Layer | Details |
|-------|---------|
| **AI Pipelines (Phase 3) — THIS SPEC** | `ai.chunk`, `ai.embed`, `ai.extract`, `ai.generate`, `ai.rank`, `ai.search`, `ai.request_approval` (new) — AI abstractions |
| **Data Pipelines (Phase 2)** | `dp.create`, `dp.table_source`, `dp.table_sink`, `dp.sql`, `dp.status`, `dp.backfill`, `dp.schedule` — State management, incremental tracking, monitoring |
| **pg_durable (Phase 1) — SHIPPING MARCH 2026** | `df.start`, `df.sql`, `df.if`, `df.loop`, `df.sleep` — Durable execution, crash recovery, replay. Operators: `~>` (seq), `&` (parallel), `\|=>` (name) — Pipeline orchestration |
| **PostgreSQL + azure_ai (expanded)** | pgvector, DiskANN, AGE, pg_cron. azure_ai: semantic operators (generate, is_true, extract, rank, search, embed) + auto embeddings + bulk generation — AI functions |

## Open Questions for Engineering

| # | Question | Options | Impact |
|---|----------|---------|--------|
| 1 | Which implementation pattern to build first? | DSL, SDK, SQL Extension, or layered approach? | Customer signal favors SQL Extension first. |
| 2 | Where does chunking logic run? | In Postgres (Rust extension), in Python background worker, or call external service? | Affects performance and deployment model. pgrag runs local ONNX models; pgai uses external workers. |
| 3 | How to handle 1→N row expansion from chunking? | Temporary table, set-returning function, or pipeline-internal buffer? | Core architectural decision for the `ai.chunk` operator. |
| 4 | Should we support local embedding models? | ONNX in-process (like pgrag), or Azure OpenAI/external API only? | Local models = zero API cost, works offline. But adds binary size and GPU concerns. |
| 5 | How does cost tracking integrate with APIM? | Extension tracks tokens internally, or delegate to APIM? | EY.AI already uses APIM for 8-10 models. Need to decide if we complement or replace. |
| 6 | What's the backfill strategy for 300M rows? | Parallel workers, batched with throttling, or offload to Container App? | Walmart's scale (300M embeddings) is the bar for production-ready. |
| 7 | How do we handle model credential management? | Managed Identity (customer requirement), extension config, or AIMM integration? | Freeport: MI is "must-have". UK Defence: "only managed identities allowed". |
| 8 | What is the launch relationship between AI Pipelines DSL and UQL? | Separate stories, shared grammar, or UQL as a superset? | Nitro report says the UQL expectation is growing faster than the current proposal reflects. |
| 9 | How far do auth / RLS propagation go in v1? | Pipeline-level identity, on-behalf-of execution, or integration hooks only? | Incyte, Eastman, UBS, and Saxo Bank make this an adoption criterion, not a nice-to-have. |
| 10 | How opinionated should managed execution be? | Extension-only, container-hosted helper, or managed service control plane? | Customers want something simpler than MCP / framework glue, but expectations vary. |
| 11 | What quality loop belongs in the first release? | Metrics only, evaluation datasets, approval gates, or full version comparison? | Eastman, PIMCO, and SubgenAI will evaluate the feature as part of a quality system, not just an ingest engine. |

**See also:**

- PG Data Pipelines Spec — Phase 2 specification with shared implementation pattern analysis
- Market Analysis — Competitive landscape and positioning
- pg_durable One-Pager — Phase 1 durable execution runtime
- AI Pipelines 1-Pager — Original vision document

---

## Appendix A – Interested Customers

| Customer | What They Need | Current Workaround |
|----------|---------------|-------------------|
| Walmart | Retroactive embedding on existing tables with throttling, restartability, error handling | Manual embedding pipeline outside Postgres |
| Esposure4all | Real-time embedding workflows for gamified learning content (5M embeddings) | External Python pipeline |
| NetApp | Auto-chunking of large documents for knowledge base "Neo" (12B docs) | Manual chunking in application code |
| HLS/Incyte | Re-ranking inside database + Cohere rerank-v4 support | Cohere on external service (hitting endpoint errors) |
| Truveta | Hybrid search + re-ranking for healthcare chatbot | Hugging Face on AKS + custom Elasticsearch |
| EY.AI | Agent marketplace with vectorized documents (50+ Flex servers) | Custom pipeline, IVFFLAT → DiskANN migration |
| DHS | NL→SQL/vector/graph routing over 10K+ emails | External LLM orchestration |
| Sompo | RAG on millions of insurance claims documents | Azure AI Search (cost concern) |
| Nasdaq | Board meeting document AI search | Azure AI Search (cross-region replication gaps) |
| Freeport-McMoRan | Enterprise search over 40K employees, 14B data points/day | AI Search + Redis + Cosmos DB → consolidating to Postgres |

## Appendix B: Sample Pipeline Definition with Details

```sql
-- Declarative AI pipeline in pure SQL
SELECT dp.create(
    name => 'knowledge_base_ingestion',
    source => dp.table_source('documents', incremental_column => 'updated_at'),
    steps => ARRAY[
        -- Step 1: Chunk documents
        ai.chunk(
            column => 'content',
            method => 'recursive',
            chunk_size => 512,
            overlap => 64
        ),
        -- Step 2: Generate embeddings
        ai.embed(
            model => 'text-embedding-3-small',
            column => 'chunk_text',
            batch_size => 100,
            retry => 3,
            backoff => 'exponential'
        ),
        -- Step 3: Extract metadata using LLM
        ai.extract(
            model => 'gpt-4o',
            column => 'chunk_text',
            fields => jsonb_build_object(
                'category', 'Document category',
                'summary', 'One-sentence summary'
            )
        )
    ],
    sink => dp.table_sink('knowledge_vectors',
                columns => ARRAY['doc_id', 'chunk_index', 'chunk_text',
                                  'embedding', 'category', 'summary']),
    trigger => 'on_change',
    options => jsonb_build_object(
        'throttle_rps', 100,
        'error_handling', 'retry_then_skip',
        'checkpoint', 'per_batch',
        'cost_tracking', true
    )
);

-- Monitor the AI pipeline
SELECT * FROM dp.status('knowledge_base_ingestion');
```

### Comparison to pgai Vectorizer

| Aspect | pgai Vectorizer (Timescale) | PG AI Pipelines (Ours) |
|--------|---------------------------|----------------------|
| Setup | `SELECT ai.create_vectorizer(...)` | `SELECT dp.create(... steps => ARRAY[ai.chunk(), ai.embed(), ...])` |
| Scope | Embedding sync only | Full pipeline: chunk → embed → extract → store |
| Chunking | `ai.chunking_default(chunk_size, overlap)` | `ai.chunk(method => 'recursive', chunk_size, overlap)` |
| LLM calls | ❌ Not supported | ✅ `ai.extract()`, `ai.generate()` |
| Composition | Single vectorizer per table | Multi-step pipeline with any combination of operators |
| Durability | Background worker with retry | Full durable execution (pg_durable crash recovery) |
| Incremental | Trigger-based sync | Trigger + cursor + backfill support |
| Throttling | ❌ | ✅ `throttle_rps` option |
| Cost tracking | ❌ | ✅ `dp.cost_log` table |
| Human approval | ❌ | ✅ `ai.request_approval()` |
| Re-ranking | ❌ | ✅ `ai.rerank()` |
| Custom operators | ❌ | ✅ Extensible operator interface |

## Appendix C: Competitive Positioning

### vs. pgai Vectorizer (Timescale)

pgai Vectorizer is the closest competitor. It does one thing well: keep embeddings synced with a source table. We differentiate by:

- Multi-step pipeline composition (chunk → embed → extract → rank — not just embed)
- Durable execution with crash recovery (pgai has retry but not durable replay)
- Throttling and cost tracking (production safety features missing from pgai)
- Human-in-the-loop approval (completely absent)
- LLM-based extraction and generation operators (pgai is embedding-only)

### vs. pgrag (Neon)

pgrag provides RAG building blocks as SQL functions. We differentiate by:

- Pipeline abstraction (pgrag is individual function calls, not composable pipelines)
- Incremental processing (pgrag has no state management — reprocesses everything)
- Durable execution (no crash recovery in pgrag)
- Scale (pgrag is single-document-at-a-time; we support batch processing)

### vs. AlloyDB AI (Google Cloud)

AlloyDB has strong in-database AI functions via `google_ml_integration`, and its newer GA features make the simple case better: auto vector embeddings reduce single-table sync work, bulk embedding generation and refresh improve throughput, and SQL AI functions make inline enrichment easier. Our differentiation is not that AlloyDB cannot do AI in SQL. It is that AlloyDB mainly strengthens AI primitives and vector lifecycle automation, while PG AI Pipelines targets the broader pipeline layer. We differentiate by:

- Multi-step pipeline abstraction that spans parse → chunk → embed → extract → retrieve → rank → approve, not just table-local SQL calls or embedding maintenance
- Durable execution with checkpointing and replay for long-running backfills and failure recovery
- Governed reprocessing when models, prompts, or chunking logic change
- Multi-source and multi-modal ingestion before embeddings exist
- Cloud-agnostic deployment rather than a Google Cloud-specific feature set
- Open source extensibility rather than a proprietary extension surface

### vs. LangChain / LlamaIndex

These are the most common external orchestration approaches. We differentiate by:

- Zero data movement — processing happens where data lives
- Built-in state management and crash recovery
- Incremental processing — only new/changed data
- No Python runtime needed for simple pipelines
- Production safety (throttling, retry, cost tracking) out of the box
- A stable standard abstraction above framework churn — closer to the "ODBC for GenAI" expectation PIMCO described
