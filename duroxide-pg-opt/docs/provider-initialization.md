# Provider Initialization Design Proposal

## Motivation

Today, the `PostgresProvider` convenience constructors (`new()`, `new_with_schema()`) unconditionally run the full migration pipeline (creating the schema, tracking table, and applying all SQL migrations). The lower-level `new_with_options()` constructor already allows disabling the long-poll notifier via `LongPollConfig { enabled: false }`, but it still unconditionally runs DDL migrations. This means **every provider instance performs DDL**, which is problematic for deployment scenarios where DDL ownership must be separated from DML usage.

Some deployment scenarios require **three distinct client roles** for the same database:

- A **DDL client** that creates or migrates the schema, using a single connection, and exits. It does not need a connection pool, a notifier, or a `PostgresProvider` instance at all.
- A **DML engine client** (background worker) that runs the duroxide runtime's dispatch loops against an already-initialized schema, using a full connection pool and long-poll notifier. It should never create or modify schema objects.
- A **DML API client** (`duroxide::Client`) that calls orchestration management and monitoring APIs. These are synchronous request/response operations that do not use the long-poll notifier, so this client needs only a connection pool — no `PgListener`, no notifier background task.

Today, all constructors unconditionally run DDL migrations — there is no way to connect to an already-initialized schema without performing DDL. While `new_with_options` already supports disabling the notifier, it still runs the full migration pipeline every time.

### Target Use Case: PostgreSQL Extension with Background Worker

A PostgreSQL extension that embeds duroxide-pg-opt has three distinct execution contexts:

| Context | Role | Connection pool | Long-poll notifier | When it runs | What it should do |
|---|---|---|---|---|---|
| `CREATE EXTENSION` / `ALTER EXTENSION UPDATE` | DDL client | No (single connection) | No | Explicit DDL by a privileged user | Create/migrate the duroxide schema and all tables, then return |
| Background Worker | DML engine | Yes | Yes | When the extension is included in shared_preload_libraries in postgresql.conf | Use duroxide engine for DML only — never create schema or tables |
| `duroxide::Client` | DML API | Yes | No | Any backend calling orchestration APIs | Orchestration management (start, cancel, raise event) and monitoring (list instances, get info) — no DDL |

## Design Overview

The core contribution of this proposal is `MigrationPolicy` — separating **DDL** (schema creation/migration) from **DML** (provider usage). The ability to disable the long-poll notifier is pre-existing (`LongPollConfig { enabled: false }` was already supported by `new_with_options`); `ProviderConfig` carries that setting forward in a more extensible struct.

With `MigrationPolicy::VerifyOnly`, the provider verifies that the schema is at the expected version without executing any DDL:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  DDL (CREATE EXTENSION / ALTER EXTENSION UPDATE)                        │
│                                                                         │
│  Extension-owned SQL scripts apply duroxide-pg-opt migrations.          │
│  No Rust API is required for DDL.                                       │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  DML Client — Engine (Background Worker)                                │
│                                                                         │
│  let mut config = ProviderConfig::default();                            │
│  config.migration_policy = MigrationPolicy::VerifyOnly;                 │
│  let provider = PostgresProvider::new_with_config(&url, config)         │
│    → Full connection pool + PgListener + notifier                       │
│    → Verifies schema is at expected version (no DDL)                    │
│    → Returns Result<PostgresProvider>                                   │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  DML Client — duroxide::Client (orchestration management / monitoring)  │
│                                                                         │
│  let mut config = ProviderConfig::default();                            │
│  config.migration_policy = MigrationPolicy::VerifyOnly;                 │
│  config.long_poll = LongPollConfig { enabled: false, ..Default::default() };│
│  let provider = PostgresProvider::new_with_config(&url, config)         │
│    → Connection pool only — no PgListener, no notifier                  │
│    → Verifies schema is at expected version (no DDL)                    │
│    → Returns Result<PostgresProvider>                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Proposed API: `MigrationPolicy` Enum

