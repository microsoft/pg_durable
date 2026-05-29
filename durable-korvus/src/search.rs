//! Search result type and query building.

use serde::{Deserialize, Serialize};

/// A single result from a vector similarity search.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// Internal stable chunk identifier (hash of collection/doc_id/pipeline/chunk_index).
    pub chunk_id: String,

    /// The caller-supplied document identifier from the originating document.
    pub document_id: String,

    /// The chunk text that was embedded and matched the query.
    pub chunk_text: String,

    /// Zero-based index of this chunk within its parent document.
    pub chunk_index: u32,

    /// The originating document's metadata (JSON).
    pub metadata: serde_json::Value,

    /// Cosine similarity score in [0.0, 1.0]. Higher means more similar to the query.
    pub score: f32,
}

/// Build the SQL query for vector similarity search.
///
/// Returns a parameterized SQL string and the list of parameters:
/// `($1 = pipeline_name, $2 = query_vector, $3 = filter, $4 = k)`.
///
/// # TODO
/// This is a stub. The real implementation will produce the query described in
/// SPEC.md §Search, handling optional filter via SQL conditional logic.
///
/// Expected query shape:
/// ```sql
/// SELECT c.chunk_id, c.document_id, c.chunk_text, c.chunk_index,
///        d.metadata, 1 - (e.embedding <=> $2) AS score
/// FROM <name>_embeddings_<pipeline> e
/// JOIN <name>_chunks c ON c.chunk_id = e.chunk_id
/// JOIN <name>_documents d ON d.id = c.document_id
/// WHERE ($3::jsonb IS NULL OR d.metadata @> $3)
/// ORDER BY e.embedding <=> $2
/// LIMIT $4;
/// ```
pub(crate) fn build_search_sql(_collection_name: &str, _pipeline_name: &str) -> String {
    todo!("build_search_sql is not yet implemented")
}
