//! Embedding provider configuration and request/response types.

use serde::{Deserialize, Serialize};

/// Configuration for the HTTPS embedding provider.
///
/// All embedding calls are made via `pg_durable`'s `df.http()` function, which
/// runs inside the PostgreSQL background worker. The API key is read from an
/// environment variable at workflow execution time — it is **never stored in the
/// database**.
///
/// Any provider that implements the OpenAI embeddings API format is supported.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingConfig {
    /// Base URL for the embeddings endpoint.
    ///
    /// Examples:
    /// - OpenAI: `"https://api.openai.com/v1/embeddings"`
    /// - Azure OpenAI: `"https://<resource>.openai.azure.com/openai/deployments/<deployment>/embeddings?api-version=2024-02-01"`
    pub provider_url: String,

    /// Model name as expected by the provider.
    ///
    /// Examples: `"text-embedding-3-small"`, `"text-embedding-ada-002"`.
    pub model: String,

    /// Name of the environment variable that holds the API key.
    ///
    /// The environment variable must be set on the PostgreSQL server process
    /// (i.e., in the environment that launches `postgres`). It is read at
    /// workflow execution time by the `pg_durable` background worker.
    pub api_key_env: String,

    /// Expected output vector dimension.
    ///
    /// Must match the actual dimension returned by the provider for the chosen
    /// model. Validated against the first API response; mismatches cause the
    /// workflow to fail with [`Error::DimensionMismatch`].
    pub dimensions: u32,

    /// Maximum number of chunks included in a single embedding API call.
    /// Defaults to `32`.
    #[serde(default = "default_batch_size")]
    pub batch_size: u32,

    /// HTTP request timeout in seconds.
    /// Defaults to `30`.
    #[serde(default = "default_timeout_seconds")]
    pub timeout_seconds: u32,
}

fn default_batch_size() -> u32 {
    32
}

fn default_timeout_seconds() -> u32 {
    30
}

// ---------------------------------------------------------------------------
// Request / Response types (OpenAI embeddings API format)
// ---------------------------------------------------------------------------

/// Request body sent to the embeddings provider.
///
/// Follows the OpenAI embeddings API format.
#[derive(Debug, Serialize)]
pub(crate) struct EmbeddingRequest {
    pub model: String,
    pub input: Vec<String>,
}

/// Full response from the embeddings provider.
#[derive(Debug, Deserialize)]
pub(crate) struct EmbeddingResponse {
    pub data: Vec<EmbeddingObject>,
}

/// A single embedding entry in the provider response.
#[derive(Debug, Deserialize)]
pub(crate) struct EmbeddingObject {
    pub index: usize,
    pub embedding: Vec<f32>,
}

/// Build the JSON request body for a batch of chunk texts.
///
/// # TODO
/// This is a stub. The real implementation will serialize `EmbeddingRequest`
/// and return it as a `serde_json::Value` for use in the `df.http()` DSL call.
pub(crate) fn build_request(chunks: &[String], config: &EmbeddingConfig) -> serde_json::Value {
    let _ = (chunks, config); // suppress unused warnings in stub
    todo!("build_request is not yet implemented")
}

/// Parse the JSON response from the embeddings provider.
///
/// Returns a list of embedding vectors in the same order as the input chunks.
///
/// # Errors
///
/// Returns an error if:
/// - The response cannot be deserialized.
/// - The number of embeddings does not match the number of input chunks.
/// - The embedding dimension does not match `expected_dimensions`.
///
/// # TODO
/// This is a stub.
pub(crate) fn parse_response(
    _response: &serde_json::Value,
    _expected_dimensions: u32,
    _input_count: usize,
) -> Result<Vec<Vec<f32>>, crate::Error> {
    todo!("parse_response is not yet implemented")
}