```rust
/// Controls how schema migrations are handled during provider initialization.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum MigrationPolicy {
    /// Run all migrations, creating the schema and tables from scratch if needed.
    ///
    /// This is the current behavior and the default. Use this in contexts where
    /// the process is allowed to perform DDL (e.g., standalone applications or
    /// test/dev environments).
    #[default]
    ApplyAll,

    /// Verify that the schema exists and is at the expected migration version.
    /// Perform no DDL whatsoever.
    ///
    /// This policy:
    /// - **Checks** that the `_duroxide_migrations` tracking table exists.
    /// - **Checks** that all expected migrations have been applied.
    /// - **Errors** if the schema is missing (for non-`public` schemas) or the version is behind.
    /// - **Executes no DDL** — not even `CREATE TABLE IF NOT EXISTS`.
    ///
    /// Note: `VerifyOnly` is intentionally conservative but not exhaustive: it relies on the
    /// migration tracking table as the source of truth and does not attempt to detect or repair
    /// corrupted schemas where objects were dropped/modified out-of-band.
    ///
    /// Use this when the background worker should assume the schema is fully set up
    /// and treat any mismatch as a fatal configuration error.
    VerifyOnly,
}
```

## Behavior Matrix

| Scenario | `ApplyAll` | `VerifyOnly` |
|---|---|---|
| Schema does not exist | Creates it | **Error** |
| Schema exists, no tables (migration 0001 not applied) | Runs all migrations | **Error** |
| Schema exists, tables exist, all migrations applied | No-op | No-op (verified) |
| Schema exists, tables exist, behind by 1+ migrations | Applies pending | **Error** (version mismatch) |
| Schema exists, tables exist, has extra unknown migrations | **Error** | **Error** |
| `_duroxide_migrations` table missing | Creates it, runs all | **Error** |

## DML Path: `ProviderConfig` and `new_with_config()`

For DML client roles, a new `ProviderConfig` struct replaces the growing parameter list in `new_with_options`. Adding parameters directly to `new_with_options` would be a breaking change for all existing callers. `ProviderConfig` with `#[non_exhaustive]` solves this: new fields can be added in future releases without breaking callers who use `Default` + field mutation.

There are two distinct DML use cases:

- **Engine (Background Worker)**: Runs the duroxide runtime's dispatch loops. Needs a full connection pool, `PgListener`, and long-poll notifier to efficiently wake dispatchers when new orchestration/worker items arrive.
- **`duroxide::Client`**: Calls orchestration management APIs (`start_orchestration`, `cancel_instance`, `raise_event`) and monitoring APIs (`list_all_instances`, `get_instance_info`, `list_executions`). These are synchronous request/response operations that **do not use the notifier**. Disabling long-polling via `LongPollConfig { enabled: false, .. }` was already possible with `new_with_options` and is carried forward in `ProviderConfig`.

### Schema Name Safety

This crate frequently needs schema-qualified dynamic SQL (e.g., `${schema}.some_function(...)`).
Because PostgreSQL does not allow binding identifiers as parameters, schema names must be treated
as **untrusted input** and handled safely.

The implementation should:
- Validate `schema_name` as a PostgreSQL identifier (e.g., ASCII `[A-Za-z_][A-Za-z0-9_]*`) and reject anything outside that set.
- Use a single canonical, safely-quoted/escaped representation of the identifier whenever it must be interpolated into SQL strings.

`ProviderConfig`:

```rust
/// Configuration for constructing a `PostgresProvider`.
///
/// Use `Default::default()` and override specific fields. The struct is
/// `#[non_exhaustive]`, so new fields can be added in future releases
/// without breaking existing code.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    /// PostgreSQL schema name. Default: `"public"`.
    pub schema_name: Option<String>,

    /// Long-polling configuration. Default: enabled with 60s poll interval.
    pub long_poll: LongPollConfig,

    /// Migration policy. Default: `ApplyAll`.
    pub migration_policy: MigrationPolicy,
}

impl Default for ProviderConfig {
    fn default() -> Self {
        Self {
            schema_name: None,
            long_poll: LongPollConfig::default(),
            migration_policy: MigrationPolicy::default(),
        }
    }
}
```

Because `ProviderConfig` is `#[non_exhaustive]`, external callers cannot use struct literal syntax directly. Instead they use `Default` and mutate:

```rust
let mut config = ProviderConfig::default();
config.schema_name = Some("my_ext".to_string());
config.migration_policy = MigrationPolicy::VerifyOnly;

let provider = PostgresProvider::new_with_config(&db_url, config).await?;
```

