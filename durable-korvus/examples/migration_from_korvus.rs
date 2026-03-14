//! Side-by-side migration example: Korvus → durable-korvus.
//!
//! This example shows how Korvus code maps to durable-korvus code.
//! Comments show the original Korvus pattern alongside the durable-korvus equivalent.
//!
//! See also: README.md §Migration Guide for a full concept-level comparison.
//!
//! # TODO: Uncomment and complete once implementation is in place.

// KORVUS (original):
// -----------------------------------------------------------------
// use korvus::Collection;
//
// #[tokio::main]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//     // 1. Create a collection (Korvus)
//     let mut collection = Collection::new("semantic_search", None)?;
//
//     // 2. Upsert documents (Korvus)
//     //    - document content lives inside a "document" key
//     //    - pipeline is implicit (configured at collection level)
//     collection.upsert_documents(serde_json::json!([
//         {"id": "doc1", "document": {"text": "Rust is fast and safe", "tag": "intro"}},
//         {"id": "doc2", "document": {"text": "pgvector enables vector search", "tag": "db"}},
//     ])).await?;
//
//     // 3. Search (Korvus)
//     //    - query wrapped in a nested JSON structure
//     let results = collection.vector_search(
//         serde_json::json!({"query": {"fields": {"document": {"query": "fast systems"}}}}),
//         &pipeline,
//     ).await?;
//
//     for r in &results {
//         println!("{}", r["chunk"]);
//     }
//     Ok(())
// }
// -----------------------------------------------------------------

// DURABLE-KORVUS (equivalent):
// -----------------------------------------------------------------
// use durable_korvus::{Client, Document, Pipeline, PipelineConfig, ChunkerConfig,
//                      EmbeddingConfig, IngestMode};
// use serde_json::json;
//
// #[tokio::main]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//     let client = Client::connect(&std::env::var("DATABASE_URL")?).await?;
//
//     // 1. Create a collection (durable-korvus)
//     //    - async, returns a Collection handle
//     let collection = client.collection("semantic_search").await?;
//
//     // 2. Pipeline is now explicit — define it separately and add to the collection
//     let pipeline = Pipeline::new(
//         "default",
//         PipelineConfig {
//             chunker: ChunkerConfig::FixedSize { size: 512, overlap: 64 },
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
//     // 3. Upsert documents (durable-korvus)
//     //    - content is a top-level field, not nested
//     //    - metadata is explicitly typed as serde_json::Value
//     //    - pipeline is explicit
//     //    - mode controls sync vs async ingestion
//     collection.upsert_documents(
//         vec![
//             Document::new("doc1", "Rust is fast and safe", json!({"tag": "intro"})),
//             Document::new("doc2", "pgvector enables vector search", json!({"tag": "db"})),
//         ],
//         &pipeline,
//         IngestMode::Sync,  // wait for embeddings before returning
//     ).await?;
//
//     // 4. Search (durable-korvus)
//     //    - query is a plain string
//     //    - k and filter are explicit parameters
//     let results = collection
//         .search("fast systems", &pipeline, 5, None)
//         .await?;
//
//     for r in &results {
//         println!("[{:.4}] {}  {}", r.score, r.document_id, r.chunk_text);
//     }
//     Ok(())
// }
// -----------------------------------------------------------------

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
    println!();
    println!("Key migration changes:");
    println!("  - collection.upsert_documents() now takes (docs, pipeline, mode)");
    println!("  - Document content is a top-level field, not nested in 'document' key");
    println!("  - Pipeline configuration is explicit and typed (not YAML/JSON config)");
    println!("  - Search takes (query_str, pipeline, k, filter) not a nested JSON object");
    println!("  - Embedding uses OpenAI-compatible HTTPS endpoint, not PostgresML");
}
