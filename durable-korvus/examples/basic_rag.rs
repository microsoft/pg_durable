//! Basic RAG example: ingest documents and search.
//!
//! This example demonstrates the full RAG write + read path:
//! 1. Create a collection
//! 2. Register an embedding pipeline
//! 3. Upsert documents (sync — blocks until embeddings are committed)
//! 4. Search using a natural language query
//!
//! # Prerequisites
//!
//! - PostgreSQL 17 with `pgvector` and `pg_durable` extensions installed
//! - `OPENAI_API_KEY` environment variable set on the PostgreSQL server process
//! - `DATABASE_URL` environment variable set to a PostgreSQL connection string
//!
//! # Running
//!
//! ```bash
//! DATABASE_URL=postgres://localhost/mydb cargo run --example basic_rag
//! ```
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
//     let db_url = std::env::var("DATABASE_URL")
//         .expect("DATABASE_URL must be set");
//
//     // Connect and open (or create) a collection
//     let client = Client::connect(&db_url).await?;
//     let collection = client.collection("rag_example").await?;
//
//     // Define the embedding pipeline
//     let pipeline = Pipeline::new(
//         "openai_small",
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
//     // Ingest documents synchronously
//     let result = collection.upsert_documents(
//         vec![
//             Document::new(
//                 "rust-intro",
//                 "Rust is a systems programming language focused on safety, speed, \
//                  and concurrency. It achieves memory safety without a garbage collector.",
//                 json!({"topic": "programming", "language": "rust"}),
//             ),
//             Document::new(
//                 "pgvector-intro",
//                 "pgvector is a PostgreSQL extension for vector similarity search. \
//                  It supports L2 distance, inner product, and cosine distance.",
//                 json!({"topic": "database", "extension": "pgvector"}),
//             ),
//             Document::new(
//                 "pg-durable-intro",
//                 "pg_durable is a PostgreSQL extension that provides durable SQL \
//                  function execution, surviving server restarts and crashes.",
//                 json!({"topic": "database", "extension": "pg_durable"}),
//             ),
//         ],
//         &pipeline,
//         IngestMode::Sync,
//     ).await?;
//
//     println!(
//         "Ingested {} documents, {} chunks (workflow: {})",
//         result.document_count, result.chunk_count, result.instance_id
//     );
//
//     // Search
//     let results = collection
//         .search("memory safety without garbage collection", &pipeline, 3, None)
//         .await?;
//
//     println!("\nSearch results:");
//     for r in &results {
//         println!("  [{:.4}] {} — {}", r.score, r.document_id, &r.chunk_text[..80.min(r.chunk_text.len())]);
//     }
//
//     Ok(())
// }

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
}
