//! Pipeline and ingestion mode types.

use crate::chunker::ChunkerConfig;
use crate::embeddings::EmbeddingConfig;
use serde::{Deserialize, Serialize};

/// A named configuration that controls how documents in a collection are chunked
/// and embedded.
///
/// Multiple pipelines can be active on the same collection simultaneously (e.g., one
/// for semantic search with a small model, another with a larger model). Each pipeline
/// gets its own embedding table (`<collection>_embeddings_<pipeline_name>`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pipeline {
    /// Unique name for this pipeline within the collection.
    /// Must match `[a-z][a-z0-9_]{0,62}`.
    pub name: String,

    /// Configuration for chunking and embedding.
    pub config: PipelineConfig,
}

impl Pipeline {
    /// Construct a new named pipeline.
    pub fn new(name: impl Into<String>, config: PipelineConfig) -> Self {
        Self {
            name: name.into(),
            config,
        }
    }
}

/// Combined chunking and embedding configuration for a pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipelineConfig {
    /// How document content is split into chunks before embedding.
    pub chunker: ChunkerConfig,

    /// How chunks are embedded (provider URL, model, API key, etc.).
    pub embedding: EmbeddingConfig,
}

/// Controls whether `upsert_documents` blocks until embeddings are committed
/// or returns immediately after submitting the workflow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IngestMode {
    /// Block until the pg_durable ingestion workflow completes and all chunk
    /// embeddings are committed to the database.
    ///
    /// Returns `Err(Error::WorkflowTimeout)` if the workflow does not complete
    /// within the configured timeout (default: 300 seconds).
    Sync,

    /// Submit the pg_durable ingestion workflow and return immediately.
    ///
    /// The `UpsertResult` includes the `instance_id` which the caller can use to
    /// check workflow status via `SELECT df.status('<instance_id>')`.
    Async,
}
