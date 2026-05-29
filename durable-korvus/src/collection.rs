//! Collection type: the primary user-facing handle for a durable-korvus collection.

use crate::document::Document;
use crate::error::Error;
use crate::pipeline::{IngestMode, Pipeline};
use crate::search::SearchResult;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;

/// A handle to an open collection in the database.
///
/// Obtain a `Collection` via [`Client::collection`](crate::Client::collection).
/// All operations are async and require a running PostgreSQL connection.
pub struct Collection {
    pub(crate) name: String,
    pub(crate) pool: PgPool,
}

/// Metadata about a collection, returned by [`Client::list_collections`](crate::Client::list_collections).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionInfo {
    pub name: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

/// Result of a successful [`Collection::upsert_documents`] call.
#[derive(Debug, Clone)]
pub struct UpsertResult {
    /// Number of documents upserted.
    pub document_count: u64,
    /// Total number of chunks produced across all documents.
    pub chunk_count: u64,
    /// The pg_durable workflow instance ID for the embedding job.
    /// Can be used to check status via `SELECT df.status('<instance_id>')`.
    pub instance_id: String,
}

impl Collection {
    /// Returns the name of this collection.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Register a pipeline with this collection (idempotent).
    ///
    /// If a pipeline with this name already exists with **identical** config, this is
    /// a no-op. If the config differs, returns [`Error::PipelineConflict`].
    ///
    /// Also creates the per-pipeline embeddings table if it does not already exist.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn add_pipeline(&self, _pipeline: &Pipeline) -> Result<(), Error> {
        todo!("add_pipeline is not yet implemented")
    }

    /// Remove a named pipeline from this collection.
    ///
    /// Drops the corresponding embeddings table (`<name>_embeddings_<pipeline>`).
    /// Returns [`Error::PipelineNotFound`] if the pipeline does not exist.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn remove_pipeline(&self, _name: &str) -> Result<(), Error> {
        todo!("remove_pipeline is not yet implemented")
    }

    /// List all pipelines registered for this collection.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn list_pipelines(&self) -> Result<Vec<Pipeline>, Error> {
        todo!("list_pipelines is not yet implemented")
    }

    /// Upsert documents into this collection.
    ///
    /// For each document:
    /// 1. Insert or update the row in `<name>_documents`.
    /// 2. Delete existing chunks for this document + pipeline.
    /// 3. Run the chunker and insert new chunks.
    ///
    /// Then submits a single pg_durable workflow to embed all new chunks via
    /// HTTPS (using `df.http()` nodes) and write the vectors to the embeddings table.
    ///
    /// If `mode` is [`IngestMode::Sync`], blocks until the workflow completes.
    /// If `mode` is [`IngestMode::Async`], returns immediately with the instance ID.
    ///
    /// # Errors
    ///
    /// - [`Error::PipelineNotFound`] if the pipeline is not registered.
    /// - [`Error::WorkflowFailed`] if the embedding workflow fails (Sync mode).
    /// - [`Error::WorkflowTimeout`] if Sync mode polling exceeds the timeout.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn upsert_documents(
        &self,
        _documents: Vec<Document>,
        _pipeline: &Pipeline,
        _mode: IngestMode,
    ) -> Result<UpsertResult, Error> {
        todo!("upsert_documents is not yet implemented")
    }

    /// Delete documents by ID.
    ///
    /// Cascades to chunks and embeddings via foreign key constraints.
    /// Returns the number of documents deleted.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn delete_documents(&self, _ids: &[&str]) -> Result<u64, Error> {
        todo!("delete_documents is not yet implemented")
    }

    /// Fetch a single document by its user-supplied ID.
    ///
    /// Returns `Ok(None)` if no document with this ID exists in the collection.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn get_document(&self, _id: &str) -> Result<Option<Document>, Error> {
        todo!("get_document is not yet implemented")
    }

    /// Perform vector similarity search over this collection's embeddings.
    ///
    /// The `query` string is embedded via a short-lived pg_durable workflow,
    /// then a cosine similarity search is run against the pipeline's embeddings table.
    ///
    /// # Arguments
    ///
    /// - `query`: natural language query to embed and search.
    /// - `pipeline`: the pipeline whose embeddings to search.
    /// - `k`: number of top results to return.
    /// - `filter`: optional JSONB metadata predicate (`@>` match).
    ///   Example: `Some(json!({"tag": "intro"}))` matches documents whose metadata
    ///   contains `"tag": "intro"`.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn search(
        &self,
        _query: &str,
        _pipeline: &Pipeline,
        _k: u32,
        _filter: Option<serde_json::Value>,
    ) -> Result<Vec<SearchResult>, Error> {
        todo!("search is not yet implemented")
    }

    /// Drop this collection and all its tables.
    ///
    /// This is irreversible. All documents, chunks, embeddings, and pipeline configs
    /// for this collection are permanently deleted.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn delete(self) -> Result<(), Error> {
        todo!("delete is not yet implemented")
    }
}
