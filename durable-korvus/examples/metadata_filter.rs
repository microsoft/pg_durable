//! Metadata filtering example.
//!
//! Demonstrates filtering search results to documents matching a JSON predicate
//! on their metadata field.
//!
//! # TODO: Uncomment and complete once implementation is in place.

// TODO: implement this example once the durable-korvus crate is implemented.
//
// use durable_korvus::{Client, Pipeline, IngestMode};
// use serde_json::json;
//
// #[tokio::main]
// async fn main() -> Result<(), Box<dyn std::error::Error>> {
//     let client = Client::connect(&std::env::var("DATABASE_URL")?).await?;
//     let collection = client.collection("filtered_search").await?;
//     let pipeline = Pipeline::new("openai_small", /* config */);
//
//     // Search only documents tagged as "technical"
//     let technical_results = collection
//         .search(
//             "database performance",
//             &pipeline,
//             5,
//             Some(json!({"category": "technical"})),
//         )
//         .await?;
//
//     println!("Technical results: {}", technical_results.len());
//
//     // Search only documents from a specific source
//     let blog_results = collection
//         .search(
//             "database performance",
//             &pipeline,
//             5,
//             Some(json!({"source": "blog", "category": "technical"})),
//         )
//         .await?;
//
//     println!("Blog + technical results: {}", blog_results.len());
//
//     Ok(())
// }

fn main() {
    println!("This example is a placeholder. Uncomment the code once the crate is implemented.");
}
