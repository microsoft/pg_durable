//! Chunker configuration and chunking logic.

use serde::{Deserialize, Serialize};

/// Configuration for how documents are split into chunks before embedding.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ChunkerConfig {
    /// Split document content into fixed-size character windows with optional overlap.
    FixedSize {
        /// Window size in characters.
        size: usize,
        /// Number of characters shared between adjacent chunks.
        /// Must be less than `size`.
        overlap: usize,
    },

    /// The caller is responsible for supplying pre-chunked content.
    /// When this is selected, documents passed to `upsert_documents` must each
    /// have their content set to a single chunk (i.e., no automatic splitting occurs).
    UserProvided,
}

/// A single chunk produced by the chunker: `(chunk_index, chunk_text)`.
pub type Chunk = (usize, String);

/// Split `content` into chunks according to `config`.
///
/// Returns a list of `(chunk_index, chunk_text)` pairs, with empty/whitespace-only
/// trailing chunks omitted.
///
/// # TODO
/// - Add token-based chunking variant (`FixedSizeTokens`).
/// - Add sentence-aware chunking variant.
pub fn chunk(content: &str, config: &ChunkerConfig) -> Vec<Chunk> {
    match config {
        ChunkerConfig::UserProvided => {
            // The content is already a single chunk.
            vec![(0, content.to_owned())]
        }
        ChunkerConfig::FixedSize { size, overlap } => {
            chunk_fixed_size(content, *size, *overlap)
        }
    }
}

fn chunk_fixed_size(content: &str, size: usize, overlap: usize) -> Vec<Chunk> {
    // TODO: implement fixed-size character-based chunking with overlap.
    // This is a stub; the real implementation will iterate over the content
    // using character indices and produce non-empty windows.
    //
    // Expected algorithm:
    //   step = size - overlap
    //   for i in 0.. {
    //       start = i * step
    //       if start >= content.len() { break }
    //       end = min(start + size, content.len())
    //       chunk_text = content[start..end].trim()
    //       if !chunk_text.is_empty() { push (i, chunk_text) }
    //   }
    let _ = (content, size, overlap); // suppress unused warnings in stub
    todo!("FixedSize chunker is not yet implemented — see SPEC.md §Chunking")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_provided_returns_content_as_single_chunk() {
        let chunks = chunk("hello world", &ChunkerConfig::UserProvided);
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].0, 0);
        assert_eq!(chunks[0].1, "hello world");
    }
}