### Constructor changes

```rust
impl PostgresProvider {
    /// Create a new provider with default settings (ApplyAll, long-poll enabled).
    /// This is unchanged and not a breaking change.
    pub async fn new(database_url: &str) -> Result<Self> {
        Self::new_with_config(database_url, ProviderConfig::default()).await
    }

    /// Create a new provider with a custom schema.
    /// This is unchanged and not a breaking change.
    pub async fn new_with_schema(database_url: &str, schema_name: Option<&str>) -> Result<Self> {
        let mut config = ProviderConfig::default();
        config.schema_name = schema_name.map(|s| s.to_string());
        Self::new_with_config(database_url, config).await
    }

    /// Create a new provider with full configuration.
    pub async fn new_with_config(
        database_url: &str,
        config: ProviderConfig,
    ) -> Result<Self> {
        // ... pool setup (unchanged) ...

        // Handle migrations based on policy
        let migration_runner = MigrationRunner::new(pool.clone(), schema_name.clone());
        match config.migration_policy {
            MigrationPolicy::ApplyAll => {
                migration_runner.migrate().await?;
            }
            MigrationPolicy::VerifyOnly => {
                migration_runner.verify().await?;
            }
        }

        // Check for unknown migrations (schema ahead of code)
        migration_runner.check_no_unknown_migrations().await?;

        // ... notifier setup using config.long_poll (unchanged) ...
    }

    /// Existing method — kept for backward compatibility and delegates
    /// to new_with_config internally. Not deprecated; it remains a stable
    /// convenience API.
    pub async fn new_with_options(
        database_url: &str,
        schema_name: Option<&str>,
        long_poll: LongPollConfig,
    ) -> Result<Self> {
        let mut config = ProviderConfig::default();
        config.schema_name = schema_name.map(|s| s.to_string());
        config.long_poll = long_poll;
        Self::new_with_config(database_url, config).await
    }
}
```

### Why `#[non_exhaustive]`?

- Adding a new field to `ProviderConfig` (e.g., `max_connections`, `acquire_timeout`) is **not a breaking change** — existing callers using `Default` + field mutation are unaffected.
- Without `#[non_exhaustive]`, callers using struct literal syntax (`ProviderConfig { field1: ..., ..Default::default() }`) would break when new fields are added, even with `..Default::default()`.
- Trade-off: callers must use `ProviderConfig::default()` followed by field assignment, rather than struct literal syntax. This is a minor ergonomic cost for future-proofing.

## MigrationRunner Changes

### `verify()`

```rust
/// Verify that the schema is fully migrated. Executes no DDL.
///
/// Errors if:
/// - The schema does not exist (for non-public schemas)
/// - The migration tracking table does not exist
/// - Any expected migration has not been applied
///
/// `VerifyOnly` relies only on `_duroxide_migrations` as the source of truth. It does not attempt
/// to detect or repair out-of-band schema changes (e.g., dropped tables/procedures).
///
/// Note: unknown-migration detection (schema ahead of code) is handled
/// separately by `check_no_unknown_migrations()` and is always enforced.
pub async fn verify(&self) -> Result<()> {
    // 1. Check schema exists
    if self.schema_name != "public" {
        let schema_exists = self.check_schema_exists().await?;
        if !schema_exists {
            anyhow::bail!(
                "Schema '{}' does not exist. Cannot verify migrations.",
                self.schema_name
            );
        }
    }

    // 2. Check tracking table exists
    let tracking_table_exists = self.check_migration_table_exists().await?;
    if !tracking_table_exists {
        anyhow::bail!(
            "Migration tracking table does not exist in schema '{}'. \
             Schema has not been initialized.",
            self.schema_name
        );
    }

    // 3. Check all migrations are applied
    let applied_versions = self.get_applied_versions().await?;
    let expected_migrations = self.load_migrations()?;

    let mut missing = Vec::new();
    for migration in &expected_migrations {
        if !applied_versions.contains(&migration.version) {
            missing.push(format!("{} ({})", migration.version, migration.name));
        }
    }

    if !missing.is_empty() {
        anyhow::bail!(
            "Schema '{}' is behind the expected migration version. \
             Missing migrations: {}. \
             Run migrations before connecting with VerifyOnly policy.",
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
```

