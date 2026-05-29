//! DDL generation and collection table management.
//!
//! All table creation is idempotent (`CREATE TABLE IF NOT EXISTS`).
//! Future schema migrations use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.

/// Validate a collection or pipeline name.
///
/// Names must match `[a-z][a-z0-9_]{0,62}`:
/// - Lowercase ASCII only
/// - Start with a letter
/// - Alphanumeric or underscores
/// - 1–63 characters total
///
/// This prevents SQL injection in dynamic DDL statements where the name is
/// used as an identifier (not a parameter).
pub(crate) fn validate_name(name: &str) -> Result<(), crate::Error> {
    if name.is_empty()
        || name.len() > 63
        || !name.starts_with(|c: char| c.is_ascii_lowercase())
        || !name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    {
        return Err(crate::Error::InvalidName(name.to_owned()));
    }
    Ok(())
}

/// DDL to create the global collection registry table.
///
/// This table tracks all collections managed by durable-korvus in the database.
pub(crate) fn registry_ddl() -> &'static str {
    "CREATE TABLE IF NOT EXISTS _dk_collections (
        name        TEXT PRIMARY KEY,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
    );"
}

/// DDL to create the per-collection documents table.
pub(crate) fn documents_ddl(collection: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {collection}_documents (
            id          TEXT PRIMARY KEY,
            content     TEXT NOT NULL,
            metadata    JSONB NOT NULL DEFAULT '{{}}',
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        );"
    )
}

/// DDL to create the per-collection chunks table.
pub(crate) fn chunks_ddl(collection: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {collection}_chunks (
            chunk_id     TEXT PRIMARY KEY,
            document_id  TEXT NOT NULL REFERENCES {collection}_documents(id) ON DELETE CASCADE,
            pipeline     TEXT NOT NULL,
            chunk_index  INT NOT NULL,
            chunk_text   TEXT NOT NULL,
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (document_id, pipeline, chunk_index)
        );
        CREATE INDEX IF NOT EXISTS {collection}_chunks_doc_pipeline_idx
            ON {collection}_chunks (document_id, pipeline);"
    )
}

/// DDL to create the per-pipeline embeddings table.
///
/// The `dimensions` parameter sets the vector column width, which is fixed for
/// the lifetime of the table and must match the pipeline's `EmbeddingConfig.dimensions`.
///
/// Per [ADR-3](../ARCHITECTURE.md#adr-3-per-pipeline-embedding-tables), there is one
/// embedding table per pipeline to support multiple pipelines with different dimensions
/// on the same collection.
pub(crate) fn embeddings_ddl(collection: &str, pipeline: &str, dimensions: u32) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {collection}_embeddings_{pipeline} (
            chunk_id     TEXT NOT NULL
                         REFERENCES {collection}_chunks(chunk_id) ON DELETE CASCADE,
            embedding    vector({dimensions}),
            created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (chunk_id)
        );
        CREATE INDEX IF NOT EXISTS {collection}_embeddings_{pipeline}_hnsw_idx
            ON {collection}_embeddings_{pipeline}
            USING hnsw (embedding vector_cosine_ops);"
    )
}

/// DDL to create the per-collection pipeline registry table.
pub(crate) fn pipelines_ddl(collection: &str) -> String {
    format!(
        "CREATE TABLE IF NOT EXISTS {collection}_pipelines (
            name        TEXT PRIMARY KEY,
            config      JSONB NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        );"
    )
}

// TODO: implement create_collection_tables(pool, name) and drop_collection_tables(pool, name)
// using sqlx::PgPool once implementation begins.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_names_are_accepted() {
        assert!(validate_name("my_collection").is_ok());
        assert!(validate_name("a").is_ok());
        assert!(validate_name("abc123").is_ok());
        assert!(validate_name("a_b_c").is_ok());
    }

    #[test]
    fn invalid_names_are_rejected() {
        assert!(validate_name("").is_err());
        assert!(validate_name("MyCollection").is_err()); // uppercase
        assert!(validate_name("1collection").is_err()); // starts with digit
        assert!(validate_name("col-lection").is_err()); // hyphen not allowed
        assert!(validate_name(&"a".repeat(64)).is_err()); // too long
    }
}
