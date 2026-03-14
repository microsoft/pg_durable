# durable-korvus Architecture

> **Status:** 🚧 Design/Planning Phase. This document describes the intended architecture; implementation has not yet begun. Design decisions are subject to change as prototyping reveals constraints.

## Table of Contents

- [Overview](#overview)
- [Component Diagram](#component-diagram)
- [Ingestion Path](#ingestion-path)
  - [Sync Ingestion Flow](#sync-ingestion-flow)
  - [Async Ingestion Flow](#async-ingestion-flow)
  - [pg_durable Workflow Graph](#pg_durable-workflow-graph)
- [Search Path](#search-path)
- [Module Structure](#module-structure)
- [Key Design Decisions](#key-design-decisions)
  - [ADR-1: Embedding calls via pg_durable df.http(), not direct HTTP](#adr-1-embedding-calls-via-pg_durable-dfhttp-not-direct-http)
  - [ADR-2: pgvector for vector storage, not PostgresML](#adr-2-pgvector-for-vector-storage-not-postgresml)
  - [ADR-3: Per-pipeline embedding tables](#adr-3-per-pipeline-embedding-tables)
  - [ADR-4: Stable chunk IDs via content hash](#adr-4-stable-chunk-ids-via-content-hash)
  - [ADR-5: Sequential batch embedding (initial implementation)](#adr-5-sequential-batch-embedding-initial-implementation)
  - [ADR-6: API key via environment variable only](#adr-6-api-key-via-environment-variable-only)
- [Schema Design](#schema-design)
- [Korvus Compatibility Analysis](#korvus-compatibility-analysis)
- [Extension Points](#extension-points)
- [Dependency Graph](#dependency-graph)
- [Failure Modes and Recovery](#failure-modes-and-recovery)

---

## Overview

`durable-korvus` is a pure Rust library crate (no PostgreSQL extension code). It connects to PostgreSQL as a client using `sqlx` and submits `pg_durable` workflow DSL strings via SQL function calls. The heavy lifting — embedding API calls, retry logic, durability — is performed by the `pg_durable` background worker inside PostgreSQL.

```
Your Application (Rust)
       │
       │  tokio / async
       ▼
┌─────────────────────────┐
│   durable-korvus crate  │
│   (Client, Collection,  │
│    Pipeline, Search)    │
└───────────┬─────────────┘
            │ sqlx (async PostgreSQL)
            ▼
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Server                         │
│                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────────┐  │
│  │  pg_durable  │   │   pgvector   │   │  Collection     │  │
│  │  extension   │   │  extension   │   │  tables         │  │
│  │  (df schema) │   │  (vector     │   │  (*_documents,  │  │
│  │              │   │   type, ops) │   │   *_chunks,     │  │
│  │  df.start()  │   │              │   │   *_embeddings, │  │
│  │  df.status() │   │  HNSW index  │   │   *_pipelines)  │  │
│  │  df.sql()    │   │              │   │                 │  │
│  │  df.http()   │   │              │   │                 │  │
│  └──────┬───────┘   └──────────────┘   └─────────────────┘  │
│         │                                                     │
│  ┌──────▼───────────────────┐                                 │
│  │  pg_durable background   │  HTTPS  ┌───────────────────┐  │
│  │  worker (duroxide)       │────────►│  Embedding API    │  │
│  │                          │◄────────│  (OpenAI/Azure/…) │  │
│  │  Executes df.http() nodes│         └───────────────────┘  │
│  └──────────────────────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Diagram

```
durable-korvus crate
│
├── client.rs          Client — PostgreSQL connection, collection factory
├── collection.rs      Collection — CRUD, upsert, search
├── document.rs        Document — struct and validation
├── pipeline.rs        Pipeline, PipelineConfig — chunker + embedding config
├── embeddings.rs      EmbeddingConfig — provider abstraction, request/response types
├── chunker.rs         ChunkerConfig, chunking logic (FixedSize, UserProvided)
├── search.rs          SearchResult, search query building
├── schema.rs          DDL generation, table creation/migration
├── workflow.rs        pg_durable DSL string construction, df.start(), df.status() polling
├── error.rs           Error enum
└── lib.rs             Public API re-exports
```

---

## Ingestion Path

### Sync Ingestion Flow

```
Application                durable-korvus             PostgreSQL
     │                          │                          │
     │  upsert_documents(       │                          │
     │    docs, pipeline,       │                          │
     │    Sync)                 │                          │
     │─────────────────────────►│                          │
     │                          │  INSERT INTO *_documents │
     │                          │─────────────────────────►│
     │                          │  DELETE+INSERT *_chunks  │
     │                          │─────────────────────────►│
     │                          │  df.start(workflow)      │
     │                          │─────────────────────────►│
     │                          │◄─── instance_id ─────────│
     │                          │                          │
     │                          │  poll df.status()        │
     │                          │─────────────────────────►│
     │                          │◄─── "running" ───────────│
     │                          │  (repeat every 100ms)    │
     │                          │                          │
     │                          │         [background worker executes workflow]
     │                          │         [calls embedding API via df.http()]
     │                          │         [writes vectors to *_embeddings]
     │                          │                          │
     │                          │  poll df.status()        │
     │                          │─────────────────────────►│
     │                          │◄─── "completed" ─────────│
     │                          │                          │
     │◄── Ok(UpsertResult) ─────│                          │
```

### Async Ingestion Flow

```
Application                durable-korvus             PostgreSQL
     │                          │                          │
     │  upsert_documents(       │                          │
     │    docs, pipeline,       │                          │
     │    Async)                │                          │
     │─────────────────────────►│                          │
     │                          │  INSERT INTO *_documents │
     │                          │─────────────────────────►│
     │                          │  DELETE+INSERT *_chunks  │
     │                          │─────────────────────────►│
     │                          │  df.start(workflow)      │
     │                          │─────────────────────────►│
     │                          │◄─── instance_id ─────────│
     │◄── Ok(UpsertResult) ─────│                          │
     │    { instance_id, ... }  │                          │
     │                          │                          │
     │  (returns immediately)   │         [background worker continues async]
```

### pg_durable Workflow Graph

For a document batch producing 3 embedding batches:

```
df.start(
    df.sql("INSERT ... chunks, DELETE old embeddings")
    ~> df.http(embed_batch_0)
    ~> df.sql("INSERT INTO *_embeddings batch_0_vectors")
    ~> df.http(embed_batch_1)
    ~> df.sql("INSERT INTO *_embeddings batch_1_vectors")
    ~> df.http(embed_batch_2)
    ~> df.sql("INSERT INTO *_embeddings batch_2_vectors")
    ~> df.sql("UPDATE ingestion status = complete")
)
```

Each `df.http()` call is a node in the workflow graph. The `~>` (sequence) operator ensures each step only runs after the previous one completes. If the server crashes after step 3 completes, the workflow resumes from step 4.

```
[chunks]──►[embed_0]──►[store_0]──►[embed_1]──►[store_1]──►[embed_2]──►[store_2]──►[done]
              │                       │                       │
              │  df.http()            │  df.http()            │  df.http()
              └──► Embedding API      └──► Embedding API      └──► Embedding API
```

**Future (v0.2):** Parallel batch execution using `&` operator:

```
[chunks]──►[embed_0 & embed_1 & embed_2]──►[store_all]──►[done]
```

---

## Search Path

Search is a synchronous operation. The query string is embedded via a single `df.http()` call (short-lived workflow, awaited synchronously), then a similarity search query is executed.

```
Application          durable-korvus           PostgreSQL
     │                    │                       │
     │  search(query,     │                       │
     │   pipeline, k,     │                       │
     │   filter)          │                       │
     │───────────────────►│                       │
     │                    │  df.start(            │
     │                    │    df.http(embed_q))  │
     │                    │──────────────────────►│
     │                    │◄── instance_id ───────│
     │                    │                       │
     │                    │  poll df.status()     │
     │                    │  (embedding done)     │
     │                    │──────────────────────►│
     │                    │◄── "completed" ───────│
     │                    │                       │
     │                    │  df.result(instance)  │
     │                    │──────────────────────►│
     │                    │◄── query_vector ──────│
     │                    │                       │
     │                    │  SELECT ... <=> ...   │
     │                    │  ORDER BY cosine dist │
     │                    │  LIMIT k              │
     │                    │──────────────────────►│
     │                    │◄── rows ──────────────│
     │◄── Vec<SearchResult│                       │
```

> **Open Question (ADR candidate):** Using a single-node workflow for query embedding adds round-trip overhead. A future optimization could cache query embeddings or allow a direct `reqwest` call for search (where durability is not required). This trade-off needs benchmarking.

---

## Module Structure

### `src/lib.rs`
Public API re-exports. All user-facing types are exported from the crate root.

### `src/client.rs`
- Holds the `sqlx::PgPool` connection pool.
- `collection(name)` validates the name, creates tables (via `schema.rs`), registers in `_dk_collections`, returns a `Collection`.
- `list_collections()` queries `_dk_collections`.

### `src/collection.rs`
Core user-facing logic:
- `upsert_documents()`: orchestrates document/chunk insertion and workflow submission.
- `search()`: embeds query, runs similarity SQL.
- `add_pipeline()` / `list_pipelines()` / `remove_pipeline()`.
- `delete_documents()`, `get_document()`, `delete()`.

### `src/document.rs`
Simple `Document` struct with `id`, `content`, `metadata`. Validation: non-empty id and content.

### `src/pipeline.rs`
`Pipeline` and `PipelineConfig` types. Serialization to/from JSONB for storage in `*_pipelines` table.

### `src/embeddings.rs`
- `EmbeddingConfig` type.
- `build_embedding_request(chunks, config)` → JSON body for `df.http()`.
- `parse_embedding_response(json)` → `Vec<Vec<f32>>`.
- Dimension validation logic.

### `src/chunker.rs`
- `ChunkerConfig` enum.
- `chunk(content, config)` → `Vec<(usize, String)>` (index, text).
- Fixed-size chunker implementation.

### `src/search.rs`
- `SearchResult` struct.
- `build_search_sql(collection_name, pipeline_name, k, filter)` → parameterized SQL string.

### `src/schema.rs`
- `create_collection_tables(pool, name)` → executes DDL.
- `drop_collection_tables(pool, name)` → DROP TABLE CASCADE.
- DDL strings for all four table types.

### `src/workflow.rs`
- `build_ingestion_workflow(chunks, config)` → pg_durable DSL expression string.
- `submit_workflow(pool, dsl)` → calls `df.start()` via `sqlx`, returns `instance_id`.
- `poll_workflow(pool, instance_id, timeout, interval)` → polls `df.status()` for Sync mode.

### `src/error.rs`
- `Error` enum (see [SPEC.md](SPEC.md#error-handling)).

---

## Key Design Decisions

### ADR-1: Embedding calls via pg_durable df.http(), not direct HTTP

**Context:** Embedding API calls during ingestion can fail due to network issues, rate limits, or provider outages. If the application calls the embedding API directly and then crashes, partially-embedded documents are left in an inconsistent state.

**Decision:** All embedding API calls are submitted as `df.http()` nodes in a `pg_durable` workflow. The background worker executes these calls with built-in retry and checkpointing.

**Consequences:**
- ✅ Full durability: embedding resumes after any crash.
- ✅ Automatic retry on 5xx / network errors.
- ✅ SSRF protection via pg_durable's built-in IP blocklist.
- ⚠️ Added latency: at least one extra round-trip to PostgreSQL per embedding batch.
- ⚠️ Requires pg_durable background worker to be running.
- ⚠️ Search query embedding also goes through this path (see Open Questions in SPEC.md).

**Alternatives rejected:**
- Direct `reqwest` calls from the Rust client: faster, but no durability.
- `pgai` / Azure AI extension: vendor-specific; doesn't work with arbitrary OpenAI-compatible endpoints.

---

### ADR-2: pgvector for vector storage, not PostgresML

**Context:** Korvus uses PostgresML for both embedding generation and vector storage. PostgresML is a large extension with significant infrastructure requirements. `durable-korvus` targets users who want vector search without the full PostgresML stack.

**Decision:** Use `pgvector` for vector storage and similarity search. It is a widely-deployed, well-maintained extension with minimal infrastructure overhead.

**Consequences:**
- ✅ No PostgresML dependency.
- ✅ Standard HNSW index via `CREATE INDEX USING hnsw`.
- ✅ Works on any standard PostgreSQL deployment with pgvector.
- ⚠️ Users must install pgvector separately (but it is available on most hosted PostgreSQL platforms).

---

### ADR-3: Per-pipeline embedding tables

**Context:** Each pipeline may have a different embedding dimension (e.g., 1536 for `text-embedding-3-small`, 3072 for `text-embedding-3-large`). A single `<name>_embeddings` table with a fixed `vector(<N>)` column cannot accommodate pipelines with different dimensions.

**Decision:** Use a separate embeddings table per pipeline: `<name>_embeddings_<pipeline_name>`. Each table has a `vector(<N>)` column sized to that pipeline's dimension. The HNSW index is also per-table.

**Consequences:**
- ✅ Supports multiple pipelines with different dimensions on the same collection.
- ✅ Each HNSW index is properly typed.
- ⚠️ More tables per collection; schema is slightly more complex.
- ⚠️ `list_pipelines()` must enumerate these tables.


---

### ADR-4: Stable chunk IDs via content hash

**Context:** When a document is re-upserted, we need to delete old chunks and embeddings and replace them. During workflow retry after a crash, we need to avoid double-inserting embeddings.

**Decision:** Chunk IDs are computed as `sha256(collection/doc_id/pipeline/chunk_index)` truncated to 32 hex characters. This is deterministic and stable across retries.

**Consequences:**
- ✅ `INSERT ... ON CONFLICT DO NOTHING` on embeddings is safe to retry.
- ✅ No UUIDs to store or coordinate.
- ⚠️ Chunk ID changes if document id, collection name, pipeline name, or chunk index changes (which is correct behavior — those are different chunks).

---

### ADR-5: Sequential batch embedding (initial implementation)

**Context:** A large document batch may produce many embedding API calls. These could be parallelized using `pg_durable`'s `&` operator to reduce total time. However, parallel execution is more complex to implement and reason about for retry semantics.

**Decision:** Initial implementation uses sequential batch embedding (`~>` operator only). Parallelism may be added in a future version after benchmarking.

**Consequences:**
- ✅ Simpler workflow graph.
- ✅ Easier to reason about retry semantics.
- ⚠️ Slower for large batches (linear time in number of batches).

---

### ADR-6: API key via environment variable only

**Context:** Embedding API keys are secrets that must not be stored in the database. Options include: environment variables, PostgreSQL secrets table (encrypted), or external secret stores.

**Decision:** API keys are read from named environment variables at workflow execution time by the `pg_durable` background worker process. No other secret storage mechanism is supported in v0.1.

**Consequences:**
- ✅ Simple; no additional infrastructure required.
- ✅ Keys never enter the database.
- ⚠️ Requires the environment variable to be set on the PostgreSQL server process.
- ⚠️ Key rotation requires restarting the background worker (or using a dynamic secrets approach in a future version).

---

## Schema Design

### Entity Relationship Diagram

```
_dk_collections
    │ name (PK)
    │
    ├── <name>_pipelines
    │       │ name (PK)
    │       │ config (JSONB)
    │
    ├── <name>_documents
    │       │ id (PK)
    │       │ content
    │       │ metadata (JSONB)
    │
    └── <name>_chunks
            │ chunk_id (PK)
            │ document_id (FK → *_documents.id)
            │ pipeline
            │ chunk_index
            │ chunk_text
            │
            └── <name>_embeddings_<pipeline>
                    │ chunk_id (PK, FK → *_chunks.chunk_id)
                    │ embedding vector(N)
                    │ (HNSW index)
```

### Notes

- All FK relationships use `ON DELETE CASCADE` so deleting a document automatically removes its chunks and embeddings.
- The `_dk_collections` table is the single source of truth for collection discovery.
- Pipeline configs are stored as JSONB in `*_pipelines` to support future config schema evolution.

---

## Korvus Compatibility Analysis

The following table shows where `durable-korvus` matches Korvus semantics exactly, where it differs, and where it is a superset.

| Korvus Feature | durable-korvus | Status |
|----------------|----------------|--------|
| `Collection::new(name, None)` | `client.collection(name).await` | ✅ Compatible (different syntax) |
| `collection.upsert_documents(docs)` | `collection.upsert_documents(docs, pipeline, mode).await` | ✅ Compatible (pipeline explicit) |
| `collection.get_pipelines()` | `collection.list_pipelines()` | ✅ Compatible (renamed) |
| `collection.vector_search(query, pipeline)` | `collection.search(query, pipeline, k, filter)` | ✅ Compatible (k + filter explicit) |
| `pgml.embed()` via PostgresML | `df.http()` via pg_durable | ✅ Equivalent (OpenAI-compat) |
| HNSW/IVFFlat index selection | HNSW only (v0.1) | ⚠️ Subset |
| Pipeline YAML config | `PipelineConfig` Rust struct | ⚠️ Different format |
| Reranking | Not in v0.1 | ❌ Not supported |
| Hybrid search | Not in v0.1 | ❌ Not supported |
| Durable/fault-tolerant ingestion | ✅ Core feature | 🆕 New capability |

---

## Extension Points

The following extension points are designed into the API to support future enhancements without breaking changes:

1. **Chunker variants:** `ChunkerConfig` is an enum; new variants (e.g., `SentenceAware`, `TokenBased`) can be added without changing the `upsert_documents` signature.

2. **Embedding providers:** `EmbeddingConfig` is a struct with a URL field; any OpenAI-compatible endpoint works. A future `EmbeddingProvider` trait could support non-HTTP providers.

3. **Search modes:** `search()` currently supports vector similarity only. A `SearchMode` enum parameter can be added for hybrid search without breaking the existing signature.

4. **Metadata filters:** Currently uses JSONB `@>` operator. A `Filter` enum could provide richer predicates in the future.

5. **Pipeline parallelism:** The `IngestMode::Async` path already submits workflows; making batches parallel is purely an internal change to `workflow.rs`.

---

## Dependency Graph

```
durable-korvus
│
├── sqlx 0.8          (async PostgreSQL client)
├── tokio 1.x         (async runtime)
├── serde 1.x         (serialization)
├── serde_json 1.x    (JSON)
├── uuid 1.x          (chunk ID generation — possibly replaced by sha256)
├── sha2              (stable chunk ID hashing)
├── thiserror 1.x     (error derive macro)
└── (test-only) tokio-test, sqlx with test feature
```

**Runtime dependencies on PostgreSQL extensions:**
- `pg_durable` ≥ 0.2.0 (must be in `shared_preload_libraries`)
- `pgvector` ≥ 0.7 (must be installed)

**No compile-time dependency on pg_durable source** — `durable-korvus` is a pure client library that calls `pg_durable` via SQL.

---

## Failure Modes and Recovery

| Failure Scenario | Effect | Recovery |
|------------------|--------|----------|
| Application crash during `upsert_documents` (before `df.start()`) | Chunks written to DB but no workflow submitted. Documents in `*_documents` are current; chunks are in `*_chunks` but have no embeddings. | Next upsert of same document will re-chunk and re-submit workflow. |
| Application crash after `df.start()` (Async mode) | Workflow is running in background; embeddings will be committed. | Application can query `df.status(instance_id)` if it saved the ID, or search will work once embeddings are committed. |
| PostgreSQL crash during workflow execution | pg_durable resumes workflow from last checkpoint on restart. | Embeddings are committed idempotently; no data loss. |
| Embedding API call fails with 5xx | pg_durable retries the `df.http()` node automatically. | Transparent to the caller. |
| Embedding API call fails with 4xx | Workflow fails; `df.status()` returns "failed". | Caller receives `Error::WorkflowFailed`; fix config and re-upsert. |
| Dimension mismatch detected | Workflow fails after first successful API call. | Caller receives `Error::WorkflowFailed` with dimension details; fix pipeline config. |
| Concurrent upsert of same document | `ON CONFLICT DO UPDATE` on documents is safe; chunk deletion is sequential. | May need advisory lock to prevent race between chunk-delete and chunk-insert if concurrency is high. (See Open Questions in SPEC.md.) |
