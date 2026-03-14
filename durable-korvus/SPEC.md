# durable-korvus Specification

> **Status:** 🚧 Design/Planning Phase. This specification is subject to change as design is validated. Implementation will begin after this spec is approved.

## Table of Contents

- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
- [Terminology](#terminology)
- [Dependencies](#dependencies)
- [Public API](#public-api)
  - [Client](#client)
  - [Collection](#collection)
  - [Document](#document)
  - [Pipeline](#pipeline)
  - [EmbeddingConfig](#embeddingconfig)
  - [ChunkerConfig](#chunkerconfig)
  - [SearchResult](#searchresult)
  - [IngestMode](#ingestmode)
- [Behavior Specification](#behavior-specification)
  - [Collection Lifecycle](#collection-lifecycle)
  - [Document Upsert](#document-upsert)
  - [Chunking](#chunking)
  - [Embedding](#embedding)
  - [Search](#search)
  - [Metadata Filtering](#metadata-filtering)
  - [Deletion](#deletion)
- [Error Handling](#error-handling)
- [Schema Specification](#schema-specification)
  - [Collection Tables](#collection-tables)
  - [Idempotency and Migrations](#idempotency-and-migrations)
- [Embedding Provider Contract](#embedding-provider-contract)
  - [Request Format](#request-format)
  - [Response Format](#response-format)
  - [Error Semantics](#error-semantics)
  - [Model Dimension Validation](#model-dimension-validation)
- [Durability Specification](#durability-specification)
  - [Ingestion Workflow Graph](#ingestion-workflow-graph)
  - [Sync Mode Semantics](#sync-mode-semantics)
  - [Async Mode Semantics](#async-mode-semantics)
  - [Retry and Failure Handling](#retry-and-failure-handling)
- [Security Considerations](#security-considerations)
- [Configuration Reference](#configuration-reference)
- [Open Questions](#open-questions)

---

## Overview

`durable-korvus` is a Rust crate providing a durable vector search and RAG ingestion pipeline on top of `pg_durable` and `pgvector`. It exposes a high-level API (Collections, Documents, Pipelines, Search) that is intentionally compatible with the [Korvus](https://github.com/postgresml/korvus) API surface, enabling existing Korvus users to migrate with minimal code changes.

The key differentiating feature is **durable ingestion**: document chunking and embedding API calls are executed as `pg_durable` workflow nodes, meaning the entire pipeline is fault-tolerant and automatically resumes after crashes.

---

## Goals and Non-Goals

### Goals

- Provide a Korvus-compatible API for collections, documents, pipelines, and vector search.
- Run all HTTPS embedding calls as `pg_durable` workflow nodes (no direct client-side HTTP).
- Support both synchronous (blocking) and asynchronous (background) ingestion.
- Store vectors in standard `pgvector` columns with HNSW indexes.
- Support metadata filtering on search results.
- Provide a clear migration path from Korvus.
- Be self-contained in the `durable-korvus/` top-level folder.

### Non-Goals (v0.1)

- Client bindings other than Rust.
- Hybrid search (vector + full-text). Planned for v0.2.
- Sentence-aware or token-based chunkers. Planned for v0.2.
- Multiple embedding providers per pipeline. Planned for v0.2.
- Direct integration with the Azure AI extension (`azure_ai`). `df.http()` is used instead.
- Custom ranking models or reranking.
- Collection-level access control / RLS. Planned for a future version.

---

## Terminology

| Term | Definition |
|------|------------|
| **Collection** | A named namespace grouping documents, chunks, and embeddings. Has its own set of PostgreSQL tables. |
| **Document** | A user-supplied text artifact with a stable id, content string, and JSON metadata. |
| **Chunk** | A contiguous substring of a document, produced by the chunker. The unit that gets embedded. |
| **Pipeline** | A named configuration specifying chunking and embedding parameters. Multiple pipelines can be active on one collection. |
| **Embedding** | A floating-point vector representation of a chunk, produced by calling an external HTTPS endpoint. |
| **Workflow** | A `pg_durable` durable function instance managing the lifecycle of an ingestion run. |
| **Sync ingestion** | `upsert_documents` blocks until all embeddings are committed to the database. |
| **Async ingestion** | `upsert_documents` submits the workflow and returns immediately; embedding runs in the background. |

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `pg_durable` | ≥ 0.2.0 | Durable workflow execution for embedding HTTPS calls |
| `pgvector` | ≥ 0.7 | Vector storage and HNSW similarity search |
| `tokio` | 1.x | Async runtime |
| `sqlx` | 0.8 | Async PostgreSQL client |
| `serde` / `serde_json` | 1.x | JSON serialization for metadata and configs |
| `uuid` | 1.x | Chunk ID generation |

---

## Public API

All types are defined in the `durable_korvus` crate root. The API is `async`-first using `tokio`.

### Client

```rust
pub struct Client { /* opaque */ }

impl Client {
    /// Connect to PostgreSQL. `db_url` is a standard libpq connection string.
    pub async fn connect(db_url: &str) -> Result<Self, Error>;

    /// Open or create a named collection (idempotent).
    pub async fn collection(&self, name: &str) -> Result<Collection, Error>;

    /// List all collections managed by durable-korvus in this database.
    pub async fn list_collections(&self) -> Result<Vec<CollectionInfo>, Error>;
}
```

### Collection

```rust
pub struct Collection { /* opaque */ }

impl Collection {
    /// Returns the collection name.
    pub fn name(&self) -> &str;

    /// Register a pipeline with this collection (idempotent).
    /// If the pipeline already exists with different config, returns Err(Error::PipelineConflict).
    pub async fn add_pipeline(&self, pipeline: &Pipeline) -> Result<(), Error>;

    /// Remove a pipeline and delete all its embeddings.
    pub async fn remove_pipeline(&self, name: &str) -> Result<(), Error>;

    /// List all registered pipelines for this collection.
    pub async fn list_pipelines(&self) -> Result<Vec<Pipeline>, Error>;

    /// Upsert documents into the collection.
    /// - Computes stable chunk IDs, inserts/updates chunks.
    /// - Submits a pg_durable workflow to call the embedding provider and store vectors.
    /// - If mode is Sync, polls until the workflow completes before returning.
    /// - If mode is Async, returns the pg_durable instance_id immediately.
    pub async fn upsert_documents(
        &self,
        documents: Vec<Document>,
        pipeline: &Pipeline,
        mode: IngestMode,
    ) -> Result<UpsertResult, Error>;

    /// Delete documents by id. Cascades to chunks and embeddings.
    pub async fn delete_documents(&self, ids: &[&str]) -> Result<u64, Error>;

    /// Fetch a single document by id. Returns None if not found.
    pub async fn get_document(&self, id: &str) -> Result<Option<Document>, Error>;

    /// Perform vector similarity search.
    /// - `query`: natural language query string (will be embedded via the pipeline).
    /// - `pipeline`: which pipeline's embeddings to search.
    /// - `k`: number of top results to return.
    /// - `filter`: optional JSON metadata predicate (see Metadata Filtering).
    pub async fn search(
        &self,
        query: &str,
        pipeline: &Pipeline,
        k: u32,
        filter: Option<serde_json::Value>,
    ) -> Result<Vec<SearchResult>, Error>;

    /// Drop the collection and all its tables. Irreversible.
    pub async fn delete(self) -> Result<(), Error>;
}
```

### Document

```rust
pub struct Document {
    pub id: String,
    pub content: String,
    pub metadata: serde_json::Value,
}

impl Document {
    pub fn new(id: impl Into<String>, content: impl Into<String>, metadata: serde_json::Value) -> Self;
}
```

### Pipeline

```rust
pub struct Pipeline {
    pub name: String,
    pub config: PipelineConfig,
}

pub struct PipelineConfig {
    pub chunker: ChunkerConfig,
    pub embedding: EmbeddingConfig,
}

impl Pipeline {
    pub fn new(name: impl Into<String>, config: PipelineConfig) -> Self;
}
```

### EmbeddingConfig

```rust
pub struct EmbeddingConfig {
    /// Base URL for the embeddings endpoint (e.g., "https://api.openai.com/v1/embeddings")
    pub provider_url: String,

    /// Model name as expected by the provider (e.g., "text-embedding-3-small")
    pub model: String,

    /// Environment variable name holding the API key. Read at workflow execution time.
    pub api_key_env: String,

    /// Expected output vector dimension. Validated against first API response.
    pub dimensions: u32,

    /// Max number of chunks per API call. Default: 32.
    pub batch_size: u32,

    /// HTTP request timeout in seconds. Default: 30.
    pub timeout_seconds: u32,
}
```

### ChunkerConfig

```rust
pub enum ChunkerConfig {
    /// Split content into fixed-size windows with optional overlap.
    FixedSize {
        /// Window size in characters.
        size: usize,
        /// Number of characters of overlap between adjacent chunks.
        overlap: usize,
    },

    /// Caller is responsible for supplying pre-chunked content.
    /// Documents must supply chunks directly (see upsert_documents with pre-chunked input).
    UserProvided,
}
```

### SearchResult

```rust
pub struct SearchResult {
    pub chunk_id: String,
    pub document_id: String,
    pub chunk_text: String,
    pub chunk_index: u32,
    pub metadata: serde_json::Value,
    pub score: f32,
}
```

### IngestMode

```rust
pub enum IngestMode {
    /// Block until all embeddings are committed and the workflow completes.
    Sync,

    /// Submit the pg_durable workflow and return immediately.
    Async,
}
```

### UpsertResult

```rust
pub struct UpsertResult {
    /// Number of documents upserted.
    pub document_count: u64,

    /// Number of chunks produced.
    pub chunk_count: u64,

    /// pg_durable workflow instance ID (present for both Sync and Async modes).
    pub instance_id: String,
}
```

---

## Behavior Specification

### Collection Lifecycle

1. `client.collection(name)` calls `CREATE TABLE IF NOT EXISTS` for all four collection tables (documents, chunks, embeddings, pipelines). This is safe to call concurrently.
2. Collection names must match `[a-z][a-z0-9_]{0,62}` (lowercase, alphanumeric, underscores, max 63 chars). Returns `Error::InvalidName` otherwise.
3. `collection.delete()` issues `DROP TABLE ... CASCADE` for all four tables in dependency order.
4. `client.list_collections()` queries a global `_dk_collections` registry table (see Schema Specification).

### Document Upsert

1. For each document in the input list:
   a. `INSERT INTO <name>_documents (id, content, metadata, updated_at) VALUES (...) ON CONFLICT (id) DO UPDATE SET content=..., metadata=..., updated_at=now()`.
   b. Delete all existing chunks for this document and pipeline: `DELETE FROM <name>_chunks WHERE document_id=$1 AND pipeline=$2`.
   c. Run the chunker to produce chunks.
   d. Insert new chunks with stable chunk IDs (see Chunking).
2. Submit a single `pg_durable` workflow covering all documents in the batch (not one workflow per document).
3. If `mode = Sync`, poll `df.status(instance_id)` until `completed` or `failed`.
4. If `mode = Async`, return `UpsertResult` immediately.

### Chunking

The chunker converts a document's `content` string into a list of `(chunk_index, chunk_text)` pairs.

**FixedSize chunker:**

```
chunk_0 = content[0 .. size]
chunk_1 = content[size-overlap .. 2*size-overlap]
chunk_2 = content[2*(size-overlap) .. 3*size-overlap]
...
```

Empty trailing chunks (whitespace-only) are dropped.

**Stable chunk IDs:**

```
chunk_id = sha256(collection_name || "/" || document_id || "/" || pipeline_name || "/" || chunk_index)
           encoded as lowercase hex, truncated to 32 characters
```

Stable IDs ensure that re-upserting the same document produces the same chunk IDs, which allows correct ON CONFLICT handling if partial ingestion is retried.

### Embedding

1. Chunks are batched into groups of `batch_size`.
2. For each batch, a `df.http()` node is added to the workflow:
   - `POST <provider_url>`
   - Body: `{"model": "<model>", "input": ["chunk1", "chunk2", ...]}`
   - Headers: `{"Authorization": "Bearer <api_key>", "Content-Type": "application/json"}`
   - The API key is read from the named environment variable at workflow execution time.
3. Each batch result is parsed and vectors are written to `<name>_embeddings`.
4. Vector dimension is validated against `EmbeddingConfig.dimensions` on the first response. Returns `Error::DimensionMismatch` if they differ.

### Search

1. The query string is embedded via a **synchronous** HTTPS call using `df.http()` (a single-node workflow, awaited immediately).
2. The resulting query vector is used in:
   ```sql
   SELECT c.chunk_id, c.document_id, c.chunk_text, c.chunk_index,
          d.metadata, 1 - (e.embedding <=> $query_vector) AS score
   FROM <name>_embeddings e
   JOIN <name>_chunks c ON c.chunk_id = e.chunk_id
   JOIN <name>_documents d ON d.id = c.document_id
   WHERE e.pipeline = $pipeline_name
     AND ($filter IS NULL OR d.metadata @> $filter)
   ORDER BY e.embedding <=> $query_vector
   LIMIT $k;
   ```
3. Results are returned as `Vec<SearchResult>`.

### Metadata Filtering

Filters are expressed as JSON objects and matched using PostgreSQL's `@>` (contains) operator on the `metadata JSONB` column.

Examples:

```rust
// Filter to documents with tag == "intro"
Some(json!({"tag": "intro"}))

// Filter to documents with category == "technical" AND source == "blog"
Some(json!({"category": "technical", "source": "blog"}))

// No filter (all documents)
None
```

> **TODO:** More expressive filter predicates (range queries, `NOT`, nested paths) may be added in a future version.

### Deletion

`delete_documents(ids)` executes:
```sql
DELETE FROM <name>_documents WHERE id = ANY($ids)
```
Cascade constraints on `<name>_chunks.document_id` and `<name>_embeddings.chunk_id` ensure all dependent rows are also removed.

---

## Error Handling

```rust
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("invalid collection name: {0}")]
    InvalidName(String),

    #[error("pipeline '{0}' already registered with different config")]
    PipelineConflict(String),

    #[error("pipeline '{0}' not found")]
    PipelineNotFound(String),

    #[error("embedding dimension mismatch: expected {expected}, got {actual}")]
    DimensionMismatch { expected: u32, actual: u32 },

    #[error("embedding provider error (HTTP {status}): {body}")]
    EmbeddingProvider { status: u16, body: String },

    #[error("ingestion workflow failed: {0}")]
    WorkflowFailed(String),

    #[error("workflow timed out after {0}s")]
    WorkflowTimeout(u64),

    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("{0}")]
    Other(String),
}
```

**HTTP 4xx from embedding provider:** Returns `Error::EmbeddingProvider` immediately (not retried — likely a configuration error).

**HTTP 5xx from embedding provider:** Retried by `pg_durable`'s workflow retry mechanism before surfacing as `Error::EmbeddingProvider`.

---

## Schema Specification

### Collection Tables

All tables use the collection name as a prefix (`<name>_*`).

```sql
-- Global collection registry
CREATE TABLE IF NOT EXISTS _dk_collections (
    name        TEXT PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-collection: raw documents
CREATE TABLE IF NOT EXISTS <name>_documents (
    id          TEXT PRIMARY KEY,
    content     TEXT NOT NULL,
    metadata    JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-collection: chunks (unit of embedding)
CREATE TABLE IF NOT EXISTS <name>_chunks (
    chunk_id     TEXT PRIMARY KEY,
    document_id  TEXT NOT NULL REFERENCES <name>_documents(id) ON DELETE CASCADE,
    pipeline     TEXT NOT NULL,
    chunk_index  INT NOT NULL,
    chunk_text   TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (document_id, pipeline, chunk_index)
);
CREATE INDEX IF NOT EXISTS <name>_chunks_doc_pipeline_idx
    ON <name>_chunks (document_id, pipeline);

-- Per-pipeline: embeddings (one table per pipeline to support different vector dimensions)
-- Table name: <name>_embeddings_<pipeline_name>
-- N = EmbeddingConfig.dimensions for that pipeline
CREATE TABLE IF NOT EXISTS <name>_embeddings_<pipeline_name> (
    chunk_id     TEXT NOT NULL REFERENCES <name>_chunks(chunk_id) ON DELETE CASCADE,
    embedding    vector(<N>),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chunk_id)
);
CREATE INDEX IF NOT EXISTS <name>_embeddings_<pipeline_name>_hnsw_idx
    ON <name>_embeddings_<pipeline_name>
    USING hnsw (embedding vector_cosine_ops);

-- Per-collection: pipeline configs
CREATE TABLE IF NOT EXISTS <name>_pipelines (
    name        TEXT PRIMARY KEY,
    config      JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Note:** Per [ADR-3](ARCHITECTURE.md#adr-3-per-pipeline-embedding-tables), there is one embedding table per pipeline (`<name>_embeddings_<pipeline_name>`). This supports multiple pipelines with different embedding dimensions on the same collection. The `vector(<N>)` column dimension is fixed at pipeline registration time.

### Idempotency and Migrations

- All `CREATE TABLE` statements use `IF NOT EXISTS`.
- New columns added in future versions use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.
- Pipeline config changes are detected and rejected with `Error::PipelineConflict` to prevent dimension mismatches.
- The `_dk_collections` registry is the source of truth for `list_collections()`.

---

## Embedding Provider Contract

### Request Format

`durable-korvus` calls embedding providers using the OpenAI embeddings API format:

```http
POST <provider_url>
Content-Type: application/json
Authorization: Bearer <api_key>

{
  "model": "<model_name>",
  "input": ["text1", "text2", ...]
}
```

The `input` array contains between 1 and `batch_size` strings.

### Response Format

The response must follow the OpenAI embeddings response format:

```json
{
  "object": "list",
  "data": [
    { "object": "embedding", "index": 0, "embedding": [0.1, 0.2, ...] },
    { "object": "embedding", "index": 1, "embedding": [0.3, 0.4, ...] }
  ],
  "model": "text-embedding-3-small",
  "usage": { "prompt_tokens": 8, "total_tokens": 8 }
}
```

The `data` array must have the same length as `input`. Results are matched by `index`.

### Error Semantics

| HTTP Status | Behavior |
|-------------|----------|
| 2xx | Parse response and store embeddings |
| 429 Too Many Requests | Retry with exponential backoff (handled by `pg_durable` workflow retry) |
| 5xx | Retry (handled by `pg_durable` workflow retry) |
| 4xx (other) | Fail immediately with `Error::EmbeddingProvider` (not retried) |

### Model Dimension Validation

On the first successful embedding call for a pipeline, the returned vector dimension is compared to `EmbeddingConfig.dimensions`. If they differ, the workflow fails with a clear error message. This catches misconfigured pipelines before committing any data.

---

## Durability Specification

### Ingestion Workflow Graph

For a batch of `N` documents producing `B` embedding batches, the pg_durable workflow looks like:

```
df.start(
    upsert_chunks_sql                   -- writes chunks to DB
    ~> embed_batch_0                    -- df.http() for batch 0
    ~> store_embeddings_0_sql           -- writes vectors to DB
    ~> embed_batch_1                    -- df.http() for batch 1
    ~> store_embeddings_1_sql           -- writes vectors to DB
    ~> ...
    ~> mark_complete_sql                -- updates ingestion status
)
```

> **Design TODO:** Parallel vs. sequential batch execution. Sequential is simpler and easier to reason about for retry semantics. Parallel (using `&` operator) would be faster for large batches but requires all batches to succeed before marking complete. Initial implementation will use sequential.

Each step is a SQL function (`df.sql()`) or HTTP call (`df.http()`). If any step fails, the workflow retries from the last successful checkpoint.

### Sync Mode Semantics

```
Client calls upsert_documents(mode=Sync)
    │
    ├─ Insert/update documents table
    ├─ Delete + re-insert chunks table  
    ├─ Submit pg_durable workflow
    │   └─ Returns instance_id
    │
    └─ Poll df.status(instance_id) every 100ms
           │
           ├─ "running" → continue polling
           ├─ "completed" → return Ok(UpsertResult)
           └─ "failed" → return Err(Error::WorkflowFailed)

Default timeout: 300 seconds (configurable).
```

### Async Mode Semantics

```
Client calls upsert_documents(mode=Async)
    │
    ├─ Insert/update documents table
    ├─ Delete + re-insert chunks table
    └─ Submit pg_durable workflow
           └─ Returns instance_id immediately → Ok(UpsertResult { instance_id, ... })

pg_durable background worker executes the workflow independently.
```

The caller can check status later via raw SQL: `SELECT df.status('<instance_id>')`.

### Retry and Failure Handling

- `pg_durable` provides automatic retry for failed workflow nodes.
- Chunk insertion is idempotent (stable chunk IDs + `ON CONFLICT DO NOTHING`).
- Embedding API calls that fail with 5xx are retried by the workflow.
- If a workflow is retried after partial completion, already-stored embeddings are skipped (idempotent `INSERT ... ON CONFLICT DO NOTHING` on the embeddings table).

---

## Security Considerations

- **API keys are never stored in the database.** They are read from environment variables at workflow execution time by the `pg_durable` background worker.
- **SSRF protection:** `pg_durable`'s built-in SSRF protection is active for all `df.http()` calls. Private IP ranges and localhost are blocked by default.
- **SQL injection:** Collection names are validated against `[a-z][a-z0-9_]{0,62}` before use in dynamic SQL. No user-supplied strings are interpolated into SQL without parameterization.
- **Metadata:** Stored as JSONB; filtered using parameterized `@>` operator. Not interpolated into SQL.
- **Collection isolation:** Each collection's tables are named-scoped. Access control is the responsibility of the database administrator (row-level security integration is a future roadmap item).

---

## Configuration Reference

| Config Key | Type | Default | Description |
|------------|------|---------|-------------|
| `EmbeddingConfig.provider_url` | `String` | (required) | HTTPS URL for embeddings endpoint |
| `EmbeddingConfig.model` | `String` | (required) | Model name |
| `EmbeddingConfig.api_key_env` | `String` | (required) | Environment variable for API key |
| `EmbeddingConfig.dimensions` | `u32` | (required) | Expected vector dimension |
| `EmbeddingConfig.batch_size` | `u32` | `32` | Max chunks per API call |
| `EmbeddingConfig.timeout_seconds` | `u32` | `30` | HTTP timeout |
| `ChunkerConfig::FixedSize.size` | `usize` | (required) | Window size in characters |
| `ChunkerConfig::FixedSize.overlap` | `usize` | `0` | Overlap between adjacent chunks |
| `Client.sync_timeout_seconds` | `u64` | `300` | Max wait for Sync mode |
| `Client.poll_interval_ms` | `u64` | `100` | Poll interval for Sync mode |

---

## Open Questions

> These questions need answers before or during implementation.

1. **Multi-dimension pipelines:** The current schema design uses a single `vector(<N>)` column in `<name>_embeddings`. If a collection has two pipelines with different embedding dimensions, this won't work. Options:
   - One embedding table per pipeline (e.g., `<name>_embeddings_<pipeline_name>`)
   - A separate table with a generic `float4[]` column (less efficient for HNSW)
   - Restrict: error if pipelines with different dimensions are added to the same collection
   - **Tentative decision:** One table per pipeline for flexibility. Needs validation.

2. **Parallel vs. sequential batch embedding:** Sequential is simpler to implement and reason about; parallel is faster. Initial implementation will be sequential; parallelism can be added if benchmarks show it is necessary.

3. **Chunker unit — characters vs. tokens:** The spec currently uses characters for `FixedSize`. Token-based chunking is more aligned with how LLMs count context. A future `FixedSizeTokens` variant is anticipated.

4. **Search query embedding:** The search path embeds the query via a single-node pg_durable workflow. This adds latency compared to a direct HTTP call. Alternatives: allow direct HTTP in search (breaking the "no direct HTTP" design goal), or cache query embeddings. To be evaluated.

5. **Korvus pipeline YAML compatibility:** Should durable-korvus support loading Korvus-style YAML pipeline configs for easier migration? Not planned for v0.1, but worth considering.

6. **Concurrency during upsert:** If two callers upsert the same document concurrently, the `ON CONFLICT` logic for chunks may produce races. A document-level advisory lock may be needed.