### `check_no_unknown_migrations()`

Shared check used after initialization to ensure the schema is not ahead of the code:

```rust
/// Check that the database has no migrations the code doesn't recognize.
///
/// Errors if applied migrations include versions not in the embedded migration set.
/// This catches the case where old code is running against a newer schema.
///
/// "Unknown" here is defined strictly in terms of **version numbers** present in
/// `{schema}._duroxide_migrations` that are not present in the embedded migrations.
/// It does not attempt to validate migration contents/hashes.
pub async fn check_no_unknown_migrations(&self) -> Result<()> {
    // Skip if tracking table doesn't exist (ApplyAll will create it;
    // VerifyOnly will have already errored)
    if !self.check_migration_table_exists().await? {
        return Ok(());
    }

    let applied_versions = self.get_applied_versions().await?;
    let expected_migrations = self.load_migrations()?;
    let expected_versions: HashSet<i64> = expected_migrations
        .iter()
        .map(|m| m.version)
        .collect();

    let unknown: Vec<i64> = applied_versions
        .iter()
        .filter(|v| !expected_versions.contains(v))
        .copied()
        .collect();

    if !unknown.is_empty() {
        anyhow::bail!(
            "Schema '{}' has migrations not recognized by this version of the code: {:?}. \
             The database schema is ahead of the code. Update the code or downgrade the schema.",
            self.schema_name,
            unknown
        );
    }

    Ok(())
}

```

### Migration Concurrency / Serialization

The current `MigrationRunner::migrate()` implementation runs each migration in a transaction, but
does not serialize concurrent migrators (e.g., multiple nodes starting simultaneously).
Without serialization, two processes can race to apply the same migration, potentially causing
DDL conflicts or unique-constraint errors when inserting into `_duroxide_migrations`.

For `ApplyAll`, the implementation should acquire a PostgreSQL advisory lock scoped to
`(schema_name, migration_system)` for the duration of the migration process. This makes startup
deterministic and avoids relying on incidental idempotency of individual statements.

### New Helper: `check_schema_exists()`

```rust
async fn check_schema_exists(&self) -> Result<bool> {
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)"
    )
    .bind(&self.schema_name)
    .fetch_one(&*self.pool)
    .await?;

    Ok(exists)
}
```

### New Helper: `check_migration_table_exists()`

```rust
async fn check_migration_table_exists(&self) -> Result<bool> {
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.tables \
         WHERE table_schema = $1 AND table_name = '_duroxide_migrations')"
    )
    .bind(&self.schema_name)
    .fetch_one(&*self.pool)
    .await?;

    Ok(exists)
}
```

## Usage in the PostgreSQL Extension Scenario

```rust
// In CREATE EXTENSION / ALTER EXTENSION UPDATE:
// Apply duroxide-pg-opt migrations from extension-owned SQL scripts.

// In Background Worker — normal startup after CREATE EXTENSION
// Needs pool + notifier for the duroxide engine dispatch loops
let mut config = ProviderConfig::default();
config.schema_name = Some("my_ext".to_string());
config.migration_policy = MigrationPolicy::VerifyOnly;
let provider = PostgresProvider::new_with_config(&db_url, config).await?;

// duroxide::Client — orchestration management and monitoring only
// No notifier needed: start_orchestration, cancel_instance, raise_event,
// list_all_instances, get_instance_info are synchronous request/response.
let mut config = ProviderConfig::default();
config.schema_name = Some("my_ext".to_string());
config.migration_policy = MigrationPolicy::VerifyOnly;
config.long_poll = LongPollConfig { enabled: false, ..Default::default() };
let provider = PostgresProvider::new_with_config(&db_url, config).await?;
let client = duroxide::Client::new(provider);
```

## Error Messages

Clear, actionable error messages are critical since these will surface to extension authors and DBAs:

| Policy | Condition | Error message |
|---|---|---|
| `VerifyOnly` | Schema missing | `Schema 'X' does not exist. Cannot verify migrations.` |
| `VerifyOnly` | Tracking table missing | `Migration tracking table does not exist in schema 'X'. Schema has not been initialized.` |
| `VerifyOnly` | Version behind | `Schema 'X' is behind the expected migration version. Missing migrations: 3 (0003_add_capability_filtering.sql), 4 (0004_add_session_support.sql). Run migrations before connecting with VerifyOnly policy.` |
| Any | Schema ahead of code | `Schema 'X' has migrations not recognized by this version of the code: [6, 7]. The database schema is ahead of the code. Update the code or downgrade the schema.` |

