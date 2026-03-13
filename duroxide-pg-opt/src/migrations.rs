use anyhow::Result;
use include_dir::{include_dir, Dir};
use sqlx::Connection;
use sqlx::PgPool;
use std::sync::Arc;

static MIGRATIONS: Dir = include_dir!("$CARGO_MANIFEST_DIR/migrations");

/// Migration metadata
#[derive(Debug)]
struct Migration {
    version: i64,
    name: String,
    sql: String,
}

/// Migration runner that handles schema-qualified migrations
pub struct MigrationRunner {
    pool: Arc<PgPool>,
    schema_name: String,
}

impl MigrationRunner {
    /// Create a new migration runner
    pub fn new(pool: Arc<PgPool>, schema_name: String) -> Self {
        Self { pool, schema_name }
    }

    fn advisory_lock_key(&self) -> i64 {
        // Stable 64-bit FNV-1a hash over (namespace + schema name).
        // This avoids using Rust's DefaultHasher (randomized per-process).
        const OFFSET: u64 = 0xcbf29ce484222325;
        const PRIME: u64 = 0x100000001b3;

        let mut hash = OFFSET;
        for b in b"duroxide_pg_opt:migrations:" {
            hash ^= *b as u64;
            hash = hash.wrapping_mul(PRIME);
        }
        for b in self.schema_name.as_bytes() {
            hash ^= *b as u64;
            hash = hash.wrapping_mul(PRIME);
        }

        hash as i64
    }

    async fn lock_for_migrations(&self, conn: &mut sqlx::postgres::PgConnection) -> Result<()> {
        let key = self.advisory_lock_key();
        // Session lock (not xact lock) so it spans multiple transactions.
        // We explicitly unlock at the end.
        sqlx::query("SELECT pg_advisory_lock($1)")
            .bind(key)
            .execute(&mut *conn)
            .await?;
        Ok(())
    }

    async fn unlock_for_migrations(&self, conn: &mut sqlx::postgres::PgConnection) {
        let key = self.advisory_lock_key();
        // Best-effort unlock.
        let _ = sqlx::query("SELECT pg_advisory_unlock($1)")
            .bind(key)
            .execute(&mut *conn)
            .await;
    }

    /// Run all pending migrations
    pub async fn migrate(&self) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        let conn = &mut *conn;
        self.lock_for_migrations(conn).await?;

        let result = self.migrate_inner(conn).await;
        self.unlock_for_migrations(conn).await;

