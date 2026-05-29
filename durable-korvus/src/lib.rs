//! # durable-korvus
//!
//! A durable, fault-tolerant vector search and RAG (Retrieval-Augmented Generation)
//! pipeline built on [`pg_durable`](https://github.com/microsoft/pg_durable) and
//! [`pgvector`](https://github.com/pgvector/pgvector).
//!
//! `durable-korvus` provides a Korvus-compatible API surface — Collections, Documents,
//! Pipelines, and Search — while routing all embedding API calls through `pg_durable`
//! durable workflows, giving you fault-tolerant ingestion that survives server crashes.
//!
//! ## Quick Start
//!
//! ```rust,no_run
//! use durable_korvus::{Client, Document, Pipeline, PipelineConfig, ChunkerConfig,
//!                      EmbeddingConfig, IngestMode};
//! use serde_json::json;
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     let client = Client::connect("postgres://user:pass@localhost/mydb").await?;
//!     let collection = client.collection("my_docs").await?;
//!
//!     let pipeline = Pipeline::new(
//!         "default",
//!         PipelineConfig {
//!             chunker: ChunkerConfig::FixedSize { size: 512, overlap: 64 },
//!             embedding: EmbeddingConfig {
//!                 provider_url: "https://api.openai.com/v1/embeddings".into(),
//!                 model: "text-embedding-3-small".into(),
//!                 api_key_env: "OPENAI_API_KEY".into(),
//!                 dimensions: 1536,
//!                 batch_size: 32,
//!                 timeout_seconds: 30,
//!             },
//!         },
//!     );
//!     collection.add_pipeline(&pipeline).await?;
//!
//!     collection.upsert_documents(
//!         vec![Document::new("doc1", "Rust is a systems programming language.", json!({}))],
//!         &pipeline,
//!         IngestMode::Sync,
//!     ).await?;
//!
//!     let results = collection.search("fast and safe language", &pipeline, 5, None).await?;
//!     for r in &results {
//!         println!("{:.4}  {}", r.score, r.document_id);
//!     }
//!
//!     Ok(())
//! }
//! ```
//!
//! ## Design
//!
//! See [`ARCHITECTURE.md`](https://github.com/microsoft/pg_durable/blob/main/durable-korvus/ARCHITECTURE.md)
//! and [`SPEC.md`](https://github.com/microsoft/pg_durable/blob/main/durable-korvus/SPEC.md)
//! for the full design documentation.

// TODO: Remove this allow once stubs are replaced with real implementations.
#![allow(dead_code)]

pub mod client;
pub mod collection;
pub mod document;
pub mod embeddings;
pub mod error;
pub mod pipeline;
pub mod schema;
pub mod search;

mod chunker;
mod workflow;

// Public API re-exports
pub use client::Client;
pub use collection::{Collection, CollectionInfo, UpsertResult};
pub use document::Document;
pub use embeddings::EmbeddingConfig;
pub use error::Error;
pub use pipeline::{IngestMode, Pipeline, PipelineConfig};
pub use search::SearchResult;

pub use chunker::ChunkerConfig;
