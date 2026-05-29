//! Async bulk ingestion example.
//!
//! Demonstrates submitting a large batch of documents for background embedding
//! without blocking the caller. Useful for initial data loads where eventual
//! consistency is acceptable.
//!
//! # TODO: Uncomment and complete once implementation is in place.

// TODO: implement this example once the durable-korvus crate is implemented.
//
// use durable_korvus::{Client, Document, Pipeline, PipelineConfig, ChunkerConfig,
//                      EmbeddingConfig, IngestMode};
// use serde_json::json;
//
// #[tokio::main]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//     let client = Client::connect(&std::env::var("DATABASE_URL")?).await?;
//     let collection = client.collection("bulk_example").await?;
//     let pipeline = Pipeline::new("openai_small", /* config */);
//     collection.add_pipeline(&pipeline).await?;
//
//     // Generate 1000 synthetic documents
//     let docs: Vec<Document> = (0..1000)
//         .map(|i| Document::new(
//             format!("doc_{i}"),
//             format!("Document number {i}. Content goes here."),
//             json!({"index": i}),
//         ))
//         .collect();
//
//     // Submit async — returns immediately
//     let result = collection
//         .upsert_documents(docs, &pipeline, IngestMode::Async)
//         .await?;
//
//     println!("Submitted {} documents for background ingestion.", result.document_count);
//     println!("Workflow instance: {}", result.instance_id);
//     println!("Check status: SELECT df.status('{}');", result.instance_id);
//
//     Ok(())
// }

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
}