        result
    }

    async fn migrate_inner(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
    ) -> Result<()> {
        // Ensure schema exists
        if self.schema_name != "public" {
            sqlx::query(&format!("CREATE SCHEMA IF NOT EXISTS {}", self.schema_name))
                .execute(&mut *conn)
                .await?;
        }

        // Load migrations from filesystem
        let migrations = self.load_migrations()?;

        tracing::debug!(
            "Loaded {} migrations for schema {}",
            migrations.len(),
            self.schema_name
        );

        // Ensure migration tracking table exists (in the schema)
        self.ensure_migration_table(conn).await?;

        // Get applied migrations
        let applied_versions = self.get_applied_versions(conn).await?;

        tracing::debug!("Applied migrations: {:?}", applied_versions);

        // Check if key tables exist - if not, we need to re-run migrations even if marked as applied
        // This handles the case where cleanup dropped tables but not the migration tracking table
        let tables_exist = self.check_tables_exist(conn).await.unwrap_or(false);

        // Apply pending migrations (or re-apply if tables don't exist)
        for migration in migrations {
            let should_apply = if !applied_versions.contains(&migration.version) {
                true // New migration
            } else if !tables_exist {
                // Migration was applied but tables don't exist - re-apply
                tracing::warn!(
                    "Migration {} is marked as applied but tables don't exist, re-applying",
                    migration.version
                );
                // Remove the old migration record so we can re-apply
                sqlx::query(&format!(
                    "DELETE FROM {}._duroxide_migrations WHERE version = $1",
                    self.schema_name
                ))
                .bind(migration.version)
                .execute(&mut *conn)
                .await?;
                true
            } else {
                false // Already applied and tables exist
            };

            if should_apply {
                tracing::debug!(
                    "Applying migration {}: {}",
                    migration.version,
                    migration.name
                );
                self.apply_migration(conn, &migration).await?;
            } else {
                tracing::debug!(
                    "Skipping migration {}: {} (already applied)",
                    migration.version,
                    migration.name
                );
            }
        }

        Ok(())
    }

    /// Verify that the schema is fully migrated. Executes no DDL.
    pub async fn verify(&self) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        let conn = &mut *conn;

        // 1. Check schema exists
        if self.schema_name != "public" {
            let schema_exists = self.check_schema_exists(conn).await?;
            if !schema_exists {
                anyhow::bail!(
                    "Schema '{}' does not exist. Cannot verify migrations.",
                    self.schema_name
                );
            }
        }

        // 2. Check tracking table exists
        let tracking_table_exists = self.check_migration_table_exists(conn).await?;
        if !tracking_table_exists {
            anyhow::bail!(
                "Migration tracking table does not exist in schema '{}'. Schema has not been initialized.",
                self.schema_name
            );
        }

        // 3. Check all migrations are applied
        let applied_versions = self.get_applied_versions(conn).await?;
        let expected_migrations = self.load_migrations()?;

        let mut missing = Vec::new();
        for migration in &expected_migrations {
            if !applied_versions.contains(&migration.version) {
                missing.push(format!("{} ({})", migration.version, migration.name));
            }
        }

        if !missing.is_empty() {
            anyhow::bail!(
                "Schema '{}' is behind the expected migration version. Missing migrations: {}. Run migrations before connecting with VerifyOnly policy.",
                self.schema_name,
                missing.join(", ")
            );
        }

        tracing::info!(
            "Schema '{}' verified: {} migrations applied",
            self.schema_name,
            applied_versions.len()
        );

        Ok(())
    }

    /// Check that the database has no migrations the code doesn't recognize.
    pub async fn check_no_unknown_migrations(&self) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        let conn = &mut *conn;

        // Skip if tracking table doesn't exist (ApplyAll will create it;
        // VerifyOnly will have already errored)
        if !self.check_migration_table_exists(conn).await? {
            return Ok(());
        }

        let applied_versions = self.get_applied_versions(conn).await?;
        let expected_migrations = self.load_migrations()?;
        let expected_versions: std::collections::HashSet<i64> =
            expected_migrations.iter().map(|m| m.version).collect();

        let unknown: Vec<i64> = applied_versions
            .iter()
            .filter(|v| !expected_versions.contains(v))
            .copied()
            .collect();

        if !unknown.is_empty() {
            anyhow::bail!(
                "Schema '{}' has migrations not recognized by this version of the code: {:?}. The database schema is ahead of the code. Update the code or downgrade the schema.",
                self.schema_name,
                unknown
            );
        }

        Ok(())
    }

    /// Load migrations from the embedded migrations directory
    fn load_migrations(&self) -> Result<Vec<Migration>> {
        let mut migrations = Vec::new();

        // Get all files from embedded directory
        let mut files: Vec<_> = MIGRATIONS
            .files()
            .filter(|file| file.path().extension().and_then(|ext| ext.to_str()) == Some("sql"))
            .collect();

        // Sort by path to ensure consistent ordering
        files.sort_by_key(|f| f.path());

        for file in files {
            let file_name = file
                .path()
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| anyhow::anyhow!("Invalid filename in migrations"))?;

            let sql = file
                .contents_utf8()
                .ok_or_else(|| anyhow::anyhow!("Migration file is not valid UTF-8: {file_name}"))?
                .to_string();

            let version = self.parse_version(file_name)?;
            let name = file_name.to_string();

            migrations.push(Migration { version, name, sql });
        }

        Ok(migrations)
    }

    /// Parse version number from migration filename (e.g., "0001_initial.sql" -> 1)
    fn parse_version(&self, filename: &str) -> Result<i64> {
        let version_str = filename
            .split('_')
            .next()
            .ok_or_else(|| anyhow::anyhow!("Invalid migration filename: {filename}"))?;

        version_str
            .parse::<i64>()
            .map_err(|e| anyhow::anyhow!("Invalid migration version {version_str}: {e}"))
    }

    /// Ensure migration tracking table exists
    async fn ensure_migration_table(&self, conn: &mut sqlx::postgres::PgConnection) -> Result<()> {
        // Create migration table in the target schema
        sqlx::query(&format!(
            r#"
            CREATE TABLE IF NOT EXISTS {}._duroxide_migrations (
                version BIGINT PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
            )
            "#,
            self.schema_name
        ))
        .execute(&mut *conn)
        .await?;

        Ok(())
    }

    /// Check if key tables exist
    async fn check_tables_exist(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
    ) -> Result<bool> {
        // Check if instances table exists (as a proxy for all tables)
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'instances')",
        )
        .bind(&self.schema_name)
        .fetch_one(&mut *conn)
        .await?;

        Ok(exists)
    }

    /// Get list of applied migration versions
    async fn get_applied_versions(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
    ) -> Result<Vec<i64>> {
        let versions: Vec<i64> = sqlx::query_scalar(&format!(
            "SELECT version FROM {}._duroxide_migrations ORDER BY version",
            self.schema_name
        ))
        .fetch_all(&mut *conn)
        .await?;

        Ok(versions)
    }

    async fn check_schema_exists(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
    ) -> Result<bool> {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
        )
        .bind(&self.schema_name)
        .fetch_one(&mut *conn)
        .await?;

        Ok(exists)
    }

    async fn check_migration_table_exists(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
    ) -> Result<bool> {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = '_duroxide_migrations')",
        )
        .bind(&self.schema_name)
        .fetch_one(&mut *conn)
        .await?;

        Ok(exists)
    }

    /// Split SQL into statements, respecting dollar-quoted strings ($$...$$)
    /// This handles stored procedures and other constructs that use dollar-quoting
    fn split_sql_statements(sql: &str) -> Vec<String> {
        let mut statements = Vec::new();
        let mut current_statement = String::new();
        let chars: Vec<char> = sql.chars().collect();
        let mut i = 0;
        let mut in_dollar_quote = false;
        let mut dollar_tag: Option<String> = None;

        while i < chars.len() {
            let ch = chars[i];

            if !in_dollar_quote {
                // Check for start of dollar-quoted string
                if ch == '$' {
                    let mut tag = String::new();
                    tag.push(ch);
                    i += 1;

                    // Collect the tag (e.g., $$, $tag$, $function$)
                    while i < chars.len() {
                        let next_ch = chars[i];
                        if next_ch == '$' {
                            tag.push(next_ch);
                            dollar_tag = Some(tag.clone());
                            in_dollar_quote = true;
                            current_statement.push_str(&tag);
                            i += 1;
                            break;
                        } else if next_ch.is_alphanumeric() || next_ch == '_' {
                            tag.push(next_ch);
                            i += 1;
                        } else {
                            // Not a dollar quote, just a $ character
                            current_statement.push(ch);
                            break;
                        }
                    }
                } else if ch == ';' {
                    // End of statement (only if not in dollar quote)
                    current_statement.push(ch);
                    let trimmed = current_statement.trim().to_string();
                    if !trimmed.is_empty() {
                        statements.push(trimmed);
                    }
                    current_statement.clear();
                    i += 1;
                } else {
                    current_statement.push(ch);
                    i += 1;
                }
            } else {
                // Inside dollar-quoted string
                current_statement.push(ch);

                // Check for end of dollar-quoted string
                if ch == '$' {
                    let tag = dollar_tag.as_ref().unwrap();
                    let mut matches = true;

                    // Check if the following characters match the closing tag
                    for (j, tag_char) in tag.chars().enumerate() {
                        if j == 0 {
                            continue; // Skip first $ (we already matched it)
                        }
                        if i + j >= chars.len() || chars[i + j] != tag_char {
                            matches = false;
                            break;
                        }
                    }

                    if matches {
                        // Found closing tag - consume remaining tag characters
                        for _ in 0..(tag.len() - 1) {
                            if i + 1 < chars.len() {
                                current_statement.push(chars[i + 1]);
                                i += 1;
                            }
                        }
                        in_dollar_quote = false;
                        dollar_tag = None;
                    }
                }
                i += 1;
            }
        }

        // Add remaining statement if any
        let trimmed = current_statement.trim().to_string();
        if !trimmed.is_empty() {
            statements.push(trimmed);
        }

        statements
    }

    /// Apply a single migration
    async fn apply_migration(
        &self,
        conn: &mut sqlx::postgres::PgConnection,
        migration: &Migration,
    ) -> Result<()> {
        // Start transaction
        let mut tx = conn.begin().await?;

        // Set search_path for this transaction
        sqlx::query(&format!("SET LOCAL search_path TO {}", self.schema_name))
            .execute(&mut *tx)
            .await?;

        // Remove comment lines and split SQL into individual statements
        let sql = migration.sql.trim();
        let cleaned_sql: String = sql
            .lines()
            .map(|line| {
                // Remove full-line comments
                if let Some(idx) = line.find("--") {
                    // Check if -- is inside a string (simple check)
                    let before = &line[..idx];
                    if before.matches('\'').count() % 2 == 0 {
                        // Even number of quotes means -- is not in a string
                        line[..idx].trim()
                    } else {
                        line
                    }
                } else {
                    line
                }
            })
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join("\n");

        // Split by semicolon, but respect dollar-quoted strings ($$...$$)
        let statements = Self::split_sql_statements(&cleaned_sql);

        tracing::debug!(
            "Executing {} statements for migration {}",
            statements.len(),
            migration.version
        );

        for (idx, statement) in statements.iter().enumerate() {
            if !statement.trim().is_empty() {
                tracing::debug!(
                    "Executing statement {} of {}: {}...",
                    idx + 1,
                    statements.len(),
                    &statement.chars().take(50).collect::<String>()
                );
                sqlx::query(statement)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| {
                        anyhow::anyhow!(
                            "Failed to execute statement {} in migration {}: {}\nStatement: {}",
                            idx + 1,
                            migration.version,
                            e,
                            statement
                        )
                    })?;
            }
        }

        // Record migration as applied
        sqlx::query(&format!(
            "INSERT INTO {}._duroxide_migrations (version, name) VALUES ($1, $2)",
            self.schema_name
        ))
        .bind(migration.version)
        .bind(&migration.name)
        .execute(&mut *tx)
        .await?;

        // Commit transaction
        tx.commit().await?;

        tracing::info!(
            "Applied migration {}: {}",
            migration.version,
            migration.name
        );

        Ok(())
    }
}
