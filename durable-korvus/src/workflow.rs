//! pg_durable workflow construction and submission.
//!
//! This module builds the `df.start()` DSL expressions used to submit durable
//! ingestion workflows, and provides helpers for polling workflow status in Sync mode.
//!
//! See [ARCHITECTURE.md §pg_durable Workflow Graph](../ARCHITECTURE.md#pg_durable-workflow-graph)
//! for the intended workflow structure.

/// Build the pg_durable DSL expression for an ingestion workflow.
///
/// The workflow graph is a sequential chain of `df.sql()` and `df.http()` nodes:
///
/// ```text
/// df.sql("INSERT chunks...")
/// ~> df.http(embed_batch_0)
/// ~> df.sql("INSERT embeddings batch_0")
/// ~> df.http(embed_batch_1)
/// ~> df.sql("INSERT embeddings batch_1")
/// ~> ...
/// ~> df.sql("UPDATE status = complete")
/// ```
///
/// # Arguments
///
/// - `collection`: validated collection name
/// - `pipeline`: validated pipeline name
/// - `chunk_batches`: pre-chunked text batches to embed (one `df.http()` node per batch)
/// - `embedding_config`: provider URL, model, API key env var, etc.
///
/// # Returns
///
/// A SQL string suitable for passing to `df.start()`:
/// ```sql
/// SELECT df.start(<dsl_expression>, 'durable-korvus:ingest:<collection>:<pipeline>');
/// ```
///
/// # TODO
/// This is a stub. Real implementation will construct the DSL string by concatenating
/// `df.sql(...)` and `df.http(...)` calls joined with `~>`.
pub(crate) fn build_ingestion_workflow(
    _collection: &str,
    _pipeline: &str,
    _chunk_batches: &[Vec<String>],
    _embedding_config: &crate::embeddings::EmbeddingConfig,
) -> String {
    todo!("build_ingestion_workflow is not yet implemented")
}

/// Build the pg_durable DSL expression for embedding a single search query.
///
/// This is a single-node workflow containing one `df.http()` call. It is awaited
/// synchronously in the search path.
///
/// # TODO
/// This is a stub.
pub(crate) fn build_query_embedding_workflow(
    _query: &str,
    _embedding_config: &crate::embeddings::EmbeddingConfig,
) -> String {
    todo!("build_query_embedding_workflow is not yet implemented")
}
