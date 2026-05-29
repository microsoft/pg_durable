//! PostgreSQL client and collection factory.

use crate::collection::{Collection, CollectionInfo};
use crate::error::Error;
use crate::schema::{registry_ddl, validate_name};
use sqlx::PgPool;

/// The main entry point for durable-korvus.
///
/// Holds a connection pool to PostgreSQL and provides methods to open or create
/// collections.
///
/// # Example
///
/// ```rust,no_run
/// # use durable_korvus::Client;
/// # #[tokio::main]
/// # async fn main() -> Result<(), Box<dyn std::error::Error>> {
/// let client = Client::connect("postgres://user:pass@localhost/mydb").await?;
/// let collection = client.collection("my_docs").await?;
/// # Ok(())
/// # }
/// ```
pub struct Client {
    pool: PgPool,
}

impl Client {
    /// Connect to PostgreSQL using a connection URL.
    ///
    /// Also ensures the global `_dk_collections` registry table exists.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Database`] if the connection fails.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn connect(_db_url: &str) -> Result<Self, Error> {
        todo!("Client::connect is not yet implemented")
    }

    /// Open or create a named collection (idempotent).
    ///
    /// Creates the four collection tables if they do not already exist:
    /// `<name>_documents`, `<name>_chunks`, `<name>_pipelines`, and (per pipeline)
    /// `<name>_embeddings_<pipeline>`.
    ///
    /// Also registers the collection in `_dk_collections`.
    ///
    /// # Errors
    ///
    /// - [`Error::InvalidName`] if `name` does not match `[a-z][a-z0-9_]{0,62}`.
    /// - [`Error::Database`] if table creation fails.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn collection(&self, name: &str) -> Result<Collection, Error> {
        validate_name(name)?;
        // TODO: create collection tables via schema.rs, register in _dk_collections
        let _ = registry_ddl(); // suppress unused warning in stub
        Ok(Collection {
            name: name.to_owned(),
            pool: self.pool.clone(),
        })
    }

    /// List all collections managed by durable-korvus in this database.
    ///
    /// Queries the `_dk_collections` registry table.
    ///
    /// # TODO
    /// Stub — not yet implemented.
    pub async fn list_collections(&self) -> Result<Vec<CollectionInfo>, Error> {
        todo!("list_collections is not yet implemented")
    }
}
