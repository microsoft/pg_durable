//! Error types for durable-korvus.

/// The main error type returned by all fallible durable-korvus operations.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A database-level error from sqlx.
    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    /// The provided collection name is invalid.
    /// Collection names must match `[a-z][a-z0-9_]{0,62}`.
    #[error("invalid collection name: {0}")]
    InvalidName(String),

    /// A pipeline with this name already exists on the collection with a different config.
    #[error("pipeline '{0}' already registered with different config")]
    PipelineConflict(String),

    /// No pipeline with this name is registered on the collection.
    #[error("pipeline '{0}' not found")]
    PipelineNotFound(String),

    /// The embedding provider returned vectors of an unexpected dimension.
    #[error("embedding dimension mismatch: expected {expected}, got {actual}")]
    DimensionMismatch { expected: u32, actual: u32 },

    /// The embedding provider returned a non-2xx HTTP status.
    #[error("embedding provider error (HTTP {status}): {body}")]
    EmbeddingProvider { status: u16, body: String },

    /// The pg_durable ingestion workflow failed.
    #[error("ingestion workflow failed: {0}")]
    WorkflowFailed(String),

    /// Waiting for a Sync-mode workflow exceeded the configured timeout.
    #[error("workflow timed out after {0}s")]
    WorkflowTimeout(u64),

    /// JSON serialization or deserialization failed.
    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    /// A catch-all for other errors.
    #[error("{0}")]
    Other(String),
}
