# durable-korvus

> **Status:** 🚧 Design/Planning Phase — implementation has not started yet. See [SPEC.md](SPEC.md) and [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

`durable-korvus` is a Rust crate providing a **durable, fault-tolerant vector search and RAG (Retrieval-Augmented Generation) pipeline** built on top of [`pg_durable`](https://github.com/microsoft/pg_durable) and [`pgvector`](https://github.com/pgvector/pgvector).

It is designed as a **drop-in spiritual successor to [korvus](https://github.com/postgresml/korvus)**: users familiar with Korvus' Collection/Pipeline/Search API can migrate to `durable-korvus` with minimal changes, gaining fault-tolerant ingestion and durability guarantees in exchange.

---

## Table of Contents

- [Why durable-korvus?](#why-durable-korvus)
- [Key Features](#key-features)
- [PostgreSQL Extensions Required](#postgresql-extensions-required)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
  - [Collections](#collections)
  - [Documents](#documents)
  - [Pipelines](#pipelines)
  - [Embeddings](#embeddings)
  - [Search](#search)
- [API Reference](#api-reference)
- [Migration Guide: Korvus → durable-korvus](#migration-guide-korvus--durable-korvus)
- [Configuration](#configuration)
- [Schema & Durability](#schema--durability)
- [Sync vs Async Ingestion](#sync-vs-async-ingestion)
- [Examples](#examples)
- [Development](#development)
- [Architecture](#architecture)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Why durable-korvus?

| Concern | Korvus | durable-korvus |
|---------|--------|----------------|
| Embedding calls | Direct HTTP from client | Via `pg_durable` HTTPS activity (durable, retryable) |
| Ingestion durability | Best-effort | Fault-tolerant; survives crashes mid-pipeline |
| Embedding provider | PostgresML-specific | Any OpenAI-compatible HTTPS endpoint |
| Storage backend | PostgresML tables | `pgvector` tables owned by you |
| PostgreSQL extensions | PostgresML | `pgvector` + `pg_durable` |
| RAG abstraction | Pipeline DSL | Pipeline DSL (compatible surface) |

`durable-korvus` keeps the **same ergonomic surface area** as Korvus while swapping the implementation to rely only on `pgvector` and `pg_durable`.

---

## Key Features

- **Durable ingestion:** Document chunking and embedding calls run as `pg_durable` workflows — if the server crashes mid-ingest, the pipeline resumes automatically from the last checkpoint.
- **Provider-agnostic embeddings:** Any OpenAI-compatible HTTPS endpoint (Azure OpenAI, OpenAI, etc.) works out of the box. No special PostgreSQL AI extensions required.
- **pgvector storage:** Vectors are stored in standard `pgvector` columns, giving you full SQL access to the data.
- **Korvus-compatible API:** Collections, Documents, and Pipelines follow the same conceptual model, easing migration.
- **Sync and async ingestion:** Block until embedding is complete, or fire-and-forget into the durable background worker.
- **Metadata filtering:** Query results can be filtered by arbitrary JSON predicates on document metadata.

---

## PostgreSQL Extensions Required

Both extensions must be installed before using `durable-korvus`:

```sql
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector
CREATE EXTENSION IF NOT EXISTS pg_durable; -- pg_durable (in shared_preload_libraries)
```

See [pg_durable installation docs](../README.md) and [pgvector installation docs](https://github.com/pgvector/pgvector#installation).

---

## Quick Start

> **TODO:** Fill in once the crate is published to crates.io. Below is the intended developer experience.

```toml
# Cargo.toml
[dependencies]
durable-korvus = "0.1"
```

```rust
use durable_korvus::{Client, Collection, Pipeline, PipelineConfig, EmbeddingConfig};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Connect to PostgreSQL
    let client = Client::connect("postgres://user:pass@localhost/mydb").await?;

    // Create (or open) a named collection
    let collection = client.collection("my_docs").await?;

    // Define a pipeline (chunking + embedding config)
    let pipeline = Pipeline::new(
        "default",
        PipelineConfig {
            chunker: ChunkerConfig::FixedSize { size: 512, overlap: 64 },
            embedding: EmbeddingConfig {
                provider_url: "https://api.openai.com/v1/embeddings".into(),
                model: "text-embedding-3-small".into(),
                api_key_env: "OPENAI_API_KEY".into(),
                dimensions: 1536,
            },
        },
    );
    collection.add_pipeline(&pipeline).await?;

    // Upsert documents (sync — blocks until embeddings committed)
    collection.upsert_documents(vec![
        Document::new("doc1", "Rust is a systems programming language...", json!({"tag": "intro"})),
        Document::new("doc2", "pgvector enables vector similarity search...", json!({"tag": "database"})),
    ], &pipeline, IngestMode::Sync).await?;

    // Search
    let results = collection.search("fast and safe systems language", &pipeline, 5, None).await?;
    for r in results {
        println!("{:.4}  {}  {:?}", r.score, r.document_id, r.metadata);
    }

    Ok(())
}
```

---

## Core Concepts

### Collections

A **Collection** is a named namespace that groups related documents, chunks, and vector indexes. Each collection has its own set of PostgreSQL tables (documents, chunks, embeddings).

```
Collection "my_docs"
├── my_docs_documents    — raw documents (id, content, metadata)
├── my_docs_chunks       — chunked text (chunk_id, doc_id, chunk_text, chunk_index)
└── my_docs_embeddings   — vectors (chunk_id, pipeline_name, embedding vector(N))
```

Collections are **idempotent**: calling `client.collection("name")` is safe to call multiple times and will create the tables if they don't already exist.

### Documents

A **Document** has three required fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | Stable user-supplied identifier (upsert key) |
| `content` | `String` | Full text content to be chunked and embedded |
| `metadata` | `serde_json::Value` | Arbitrary JSON, filterable at search time |

Upserting a document with the same `id` replaces the previous content and re-runs chunking + embedding.

### Pipelines

A **Pipeline** is a named configuration that controls how documents are chunked and embedded. Multiple pipelines can be active on the same collection (e.g., one for semantic search, another for a different model/dimension).

Pipeline config includes:

- **Chunker**: Splits document content into smaller pieces before embedding.
  - `FixedSize { size, overlap }` — fixed token/character window with optional overlap
  - `UserProvided` — caller supplies chunks directly (no automatic splitting)
- **Embedding**: Configures the HTTPS embedding provider (model, dimensions, API key).

### Embeddings

`durable-korvus` **never calls embedding APIs directly from your application process**. Instead, it submits embedding work as a `pg_durable` workflow node, which the PostgreSQL background worker executes via `df.http()`. This means:

- Embedding calls are **durable** — a crash during embedding does not leave documents in a half-ingested state.
- Embedding calls are **retried automatically** on transient failures.
- Your application is **decoupled** from the network path to the AI provider.

The embedding HTTPS call follows the OpenAI embeddings API format:

```json
POST /v1/embeddings
{
  "model": "text-embedding-3-small",
  "input": ["chunk text 1", "chunk text 2", ...]
}
```

Any provider with an OpenAI-compatible embeddings endpoint is supported.

### Search

Vector similarity search over a collection's embeddings:

```rust
let results = collection.search(
    "query text",
    &pipeline,         // which pipeline's embeddings to search
    10,                // top-k results
    Some(json!({"tag": "intro"})),  // optional metadata filter (JSON predicate)
).await?;
```

Each result contains:

| Field | Type | Description |
|-------|------|-------------|
| `chunk_id` | `String` | Internal chunk identifier |
| `document_id` | `String` | Originating document's user-supplied id |
| `chunk_text` | `String` | The chunk text that was embedded |
| `metadata` | `Value` | Document metadata |
| `score` | `f32` | Cosine similarity score (higher = more similar) |

---

## API Reference

> **TODO:** Full API reference will be generated from rustdoc once implementation begins. The table below describes the intended public API surface.

### `Client`

| Method | Description |
|--------|-------------|
| `Client::connect(db_url)` | Connect to PostgreSQL and return a client |
| `client.collection(name)` | Open or create a named collection |
| `client.list_collections()` | List all collections in the database |

### `Collection`

| Method | Description |
|--------|-------------|
| `collection.add_pipeline(pipeline)` | Register a pipeline config for this collection |
| `collection.remove_pipeline(name)` | Remove a pipeline and its embeddings |
| `collection.list_pipelines()` | List registered pipelines |
| `collection.upsert_documents(docs, pipeline, mode)` | Ingest documents (sync or async) |
| `collection.delete_documents(ids)` | Delete documents and their chunks/embeddings |
| `collection.get_document(id)` | Fetch a single document by id |
| `collection.search(query, pipeline, k, filter)` | Perform vector similarity search |
| `collection.delete()` | Drop the collection and all its tables |

### `Document`

| Method | Description |
|--------|-------------|
| `Document::new(id, content, metadata)` | Construct a new document |

### `Pipeline`

| Method | Description |
|--------|-------------|
| `Pipeline::new(name, config)` | Construct a named pipeline config |

### `IngestMode`

| Variant | Description |
|---------|-------------|
| `IngestMode::Sync` | Block until all chunks are embedded and committed |
| `IngestMode::Async` | Submit ingestion workflow and return immediately |

---

## Migration Guide: Korvus → durable-korvus

This section maps Korvus concepts and code patterns to their `durable-korvus` equivalents.

### Concept Mapping

| Korvus concept | durable-korvus equivalent | Notes |
|----------------|--------------------------|-------|
| `Collection::new(name, None)` | `client.collection(name).await` | Async; auto-creates tables |
| `collection.upsert_documents(docs)` | `collection.upsert_documents(docs, &pipeline, mode).await` | Pipeline is now explicit |
| Pipeline YAML config | `PipelineConfig` struct | Typed; no YAML parsing |
| `collection.get_pipelines()` | `collection.list_pipelines()` | Renamed for clarity |
| `collection.vector_search(query, pipeline)` | `collection.search(query, &pipeline, k, filter)` | k and filter are explicit |
| `pgml.embed(model, text)` | HTTPS call via `pg_durable` | No PostgresML extension needed |
| `Document { id, document }` | `Document::new(id, content, metadata)` | Metadata is first-class |

### Code Comparison

**Korvus:**
```rust
use korvus::Collection;

let mut collection = Collection::new("my_docs", None)?;
collection.upsert_documents(serde_json::json!([
    {"id": "doc1", "document": {"text": "Some content", "label": "intro"}}
])).await?;

let results = collection.vector_search(
    serde_json::json!({"query": {"fields": {"document": {"query": "fast systems"}}}}),
    &pipeline,
).await?;
```

**durable-korvus:**
```rust
use durable_korvus::{Client, Document, Pipeline, PipelineConfig, IngestMode};

let client = Client::connect("postgres://...").await?;
let collection = client.collection("my_docs").await?;
let pipeline = Pipeline::new("default", /* config */);

collection.upsert_documents(
    vec![Document::new("doc1", "Some content", json!({"label": "intro"}))],
    &pipeline,
    IngestMode::Sync,
).await?;

let results = collection.search("fast systems", &pipeline, 10, None).await?;
```

### Key Differences

1. **No PostgresML required** — `durable-korvus` uses `pgvector` + `pg_durable` only.
2. **Embedding is durable** — if your server crashes mid-ingest in Korvus, documents may be partially embedded. In `durable-korvus`, the workflow resumes automatically.
3. **Pipeline is explicit** — in Korvus, the pipeline is sometimes inferred. In `durable-korvus`, you always specify which pipeline to use.
4. **Async-first** — `durable-korvus` uses `tokio` throughout; blocking calls are provided via `IngestMode::Sync`.
5. **Metadata is typed** — document metadata is `serde_json::Value` not a freeform string field.

### What does NOT change

- Collection and document naming conventions are the same.
- The RAG query pattern (embed query → find similar chunks → return with metadata) is identical.
- Metadata filtering semantics are the same (JSON key-value predicates).

---

## Configuration

### Embedding Provider

`durable-korvus` supports any OpenAI-compatible embeddings endpoint:

```rust
EmbeddingConfig {
    provider_url: "https://myresource.openai.azure.com/openai/deployments/my-embedding/embeddings?api-version=2024-02-01".into(),
    model: "text-embedding-3-small".into(),
    api_key_env: "AZURE_OPENAI_API_KEY".into(),  // read from environment
    dimensions: 1536,
    batch_size: 32,   // max chunks per embedding API call
    timeout_seconds: 30,
}
```

The API key is read from an environment variable at workflow execution time (never stored in the database).

### Chunker Config

```rust
// Fixed-size chunking
ChunkerConfig::FixedSize {
    size: 512,      // chunk size in characters (TODO: token-based option planned)
    overlap: 64,    // overlap between adjacent chunks
}

// Caller-supplied chunks (no automatic splitting)
ChunkerConfig::UserProvided
```

---

## Schema & Durability

For each collection named `<name>`, `durable-korvus` creates:

```sql
-- Raw documents
CREATE TABLE <name>_documents (
    id          TEXT PRIMARY KEY,
    content     TEXT NOT NULL,
    metadata    JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Chunks produced by the chunker
CREATE TABLE <name>_chunks (
    chunk_id     TEXT PRIMARY KEY,   -- stable: hash(doc_id, chunk_index, pipeline)
    document_id  TEXT NOT NULL REFERENCES <name>_documents(id) ON DELETE CASCADE,
    pipeline     TEXT NOT NULL,
    chunk_index  INT NOT NULL,
    chunk_text   TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Embeddings (vector column dimension set per pipeline)
CREATE TABLE <name>_embeddings (
    chunk_id     TEXT NOT NULL REFERENCES <name>_chunks(chunk_id) ON DELETE CASCADE,
    pipeline     TEXT NOT NULL,
    embedding    vector(N),           -- N = dimensions from EmbeddingConfig
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chunk_id, pipeline)
);
CREATE INDEX ON <name>_embeddings USING hnsw (embedding vector_cosine_ops);

-- Pipeline registry
CREATE TABLE <name>_pipelines (
    name        TEXT PRIMARY KEY,
    config      JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

All table creation is idempotent (`CREATE TABLE IF NOT EXISTS`). Schema migrations for new columns use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.

### Durability Guarantees

| Operation | Guarantee |
|-----------|-----------|
| `upsert_documents` (Sync) | Returns only after embedding committed to `<name>_embeddings` |
| `upsert_documents` (Async) | Workflow submitted to `pg_durable`; survives server restart |
| Partial failure during embedding | Workflow retries from last successful chunk batch |
| `delete_documents` | Cascades to chunks and embeddings via FK constraint |

---

## Sync vs Async Ingestion

```
IngestMode::Sync                          IngestMode::Async
─────────────────────────────────────     ──────────────────────────────────────
upsert_documents() called                 upsert_documents() called
         │                                         │
         ▼                                         ▼
  df.start() submitted                     df.start() submitted
         │                                         │
         │  (poll df.status())                     │  (returns immediately)
         │◄─────────────────────                   │  instance_id returned
         │                                         │
         ▼                                         ▼
  workflow completes                       background worker executes
  (embedding committed)                   (embedding committed asynchronously)
         │
         ▼
  upsert_documents() returns Ok
```

Use `IngestMode::Sync` when you need a guarantee that documents are searchable before proceeding. Use `IngestMode::Async` for bulk ingestion where eventual consistency is acceptable.

---

## Examples

See the [`examples/`](examples/) directory:

| Example | Description |
|---------|-------------|
| [`basic_rag.rs`](examples/basic_rag.rs) | End-to-end RAG: ingest + search |
| [`bulk_ingest.rs`](examples/bulk_ingest.rs) | Async bulk ingestion of many documents |
| [`metadata_filter.rs`](examples/metadata_filter.rs) | Filtering search results by metadata |
| [`migration_from_korvus.rs`](examples/migration_from_korvus.rs) | Side-by-side Korvus → durable-korvus migration |
| [`custom_chunker.rs`](examples/custom_chunker.rs) | User-provided chunking (no automatic splitting) |
| [`azure_openai.rs`](examples/azure_openai.rs) | Azure OpenAI embeddings provider config |

---

## Development

### Prerequisites

- PostgreSQL 17 with `pgvector` and `pg_durable` extensions
- Rust (nightly, same toolchain as pg_durable)

### Running Tests

```bash
# Unit tests
cargo test

# Integration tests (requires running PostgreSQL)
DATABASE_URL=postgres://localhost/test_db cargo test --features integration
```

### Linting and Formatting

```bash
cargo fmt
cargo clippy -- -D warnings
```

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full architectural design, including:

- Component diagram
- Ingestion workflow (pg_durable activity graph)
- Search query path
- Schema design rationale
- Embedding provider abstraction

---

## Roadmap

> Items marked 🚧 are planned but not yet implemented.

### v0.1 (Initial Release)
- [x] Design and specification (this document)
- [ ] 🚧 Collection CRUD
- [ ] 🚧 Document upsert (sync + async)
- [ ] 🚧 Fixed-size chunker
- [ ] 🚧 OpenAI-compatible embedding provider
- [ ] 🚧 Vector search (cosine similarity via pgvector)
- [ ] 🚧 Metadata filtering

### v0.2 (Planned)
- [ ] 🚧 Hybrid search (vector + full-text BM25)
- [ ] 🚧 Additional chunkers (sentence-aware, token-based)
- [ ] 🚧 Multiple embedding providers in one pipeline
- [ ] 🚧 Reranking support

### Future
- [ ] 🚧 Python/TypeScript client bindings (via Korvus bridge)
- [ ] 🚧 Streaming search results
- [ ] 🚧 Collection-level access control (RLS integration)

---

## Contributing

Contributions are welcome! Before opening a PR:

1. Open an issue using the [issue templates](.github/ISSUE_TEMPLATE/) to discuss the proposed change.
2. Follow the coding style of [`pg_durable`](../README.md#development): `cargo fmt`, `cargo clippy -- -D warnings`, no unused code.
3. Add an E2E test in `examples/` for new user-facing features.

---

## Upgrade & Migration

### Backward Compatibility

`durable-korvus` is a **client library** — it does not ship as a PostgreSQL extension and does not have its own extension schema. There is no `ALTER EXTENSION` migration path. Version compatibility is managed at the library level:

- Collection tables (`<name>_documents`, `<name>_chunks`, etc.) are created by the library using `CREATE TABLE IF NOT EXISTS`. New columns in future versions will use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` to avoid breaking existing installations.
- The `_dk_collections` registry table is likewise created idempotently.
- If you upgrade `durable-korvus` and the schema has changed, run your application against the database; the library will apply any `ALTER TABLE` migrations automatically on startup.

### Compatibility with pg_durable Versions

`durable-korvus` calls `pg_durable` via SQL (`df.start()`, `df.status()`, `df.http()`). The minimum required version of `pg_durable` is **0.2.0**. When upgrading `pg_durable`, consult [pg_durable's upgrade documentation](../docs/upgrade-testing.md) to ensure the `.so` binary remains compatible with the installed schema version.

### Schema Version Detection

> **TODO:** If `durable-korvus` needs to detect the installed schema version for conditional migration logic, it will query `SELECT extversion FROM pg_extension WHERE extname = 'pg_durable'`. This pattern is established in the pg_durable codebase (see `src/dsl.rs`).

---

## License

MIT — see [LICENSE](../LICENSE).