## Impact on Existing API

- `new()` and `new_with_schema()` continue to work unchanged — **no breaking change**.
- `new_with_options()` is **preserved with its current signature** and delegates to `new_with_config` internally. It is **not deprecated** — it remains a stable convenience API for callers who don't need the full `ProviderConfig`.
- `new_with_config()` is the new primary constructor, taking a `#[non_exhaustive]` `ProviderConfig` struct. Future fields can be added without breaking callers.
- The `new_with_fault_injection()` constructor (test-only, behind feature flag) always uses `MigrationPolicy::ApplyAll` internally. It does **not** accept a `migration_policy` parameter — test infrastructure is responsible for setting up the schema via the normal path before exercising fault-injection scenarios.

## Connection Usage Analysis

All constructors create a connection pool. The `PgListener` connection is only created when long-polling is enabled (the default):

| Resource | What creates it | Purpose | Count |
|---|---|---|---|
| `PgPool` | `PgPoolOptions::new()` | All DML operations (fetches, acks, reads, etc.) | Up to `DUROXIDE_PG_POOL_MAX` (default 10) connections |
| `PgPool.min_connections` | Pool config | Eagerly opened on pool creation | 1 (always) |
| `PgListener` | `Notifier::new()` | Dedicated LISTEN/NOTIFY connection | 1 (if long-poll enabled) |

Disabling long-polling (`LongPollConfig { enabled: false }`) was already supported by `new_with_options` before this proposal. It eliminates the `PgListener` connection and the notifier background task. This proposal does not change connection behavior — it only adds `MigrationPolicy` to control whether DDL is executed during initialization.

## Deferred: Minimum Compatible Schema Version

Currently, `VerifyOnly` requires that **all** embedded migrations have been applied — if the code knows about migrations 1–5 and the database is at version 4, it errors out. This is the safest default but may be overly strict: migration 5 might only add an optional column that the code can function without.

A more nuanced approach would be a hard-coded `MIN_COMPATIBLE_SCHEMA_VERSION` constant maintained by duroxide-pg-opt developers. `VerifyOnly` would then accept any schema version >= this minimum rather than requiring an exact match. For example, if the code is at migration 5 but `MIN_COMPATIBLE_SCHEMA_VERSION = 4`, a database at version 4 would be accepted.

This is inherently a library-internal concern — only duroxide-pg-opt developers can determine which migrations are breaking (e.g., a stored procedure signature change the code depends on) vs. purely additive (e.g., an optional column). Callers using `VerifyOnly` have no way to make this determination themselves.

We defer this to future work because it introduces significant maintenance burden:
- Each migration would need to be classified as breaking or non-breaking.
- The `MIN_COMPATIBLE_SCHEMA_VERSION` constant would need to be tested and updated with each release.
- Backward compatibility between code and schema versions would need integration test coverage.

For the initial implementation, requiring all migrations to be applied is the correct conservative choice.

## Deferred: Lightweight Client Mode

The `duroxide::Client` use case (orchestration management / monitoring only) can already be served by disabling long-polling. However, the provider still creates a full connection pool (up to 10 connections, 1 eagerly). A future optimization could offer a truly lightweight client mode with a smaller pool (e.g., `max_connections = 2`, `min_connections = 0`) or even a single-connection mode, reducing resource usage for processes that only make occasional API calls.

This is deferred because:
- The current pool settings are adequate for most use cases.
- Pool sizing is a separate concern from DDL/DML separation.
- Adding `max_connections` / `min_connections` to `ProviderConfig` is straightforward when needed (the `#[non_exhaustive]` design anticipates this).

## Resolved Design Decisions

1. **Unknown migrations are always rejected.** If the database has migrations the code doesn't recognize (schema ahead of code), provider initialization fails. This prevents running old code against a newer schema, which could cause subtle runtime failures.
2. **`MigrationRunner` stays private.** Schema migrations remain internal; DDL is performed externally (e.g., extension-owned SQL scripts) or via `MigrationPolicy::ApplyAll` in applications.
