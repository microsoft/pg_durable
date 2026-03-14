//! Azure OpenAI embeddings provider example.
//!
//! Demonstrates configuring `EmbeddingConfig` for an Azure OpenAI endpoint.
//!
//! # Environment Variables (set on the PostgreSQL server process)
//!
//! - `AZURE_OPENAI_API_KEY`: Your Azure OpenAI API key
//!
//! # Azure OpenAI Endpoint Format
//!
//! ```
//! https://<resource-name>.openai.azure.com/openai/deployments/<deployment-name>/embeddings?api-version=2024-02-01
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
//     let resource = std::env::var("AZURE_OPENAI_RESOURCE").unwrap_or("myresource".into());
//     let deployment = std::env::var("AZURE_OPENAI_DEPLOYMENT").unwrap_or("text-embedding-3-small".into());
//     let api_version = "2024-02-01";
//
//     let azure_url = format!(
//         "https://{resource}.openai.azure.com/openai/deployments/{deployment}/embeddings?api-version={api_version}"
//     );
//
//     let client = Client::connect(&std::env::var("DATABASE_URL")?).await?;
//     let collection = client.collection("azure_rag").await?;
//
//     let pipeline = Pipeline::new(
//         "azure_embedding",
//         PipelineConfig {
//             chunker: ChunkerConfig::FixedSize { size: 512, overlap: 64 },
//             embedding: EmbeddingConfig {
//                 provider_url: azure_url,
//                 model: deployment,  // Azure uses deployment name as model
//                 api_key_env: "AZURE_OPENAI_API_KEY".into(),
//                 dimensions: 1536,   // text-embedding-3-small default
//                 batch_size: 16,     // Azure may have lower rate limits; reduce batch size
//                 timeout_seconds: 60,
//             },
//         },
//     );
//     collection.add_pipeline(&pipeline).await?;
//
//     collection.upsert_documents(
//         vec![Document::new(
//             "azure-doc-1",
//             "Azure OpenAI Service provides REST API access to OpenAI's powerful language models.",
//             json!({"source": "azure-docs"}),
//         )],
//         &pipeline,
//         IngestMode::Sync,
//     ).await?;
//
//     let results = collection
//         .search("Azure language models", &pipeline, 3, None)
//         .await?;
//
//     for r in &results {
//         println!("[{:.4}] {}", r.score, r.chunk_text);
//     }
//
//     Ok(())
// }

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
    println!();
    println!("Azure OpenAI endpoint format:");
    println!("  https://<resource>.openai.azure.com/openai/deployments/<deployment>/embeddings?api-version=2024-02-01");
    println!();
    println!("Set AZURE_OPENAI_API_KEY on the PostgreSQL server process.");
}
