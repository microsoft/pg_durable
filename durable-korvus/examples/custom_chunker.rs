//! Custom chunker (UserProvided) example.
//!
//! Demonstrates using `ChunkerConfig::UserProvided` when the caller handles
//! chunking themselves (e.g., using a token-aware chunker from another library).
//!
//! Each document passed to `upsert_documents` is treated as a single chunk.
//! The caller is responsible for splitting documents into appropriately-sized pieces
//! before calling `upsert_documents`.
//!
//! # TODO: Uncomment and complete once implementation is in place.

// TODO: implement this example once the durable-korvus crate is implemented.
//
// use durable_korvus::{Client, Document, Pipeline, PipelineConfig, ChunkerConfig,
//                      EmbeddingConfig, IngestMode};
// use serde_json::json;
//
// /// Simple token-count estimator (4 chars ≈ 1 token).
// fn split_into_chunks(text: &str, max_tokens: usize) -> Vec<String> {
//     let max_chars = max_tokens * 4;
//     text.chars()
//         .collect::<Vec<_>>()
//         .chunks(max_chars)
//         .enumerate()
//         .map(|(_, c)| c.iter().collect())
//         .collect()
// }
//
// #[tokio::main]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//     let client = Client::connect(&std::env::var("DATABASE_URL")?).await?;
//     let collection = client.collection("custom_chunks").await?;
//
//     let pipeline = Pipeline::new(
//         "user_chunks",
//         PipelineConfig {
//             chunker: ChunkerConfig::UserProvided,  // <-- no automatic splitting
//             embedding: EmbeddingConfig {
//                 provider_url: "https://api.openai.com/v1/embeddings".into(),
//                 model: "text-embedding-3-small".into(),
//                 api_key_env: "OPENAI_API_KEY".into(),
//                 dimensions: 1536,
//                 batch_size: 32,
//                 timeout_seconds: 30,
//             },
//         },
//     );
//     collection.add_pipeline(&pipeline).await?;
//
//     let long_document = "A very long document that needs to be split into chunks...";
//
//     // Caller splits the document into chunks (max 256 tokens each)
//     let chunks = split_into_chunks(long_document, 256);
//
//     // Each chunk is submitted as a separate Document with a derived ID
//     let docs: Vec<Document> = chunks
//         .into_iter()
//         .enumerate()
//         .map(|(i, chunk_text)| Document::new(
//             format!("long_doc_chunk_{i}"),
//             chunk_text,
//             json!({"source_doc": "long_doc", "chunk_index": i}),
//         ))
//         .collect();
//
//     collection
//         .upsert_documents(docs, &pipeline, IngestMode::Sync)
//         .await?;
//
//     println!("Custom-chunked documents ingested successfully.");
//     Ok(())
// }

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
}
