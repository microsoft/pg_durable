//! Document type for durable-korvus.

use serde::{Deserialize, Serialize};

/// A user-supplied text document to be stored, chunked, and embedded.
///
/// Documents are identified by a caller-supplied stable `id`. Upserting a document
/// with the same `id` replaces the previous version and re-runs chunking + embedding.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    /// Stable user-supplied identifier. Used as the upsert key.
    /// Must be non-empty.
    pub id: String,

    /// Full text content to be chunked and embedded.
    /// Must be non-empty.
    pub content: String,

    /// Arbitrary JSON metadata stored alongside the document.
    /// Filterable at search time using JSON predicate matching.
    pub metadata: serde_json::Value,
}

impl Document {
    /// Construct a new document.
    ///
    /// # Panics
    ///
    /// Does not panic. Validation is deferred to [`Collection::upsert_documents`].
    pub fn new(
        id: impl Into<String>,
        content: impl Into<String>,
        metadata: serde_json::Value,
    ) -> Self {
        Self {
            id: id.into(),
            content: content.into(),
            metadata,
        }
    }
}
