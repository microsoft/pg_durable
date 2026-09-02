// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Core types and configuration for pg_durable

use pgrx::{pg_extern, Spi};

use chrono::{DateTime, Utc};
use cron::Schedule as CronSchedule;
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::str::FromStr;
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use uuid::Uuid;

pub(crate) const WORKER_MANAGEMENT_APPLICATION_NAME: &str = "pg_durable:worker:management";
pub(crate) const WORKER_POLL_APPLICATION_NAME: &str = "pg_durable:worker:poll";
pub(crate) const WORKER_DUROXIDE_APPLICATION_NAME: &str = "pg_durable:worker:duroxide";
pub(crate) const WORKER_WORKFLOW_SQL_APPLICATION_NAME: &str = "pg_durable:worker:workflow-sql";
pub(crate) const BACKEND_DUROXIDE_APPLICATION_NAME: &str = "pg_durable:backend:duroxide";
pub(crate) const BACKEND_MONITORING_APPLICATION_NAME: &str = "pg_durable:backend:monitoring";
pub(crate) const BACKEND_NEW_TRANSACTION_APPLICATION_NAME: &str =
    "pg_durable:backend:new-transaction";

// ============================================================================
// Configuration Functions
// ============================================================================

/// Get the worker role from the `pg_durable.worker_role` GUC.
/// Falls back to `"postgres"` if the GUC is not set.
pub fn get_worker_role() -> String {
    crate::WORKER_ROLE
        .get()
        .map(|cs: CString| cs.to_string_lossy().into_owned())
        .unwrap_or_else(|| "postgres".to_string())
}

/// Get the database from the `pg_durable.database` GUC.
/// Falls back to `"postgres"` if the GUC is not set.
pub fn get_database() -> String {
    crate::DATABASE
        .get()
        .map(|cs: CString| cs.to_string_lossy().into_owned())
        .unwrap_or_else(|| "postgres".to_string())
}

/// Get the maximum number of management pool connections.
pub fn get_max_management_connections() -> u32 {
    crate::MAX_MANAGEMENT_CONNECTIONS.get() as u32
}

/// Get the maximum number of duroxide provider pool connections.
pub fn get_max_duroxide_connections() -> u32 {
    crate::MAX_DUROXIDE_CONNECTIONS.get() as u32
}

/// Get the maximum number of concurrent user-execution connections.
pub fn get_max_user_connections() -> u32 {
    crate::MAX_USER_CONNECTIONS.get() as u32
}

/// Get the maximum number of concurrent transaction_mode => 'new' launch sessions.
pub fn get_max_new_transaction_starts() -> u32 {
    crate::MAX_NEW_TRANSACTION_STARTS.get() as u32
}

/// Get the execution acquire timeout as a Duration.
pub fn get_execution_acquire_timeout() -> Duration {
    Duration::from_secs(crate::EXECUTION_ACQUIRE_TIMEOUT.get() as u64)
}

/// Get the transaction_mode => 'new' launch-slot timeout as a Duration.
pub fn get_new_transaction_start_timeout() -> Duration {
    Duration::from_secs(crate::NEW_TRANSACTION_START_TIMEOUT.get() as u64)
}

/// Days a terminal instance is retained before reconciliation removes it and its
/// engine record; also the age bound for reclaiming orphaned engine records.
pub fn get_retention_days() -> i32 {
    crate::RETENTION_DAYS.get()
}

/// Interval between background reconciliation passes. Zero disables reconciliation.
pub fn get_reconcile_interval() -> Duration {
    Duration::from_secs(crate::RECONCILE_INTERVAL.get() as u64)
}

/// Returns `true` when superuser-submitted instances are permitted.
pub fn superuser_instances_enabled() -> bool {
    crate::ENABLE_SUPERUSER_INSTANCES.get()
}

/// Returns `true` if the role identified by `role_oid` is a PostgreSQL superuser.
/// Runs a SPI query against `pg_catalog.pg_roles`.  Must be called from a
/// backend context (not the background worker).
pub fn is_role_superuser_oid(role_oid: pgrx::pg_sys::Oid) -> Result<bool, String> {
    match pgrx::Spi::get_one_with_args::<bool>(
        "SELECT rolsuper FROM pg_catalog.pg_roles WHERE oid = $1",
        &[role_oid.into()],
    ) {
        Ok(Some(v)) => Ok(v),
        Ok(None) => Err(format!("role oid {} not found in pg_roles", role_oid)),
        Err(e) => Err(format!(
            "superuser check failed for role oid {}: {}",
            role_oid, e
        )),
    }
}

/// Returns `true` if the role identified by `role_name` is a PostgreSQL superuser.
/// Issues a single async query against `pg_catalog.pg_roles` using the provided pool.
/// Must be called from an async context (background worker).
///
/// The lookup runs inside a short-lived transaction that applies server-side
/// `statement_timeout` / `lock_timeout`, so a probe that blocks (e.g. behind a
/// conflicting lock on the role catalog) is cancelled by PostgreSQL and its
/// connection returned cleanly to the pool, rather than pinning a management
/// connection until a client-side deadline drops the in-flight future.
pub async fn is_role_superuser_name(pool: &sqlx::PgPool, role_name: &str) -> Result<bool, String> {
    let err = |e: sqlx::Error| format!("superuser check failed for role '{}': {}", role_name, e);
    let mut tx = pool.begin().await.map_err(err)?;
    sqlx::query("SET LOCAL statement_timeout = '1500ms'")
        .execute(&mut *tx)
        .await
        .map_err(err)?;
    sqlx::query("SET LOCAL lock_timeout = '1500ms'")
        .execute(&mut *tx)
        .await
        .map_err(err)?;
    let result = sqlx::query_scalar::<_, bool>(
        "SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = $1",
    )
    .bind(role_name)
    .fetch_optional(&mut *tx)
    .await
    .map_err(err)
    .and_then(|opt| opt.ok_or_else(|| format!("role '{}' not found in pg_roles", role_name)));
    // Read-only transaction: a rollback failure cannot change the result.
    let _ = tx.rollback().await;
    result
}

/// Maximum nesting depth for workflow graphs. Bounds recursive graph walkers
/// after opaque child storage removes serde_json's incidental depth limit.
pub const MAX_GRAPH_DEPTH: usize = 256;

/// Maximum number of nodes allowed in a single workflow instance. Prevents
/// unbounded INSERTs and memory exhaustion from extremely large graphs.
pub const MAX_GRAPH_NODES: usize = 10_000;

/// Generate a short 8-character ID from a UUID.
///
/// This serves two distinct uniqueness contracts (#129). Both keep the value
/// `VARCHAR(8)` HEX (the maintainer-requested minimal change):
/// - **Instance IDs** (`df.instances.id`) are global with no scoping column.
///   `df.start()` reserves the ID with `INSERT ... ON CONFLICT (id) DO NOTHING
///   RETURNING id` and re-rolls on collision; the primary key on `df.instances`
///   is the hard guarantee.
/// - **Node IDs** (`df.nodes.id`) only need to be unique per instance. Node
///   IDs are assigned uniquely while the graph is materialized, before parent
///   references are fixed. The composite primary key `(instance_id, id)` is the
///   final database guarantee; an unexpected insert conflict aborts the start.
pub fn short_id() -> String {
    let uuid = Uuid::new_v4();
    uuid.to_string()
        .chars()
        .rev()
        .take(8)
        .collect::<String>()
        .chars()
        .rev()
        .collect()
}

/// PostgreSQL connection string for the background worker and Duroxide runtime
pub fn postgres_connection_string() -> String {
    let host = get_host();
    let port = unsafe { pgrx::pg_sys::PostPortNumber };
    let user = get_worker_role();
    let database = get_database();

    build_connection_url(&user, &host, port, &database)
}

pub(crate) fn postgres_connection_string_with_application_name(application_name: &str) -> String {
    connection_url_with_application_name(&postgres_connection_string(), application_name)
}

pub(crate) fn connection_url_with_application_name(
    database_url: &str,
    application_name: &str,
) -> String {
    let separator = if database_url.contains('?') { '&' } else { '?' };
    let encoded = utf8_percent_encode(application_name, NON_ALPHANUMERIC);
    format!("{database_url}{separator}application_name={encoded}")
}

/// Whether `host` can be placed in a `postgres://` URL verbatim.
///
/// Plain hostnames, IPv4 addresses, and bracketed IPv6 literals are safe. Anything
/// else (Unix-socket paths, or a `pg_durable.host` / `PGHOST` value carrying URL
/// metacharacters) must be percent-encoded so it cannot inject a different host or
/// extra connection parameters.
fn host_is_url_safe(host: &str) -> bool {
    if host.starts_with('[') {
        return host.ends_with(']');
    }

    host.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// Build the worker's `postgres://` connection URL.
///
/// Hosts that are not plain names or addresses are percent-encoded so the URL
/// parser keeps the whole value inside the host component. sqlx decodes socket
/// paths back out, so Unix sockets still connect; a host carrying URL
/// metacharacters stays inert and fails to resolve instead of injecting a
/// different host or extra connection parameters.
fn build_connection_url(user: &str, host: &str, port: i32, database: &str) -> String {
    if host_is_url_safe(host) {
        format!("postgres://{user}@{host}:{port}/{database}")
    } else {
        let encoded = utf8_percent_encode(host, NON_ALPHANUMERIC).to_string();
        format!("postgres://{user}@{encoded}:{port}/{database}")
    }
}

/// An empty `PGHOST` is deliberately preserved as an empty host so sqlx applies its
/// own default; only `pg_durable.host` treats empty as "not configured".
fn resolve_host(configured_host: Option<String>, environment_host: Option<String>) -> String {
    configured_host
        .filter(|host| !host.is_empty())
        .or(environment_host)
        .unwrap_or_else(|| "127.0.0.1".to_string())
}

/// Get the PostgreSQL host for connections.
/// `pg_durable.host` takes precedence over `PGHOST` when configured.
pub fn get_host() -> String {
    let configured_host = crate::HOST
        .get()
        .map(|host| host.to_string_lossy().into_owned());
    resolve_host(configured_host, std::env::var("PGHOST").ok())
}

/// Get the PostgreSQL port for connections
pub fn get_port() -> u16 {
    unsafe { pgrx::pg_sys::PostPortNumber as u16 }
}

/// Get the target database name that the background worker will connect to
/// This matches the logic in postgres_connection_string() for database selection
#[pg_extern(immutable, parallel_safe, schema = "df")]
pub fn target_database() -> String {
    get_database()
}

/// Create a single PostgreSQL connection authenticated as `user`.
pub async fn connect_as_user(
    user: &str,
    database: Option<&str>,
) -> Result<sqlx::postgres::PgConnection, String> {
    connect_as_user_with_application_name(user, database, WORKER_WORKFLOW_SQL_APPLICATION_NAME)
        .await
}

pub(crate) async fn connect_as_user_for_new_transaction(
    user: &str,
) -> Result<sqlx::postgres::PgConnection, String> {
    connect_as_user_with_application_name(user, None, BACKEND_NEW_TRANSACTION_APPLICATION_NAME)
        .await
}

async fn connect_as_user_with_application_name(
    user: &str,
    database: Option<&str>,
    application_name: &str,
) -> Result<sqlx::postgres::PgConnection, String> {
    use sqlx::postgres::PgConnectOptions;
    use sqlx::Connection;

    /// Connection timeout for per-user SQL connections (seconds).
    const CONNECT_TIMEOUT_SECS: u64 = 30;

    let default_db = target_database();
    let db = database.unwrap_or(&default_db);
    let mut options = PgConnectOptions::new()
        .username(user)
        .database(db)
        .port(get_port())
        .application_name(application_name);

    let host = get_host();
    if !host.is_empty() {
        options = options.host(&host);
    }

    let connect_future = sqlx::postgres::PgConnection::connect_with(&options);
    let mut conn = tokio::time::timeout(Duration::from_secs(CONNECT_TIMEOUT_SECS), connect_future)
        .await
        .map_err(|_| {
            format!(
                "Connection to database '{}' as '{}' timed out after {}s",
                db, user, CONNECT_TIMEOUT_SECS
            )
        })?
        .map_err(|e| {
            format!(
                "Failed to connect to database '{}' as '{}'. Error: {}",
                db, user, e
            )
        })?;

    // Mark this connection as running inside a workflow.
    // Currently used to prevent variable mutations (setvar/unsetvar/clearvars)
    // during execution. Could also be checked in df.start() to prevent
    // recursive workflow invocation in a future improvement.
    sqlx::query("SET df.in_workflow = 'true'")
        .execute(&mut conn)
        .await
        .map_err(|e| format!("SET df.in_workflow failed: {}", e))?;

    Ok(conn)
}

/// Legacy duroxide provider schema name used by installs created before the
/// `df.duroxide_schema()` helper existed (pg_durable ≤ 0.2.2). It is the only
/// fallback when that helper is absent, and the value the upgrade script pins
/// existing clusters to.
pub const LEGACY_DUROXIDE_SCHEMA: &str = "duroxide";

/// Resolve the duroxide provider schema name by calling the extension-owned
/// `df.duroxide_schema()` helper.
///
/// Returns [`LEGACY_DUROXIDE_SCHEMA`] when the helper does not exist (an install
/// that predates it — e.g. a new `.so` deployed against a ≤0.2.2 schema without
/// running `ALTER EXTENSION pg_durable UPDATE`). The presence check uses the
/// catalog rather than catching `42883` so it never aborts the surrounding
/// (sub)transaction in a backend session.
fn resolve_duroxide_schema_spi() -> String {
    let helper_exists = Spi::get_one::<bool>(
        "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_proc p \
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace \
         WHERE n.nspname = 'df' AND p.proname = 'duroxide_schema' AND p.pronargs = 0)",
    )
    .ok()
    .flatten()
    .unwrap_or(false);

    if !helper_exists {
        return LEGACY_DUROXIDE_SCHEMA.to_string();
    }

    match Spi::get_one::<String>("SELECT df.duroxide_schema()") {
        Ok(Some(s)) if !s.is_empty() => s,
        _ => LEGACY_DUROXIDE_SCHEMA.to_string(),
    }
}

/// Resolve the duroxide provider schema for the current backend session,
/// caching it for the session lifetime. The value cannot change without an
/// extension upgrade, which requires a reconnect to observe reliably, so a
/// per-session cache is safe.
pub fn backend_duroxide_schema() -> &'static str {
    static SCHEMA: OnceLock<String> = OnceLock::new();
    SCHEMA.get_or_init(resolve_duroxide_schema_spi)
}

/// Resolve the duroxide provider schema name from the background worker using an
/// async pool. Mirrors [`resolve_duroxide_schema_spi`] but for the BGW context.
/// The BGW resolves this once per epoch (after the extension is detected) rather
/// than caching for the process lifetime, because drop+recreate can switch the
/// provider schema within a single worker lifetime.
pub async fn resolve_duroxide_schema_pool(pool: &sqlx::PgPool) -> String {
    let helper_exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM pg_proc p \
         JOIN pg_namespace n ON n.oid = p.pronamespace \
         WHERE n.nspname = 'df' AND p.proname = 'duroxide_schema' AND p.pronargs = 0)",
    )
    .fetch_one(pool)
    .await
    .unwrap_or(false);

    if !helper_exists {
        return LEGACY_DUROXIDE_SCHEMA.to_string();
    }

    match sqlx::query_scalar::<_, String>("SELECT df.duroxide_schema()")
        .fetch_one(pool)
        .await
    {
        Ok(s) if !s.is_empty() => s,
        _ => LEGACY_DUROXIDE_SCHEMA.to_string(),
    }
}

/// Create a `ProviderConfig` for backend (request/response) operations.
///
/// - `VerifyOnly`: never create schema/tables, reject unknown migrations.
///   Backend sessions must not run DDL — the BGW owns schema lifecycle.
pub fn backend_provider_config(
    database_url: &str,
    schema_name: &str,
) -> duroxide_pg::ProviderConfig {
    let mut config = duroxide_pg::ProviderConfig::url(connection_url_with_application_name(
        database_url,
        BACKEND_DUROXIDE_APPLICATION_NAME,
    ));
    config.schema_name = Some(schema_name.to_string());
    config.migration_policy = duroxide_pg::MigrationPolicy::VerifyOnly;
    config
}

/// Create a backend provider for request/response operations.
pub async fn new_backend_provider(
    database_url: &str,
    schema_name: &str,
) -> Result<Arc<duroxide_pg::PostgresProvider>, String> {
    duroxide_pg::PostgresProvider::new_with_config(backend_provider_config(
        database_url,
        schema_name,
    ))
    .await
    .map(Arc::new)
    .map_err(|e| format!("Failed to connect to duroxide store: {e}"))
}

/// Create a `ProviderConfig` for the background worker runtime.
///
/// - `ApplyAll`: applies pending duroxide migrations at startup; creates tables
///   inside the extension-owned provider schema. Safe because the BGW verifies
///   schema ownership via `pg_depend` before calling
///   `PostgresProvider::new_with_config`.
pub fn worker_provider_config(
    database_url: &str,
    schema_name: &str,
) -> duroxide_pg::ProviderConfig {
    let mut config = duroxide_pg::ProviderConfig::url(connection_url_with_application_name(
        database_url,
        WORKER_DUROXIDE_APPLICATION_NAME,
    ));
    config.schema_name = Some(schema_name.to_string());
    config.migration_policy = duroxide_pg::MigrationPolicy::ApplyAll;
    config
}

/// Calculate the duration until the next cron schedule match
pub fn calculate_cron_wait(cron_expr: &str) -> Result<Duration, String> {
    let cron_with_seconds = format!("0 {cron_expr}");

    let schedule = CronSchedule::from_str(&cron_with_seconds)
        .map_err(|e| format!("Invalid cron expression '{cron_expr}': {e}"))?;

    let now: DateTime<Utc> = Utc::now();

    let next = schedule
        .upcoming(Utc)
        .next()
        .ok_or_else(|| "No upcoming schedule found".to_string())?;

    let duration = (next - now)
        .to_std()
        .map_err(|_| "Failed to calculate wait duration".to_string())?;

    Ok(duration)
}

/// Evaluate a condition result to determine if it's truthy.
/// Uses iter().next() for first-column extraction — picks an arbitrary first
/// column, which is acceptable here because conditions are single-value
/// queries (SELECT <bool_expr>).
pub fn evaluate_condition(result: &str) -> Result<bool, String> {
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(result) {
        if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
            // Empty result set → falsy (no rows means condition is not met)
            if rows.is_empty() {
                return Ok(false);
            }
            if let Some(first_row) = rows.first() {
                if let Some(obj) = first_row.as_object() {
                    if let Some((_, value)) = obj.iter().next() {
                        return Ok(is_truthy(value));
                    }
                }
            }
        }
        return Ok(is_truthy(&json));
    }

    // Raw string fallback: delegate to is_truthy for consistent behavior
    Ok(is_truthy(&serde_json::Value::String(result.to_string())))
}

pub fn is_truthy(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::Number(n) => {
            n.as_i64().map(|i| i != 0).unwrap_or(false)
                || n.as_f64().map(|f| f != 0.0).unwrap_or(false)
        }
        serde_json::Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                return false;
            }
            let lower = trimmed.to_lowercase();
            if matches!(lower.as_str(), "true" | "t" | "yes") {
                return true;
            }
            if matches!(lower.as_str(), "false" | "f" | "no") {
                return false;
            }
            // Numeric strings: try float parsing (covers both ints and floats)
            if let Ok(n) = lower.parse::<f64>() {
                return n != 0.0;
            }
            // Non-empty, non-boolean, non-numeric strings are truthy
            true
        }
        serde_json::Value::Array(a) => !a.is_empty(),
        serde_json::Value::Object(o) => !o.is_empty(),
        serde_json::Value::Null => false,
    }
}

/// System variables available during workflow execution
pub struct SystemVars {
    pub instance_id: String,
    pub label: Option<String>,
}

// ============================================================================
// Result Substitution Helpers
// ============================================================================

fn is_ident_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_ident_continue(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Parse an identifier at the start of `s`: [a-zA-Z_][a-zA-Z0-9_]*
fn parse_identifier(s: &str) -> &str {
    let bytes = s.as_bytes();
    if bytes.is_empty() || !is_ident_start(bytes[0]) {
        return "";
    }
    let len = bytes.iter().take_while(|&&b| is_ident_continue(b)).count();
    &s[..len]
}

/// Validate that a result name is a safe SQL identifier: [a-zA-Z_][a-zA-Z0-9_]*
/// Returns Ok(()) if valid, Err with message if not.
pub fn validate_result_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("result name cannot be empty".to_string());
    }
    let parsed = parse_identifier(name);
    if parsed.len() != name.len() {
        return Err(format!(
            "result name '{}' is not a valid identifier — must match [a-zA-Z_][a-zA-Z0-9_]*",
            name
        ));
    }
    Ok(())
}

/// Double-quote a SQL identifier, escaping any internal double-quotes.
fn quote_identifier(name: &str) -> String {
    let escaped = name.replace('"', "\"\"");
    format!("\"{escaped}\"")
}

/// Format a JSON value for use in a SQL or raw context.
fn format_value(val: &serde_json::Value, for_sql: bool) -> String {
    match val {
        serde_json::Value::String(s) => {
            if for_sql {
                let escaped = s.replace('\'', "''");
                format!("'{escaped}'")
            } else {
                s.clone()
            }
        }
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Bool(b) => b.to_string(),
        _ => {
            if for_sql {
                let s = val.to_string();
                let escaped = s.replace('\'', "''");
                format!("'{escaped}'")
            } else {
                val.to_string()
            }
        }
    }
}

/// Extract first-column-first-row (bare `$name` / `$name?`).
fn extract_first_column_value(
    name: &str,
    json_str: &str,
    null_safe: bool,
    for_sql: bool,
) -> Result<String, String> {
    let json: serde_json::Value = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(_) => {
            // Not JSON — return raw value (backward compat for HTTP responses etc.)
            return Ok(if for_sql {
                let escaped = json_str.replace('\'', "''");
                format!("'{escaped}'")
            } else {
                json_str.to_string()
            });
        }
    };

    if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
        if rows.is_empty() {
            return if null_safe {
                Ok("NULL".to_string())
            } else {
                Err(format!("${name} has no rows — query returned zero results"))
            };
        }

        let first_row = rows[0]
            .as_object()
            .ok_or_else(|| format!("${name}: first row is not an object"))?;
        let (_, val) = first_row
            .iter()
            .next()
            .ok_or_else(|| format!("${name}: first row has no columns"))?;

        if val.is_null() {
            return if null_safe {
                Ok("NULL".to_string())
            } else {
                Err(format!(
                    "${name} is NULL — first column of first row is NULL"
                ))
            };
        }

        Ok(format_value(val, for_sql))
    } else if for_sql {
        let escaped = json_str.replace('\'', "''");
        Ok(format!("'{escaped}'"))
    } else {
        Ok(json_str.to_string())
    }
}

/// Extract a named field from a node result (`$name.col` / `$name.col?`).
///
/// SQL node results carry a `rows` array, so the field is read from the first
/// row. HTTP and HTTP_MULTIPART results are flat response envelopes with no
/// `rows` array, so the field is read from the envelope itself — this is what
/// makes `$response.body`, `$response.status` and `$response.ok` work.
///
/// Returns the original pattern when the field does not exist in the result.
fn extract_column_value(
    name: &str,
    json_str: &str,
    col: &str,
    null_safe: bool,
    for_sql: bool,
) -> Result<String, String> {
    let json: serde_json::Value = serde_json::from_str(json_str)
        .map_err(|_| format!("${name}.{col}: result is not valid JSON"))?;

    let fields = match json.get("rows").and_then(|r| r.as_array()) {
        Some(rows) => {
            if rows.is_empty() {
                return if null_safe {
                    Ok("NULL".to_string())
                } else {
                    Err(format!("${name} has no rows — query returned zero results"))
                };
            }
            rows[0]
                .as_object()
                .ok_or_else(|| format!("${name}.{col}: first row is not an object"))?
        }
        None => json.as_object().ok_or_else(|| {
            format!("${name}.{col}: result is neither a row set nor a JSON object")
        })?,
    };

    let val = match fields.get(col) {
        Some(v) => v,
        None => {
            // Missing field.
            //
            // In a SQL context the pattern is left as-is so PostgreSQL reports
            // the error with its own diagnostics. A raw context — a URL, a
            // header, a multipart field — has no such parser, so a leftover
            // `$name.col` would be sent over the wire verbatim and the request
            // would fail somewhere far less obvious. Fail loudly instead.
            if !for_sql && !null_safe {
                let mut available: Vec<&str> = fields.keys().map(String::as_str).collect();
                available.sort_unstable();
                return Err(format!(
                    "${name}.{col}: result has no field '{col}' (available: {})",
                    available.join(", ")
                ));
            }
            let suffix = if null_safe { "?" } else { "" };
            return Ok(format!("${name}.{col}{suffix}"));
        }
    };

    if val.is_null() {
        return if null_safe {
            Ok("NULL".to_string())
        } else {
            Err(format!("${name}.{col} is NULL"))
        };
    }

    Ok(format_value(val, for_sql))
}

/// Expand `$name.*` into an inline `VALUES` subquery (SQL) or JSON array (raw).
fn expand_row_set(name: &str, json_str: &str, for_sql: bool) -> Result<String, String> {
    /// Maximum number of rows allowed in `$name.*` expansion to prevent
    /// unbounded SQL string allocation from large result sets.
    const MAX_ROWSET_EXPANSION: usize = 10_000;

    let json: serde_json::Value = serde_json::from_str(json_str)
        .map_err(|e| format!("${name}.* — invalid result JSON: {e}"))?;

    let rows = json
        .get("rows")
        .and_then(|r| r.as_array())
        .ok_or_else(|| format!("${name}.* — invalid result format"))?;

    if rows.len() > MAX_ROWSET_EXPANSION {
        return Err(format!(
            "${name}.* — result has {} rows, exceeding the maximum of {} for row-set expansion. \
             Use pagination or intermediate tables for large result sets.",
            rows.len(),
            MAX_ROWSET_EXPANSION
        ));
    }

    if !for_sql {
        return Ok(serde_json::to_string(rows).unwrap());
    }

    let quoted_name = quote_identifier(name);

    if rows.is_empty() {
        return Ok(format!("(SELECT NULL WHERE false) AS {quoted_name}"));
    }

    let first_obj = rows[0]
        .as_object()
        .ok_or_else(|| format!("${name}.* — row is not an object"))?;
    let col_names: Vec<&str> = first_obj.keys().map(|k| k.as_str()).collect();

    let mut value_rows = Vec::with_capacity(rows.len());
    for row in rows {
        let obj = row
            .as_object()
            .ok_or_else(|| format!("${name}.* — row is not an object"))?;
        let vals: Vec<String> = col_names
            .iter()
            .map(|&col| match obj.get(col) {
                Some(serde_json::Value::String(s)) => {
                    let escaped = s.replace('\'', "''");
                    format!("'{escaped}'::text")
                }
                Some(serde_json::Value::Number(n)) => n.to_string(),
                Some(serde_json::Value::Bool(b)) => b.to_string(),
                Some(serde_json::Value::Null) | None => "NULL".to_string(),
                Some(other) => {
                    let escaped = other.to_string().replace('\'', "''");
                    format!("'{escaped}'::text")
                }
            })
            .collect();
        value_rows.push(format!("({})", vals.join(",")));
    }

    let col_list = col_names
        .iter()
        .map(|c| quote_identifier(c))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "(VALUES {}) AS {quoted_name}({col_list})",
        value_rows.join(", ")
    ))
}

/// Scan-based result substitution supporting:
///   `$name.*`    — row-set expansion
///   `$name.col?` — null-safe dot-notation
///   `$name.col`  — strict dot-notation
///   `$name?`     — null-safe scalar
///   `$name`      — strict scalar
fn substitute_results(
    input: &str,
    results: &std::collections::HashMap<String, String>,
    for_sql: bool,
) -> Result<String, String> {
    if results.is_empty() {
        return Ok(input.to_string());
    }

    // Sort names longest-first to avoid partial matches
    let mut names: Vec<&str> = results.keys().map(|s| s.as_str()).collect();
    names.sort_by_key(|name| std::cmp::Reverse(name.len()));

    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    let input_bytes = input.as_bytes();

    while i < input.len() {
        if input_bytes[i] != b'$' {
            let ch = input[i..].chars().next().unwrap();
            out.push(ch);
            i += ch.len_utf8();
            continue;
        }

        let after_dollar = &input[i + 1..];
        let mut matched = false;

        for name in &names {
            if !after_dollar.starts_with(name) {
                continue;
            }

            let after_name = &after_dollar[name.len()..];
            let json_str = &results[*name];

            // 1. $name.* — row-set expansion
            if after_name.starts_with(".*") {
                let replacement = expand_row_set(name, json_str, for_sql)?;
                out.push_str(&replacement);
                i += 1 + name.len() + 2; // $ + name + .*
                matched = true;
                break;
            }

            // 2/3. $name.col? or $name.col — dot-notation
            if let Some(after_dot) = after_name.strip_prefix('.') {
                let col = parse_identifier(after_dot);
                if !col.is_empty() {
                    let after_col = &after_dot[col.len()..];
                    let null_safe = after_col.starts_with('?');
                    let replacement =
                        extract_column_value(name, json_str, col, null_safe, for_sql)?;
                    out.push_str(&replacement);
                    i += 1 + name.len() + 1 + col.len() + if null_safe { 1 } else { 0 };
                    matched = true;
                    break;
                }
                // No valid column name after dot — fall through to bare $name
            }

            // 4. $name? — null-safe scalar
            if after_name.starts_with('?') {
                let replacement = extract_first_column_value(name, json_str, true, for_sql)?;
                out.push_str(&replacement);
                i += 1 + name.len() + 1; // $ + name + ?
                matched = true;
                break;
            }

            // 5. $name — strict scalar (with word-boundary check)
            if after_name.is_empty() || !is_ident_continue(after_name.as_bytes()[0]) {
                let replacement = extract_first_column_value(name, json_str, false, for_sql)?;
                out.push_str(&replacement);
                i += 1 + name.len();
                matched = true;
                break;
            }

            // Next char is an identifier continuation — try shorter names
        }

        if !matched {
            out.push('$');
            i += 1;
        }
    }

    Ok(out)
}

/// Substitute `{name}` placeholders in a single left-to-right pass over the template.
/// Inserted values are appended as opaque text and are never scanned for more placeholders.
fn substitute_braced_variables(
    template: &str,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
) -> String {
    let mut out = String::with_capacity(template.len());
    let mut remaining = template;

    while let Some(open) = remaining.find('{') {
        out.push_str(&remaining[..open]);
        let after_open = &remaining[open + 1..];
        let Some(close) = after_open.find('}') else {
            out.push_str(&remaining[open..]);
            return out;
        };

        let name = &after_open[..close];
        let replacement = match name {
            "sys_instance_id" => Some(sys_vars.instance_id.as_str()),
            "sys_label" => Some(sys_vars.label.as_deref().unwrap_or("")),
            _ if parse_identifier(name).len() == name.len() => vars.get(name).map(String::as_str),
            _ => None,
        };

        if let Some(value) = replacement {
            out.push_str(value);
        } else {
            out.push_str(&remaining[open..open + close + 2]);
        }
        remaining = &after_open[close + 1..];
    }

    out.push_str(remaining);
    out
}

/// Substitute all variable types in a query:
/// - {name} for user vars (from FunctionInput.vars) - values are inserted as-is
/// - {sys_instance_id}, {sys_label} for system vars - inserted as-is
/// - $name, $name.col, $name?, $name.col?, $name.* for named results (from |=>)
///
/// User vars and system vars are substituted without quoting - the user should
/// handle SQL escaping in the original query if needed.
///
/// Returns `Err` if a strict (non-`?`) pattern references a result with no rows
/// or a NULL value.
pub fn substitute_all_with_options(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
    quote_results_for_sql: bool,
) -> Result<String, String> {
    // SECURITY: Raw substitution of user vars is by design — variables are
    // intended for SQL fragments (table names, expressions), not just values.
    // The user controls both the variable content and the query template, and
    // SQL executes under their own role via connect_as_user().
    // See docs/spec-security-model.md §4.3, T10.
    // 1/2. Substitute system and user vars in one pass (inserted as-is, no quoting).
    let result = substitute_braced_variables(query, vars, sys_vars);

    // 3. Substitute results: $name with dot-notation, null-safe, and row-set support
    substitute_results(&result, results, quote_results_for_sql)
}

/// Substitute all variables with SQL quoting (default for SQL contexts)
pub fn substitute_all(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
) -> Result<String, String> {
    substitute_all_with_options(query, results, vars, sys_vars, true)
}

/// Substitute all variables without SQL quoting (for URLs, headers, etc.)
pub fn substitute_all_raw(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
) -> Result<String, String> {
    substitute_all_with_options(query, results, vars, sys_vars, false)
}

/// Report whether `value` consists of exactly one variable reference and nothing
/// else, ignoring surrounding whitespace.
///
/// Accepted forms:
/// - `$name`, `$name?`
/// - `$name.col`, `$name.col?`
/// - `{name}` — covers user variables and `{sys_*}` alike
///
/// Deliberately rejected:
/// - `$name.*` — a row-set expansion is never a single opaque value
/// - anything with surrounding literal text, or more than one reference
///
/// This exists for contexts where a value must be replaced wholesale or not at
/// all — notably a multipart part's `data_b64`, where splicing a substitution
/// into the middle of a base64 string can only corrupt the payload.
pub fn is_whole_value_reference(value: &str) -> bool {
    let value = value.trim();

    if let Some(rest) = value.strip_prefix('$') {
        let name = parse_identifier(rest);
        if name.is_empty() {
            return false;
        }
        let rest = &rest[name.len()..];

        // Dot notation, but never the `.*` row-set form.
        let rest = match rest.strip_prefix('.') {
            Some(after_dot) => {
                let col = parse_identifier(after_dot);
                if col.is_empty() {
                    return false;
                }
                &after_dot[col.len()..]
            }
            None => rest,
        };

        // An optional null-safe marker may follow, and nothing else.
        return rest.is_empty() || rest == "?";
    }

    if let Some(rest) = value.strip_prefix('{') {
        let name = parse_identifier(rest);
        return !name.is_empty() && &rest[name.len()..] == "}";
    }

    false
}

/// Legacy function for backward compatibility - only substitutes $name results
pub fn substitute_variables(
    query: &str,
    results: &std::collections::HashMap<String, String>,
) -> Result<String, String> {
    substitute_all(
        query,
        results,
        &std::collections::HashMap::new(),
        &SystemVars {
            instance_id: String::new(),
            label: None,
        },
    )
}

// ============================================================================
// Function Graph Types
// ============================================================================

/// Represents a node in the function graph
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionNode {
    pub id: String,
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
    /// Effective role (current_user) for privilege isolation and connection authentication
    pub submitted_by: String,
    /// Target database for SQL execution (None = extension database)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
}

/// Supplies graph-local node IDs during materialization.
///
/// IDs must be unique within a graph. Callers that persist the result must also
/// supply IDs matching the database's `^[0-9a-f]{8}$` constraint; non-persisting
/// callers such as explain may use display-only IDs.
pub(crate) trait IdSource {
    fn next_id(&mut self) -> Result<String, String>;
}

impl<F> IdSource for F
where
    F: FnMut() -> Result<String, String>,
{
    fn next_id(&mut self) -> Result<String, String> {
        self()
    }
}

/// A graph-materialization error with the path of the offending node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GraphError {
    pub path: String,
    pub message: String,
}

impl std::fmt::Display for GraphError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.path, self.message)
    }
}

struct PendingGraphNode {
    node: Durofut,
    id: String,
    depth: usize,
    path: String,
}

/// A node whose graph references and config children have been materialized.
///
/// Persistence metadata is intentionally absent because flattening does not
/// know the submitting role, target database, or instance ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MaterializedNode {
    pub id: String,
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
}

/// Materialize a Durofut tree into pre-order nodes with parent-before-child
/// references.
///
/// For a valid graph, the returned root ID equals the first node's ID. The ID
/// source is called once per discovered node and may reject generation before
/// any persistence occurs.
pub(crate) fn flatten_graph(
    root: &Durofut,
    ids: &mut impl IdSource,
) -> Result<(String, Vec<MaterializedNode>), GraphError> {
    let root_id = ids.next_id().map_err(|message| GraphError {
        path: "root".to_string(),
        message,
    })?;
    let mut pending = vec![PendingGraphNode {
        node: root.clone(),
        id: root_id.clone(),
        depth: 0,
        path: "root".to_string(),
    }];
    let mut nodes = Vec::new();
    let mut discovered_nodes = 1;

    while let Some(entry) = pending.pop() {
        #[cfg(not(test))]
        pgrx::check_for_interrupts!();
        if entry.depth > MAX_GRAPH_DEPTH {
            return Err(GraphError {
                path: entry.path,
                message: format!(
                    "Graph exceeds maximum nesting depth of {}. Simplify the workflow or break it into multiple instances.",
                    MAX_GRAPH_DEPTH
                ),
            });
        }
        if !VALID_NODE_TYPES.contains(&entry.node.node_type.as_str()) {
            return Err(GraphError {
                path: entry.path,
                message: format!(
                    "Unknown node_type '{}'. Valid types: {}",
                    entry.node.node_type,
                    VALID_NODE_TYPES.join(", ")
                ),
            });
        }
        entry
            .node
            .validate_config_children()
            .map_err(|message| GraphError {
                path: entry.path.clone(),
                message,
            })?;

        let mut children = Vec::new();
        let mut parse_child = |raw: &serde_json::value::RawValue, segment: String| {
            let path = format!("{}.{}", entry.path, segment);
            if discovered_nodes >= MAX_GRAPH_NODES {
                return Err(GraphError {
                    path,
                    message: format!(
                        "Workflow exceeds maximum node count of {}. Simplify the workflow or break it into multiple instances.",
                        MAX_GRAPH_NODES
                    ),
                });
            }
            let node = Durofut::child_from_raw(raw).map_err(|message| GraphError {
                path: path.clone(),
                message,
            })?;
            let id = ids.next_id().map_err(|message| GraphError {
                path: path.clone(),
                message,
            })?;
            discovered_nodes += 1;
            children.push(PendingGraphNode {
                node,
                id: id.clone(),
                depth: entry.depth + 1,
                path,
            });
            Ok::<String, GraphError>(id)
        };

        let left_node = entry
            .node
            .left_node
            .as_deref()
            .map(|raw| parse_child(raw, "left".to_string()))
            .transpose()?;
        let right_node = entry
            .node
            .right_node
            .as_deref()
            .map(|raw| parse_child(raw, "right".to_string()))
            .transpose()?;
        let condition_node = if entry.node.node_type == "IF" || entry.node.node_type == "LOOP" {
            entry
                .node
                .condition_node
                .as_deref()
                .map(|raw| parse_child(raw, "condition_node".to_string()))
                .transpose()?
        } else {
            None
        };
        let extra_nodes = if entry.node.node_type == "JOIN" {
            entry
                .node
                .extra_nodes
                .iter()
                .enumerate()
                .map(|(index, raw)| parse_child(raw, format!("extra_nodes[{index}]")))
                .collect::<Result<Vec<_>, _>>()?
        } else {
            Vec::new()
        };

        let query = entry
            .node
            .materialized_query(condition_node.as_deref(), &extra_nodes)
            .map_err(|message| GraphError {
                path: entry.path.clone(),
                message,
            })?;

        nodes.push(MaterializedNode {
            id: entry.id,
            node_type: entry.node.node_type,
            query,
            result_name: entry.node.result_name,
            left_node,
            right_node,
        });

        pending.extend(children.into_iter().rev());
    }

    Ok((root_id, nodes))
}

/// Represents the entire function graph for an instance
/// Note: Uses BTreeMap for deterministic serialization order (required for Duroxide replay)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionGraph {
    pub instance_id: String,
    pub root_node_id: String,
    pub nodes: std::collections::BTreeMap<String, FunctionNode>,
}

fn is_zero_u32(value: &u32) -> bool {
    *value == 0
}

/// Input structure passed to duroxide functions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionInput {
    pub instance_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, serialize_with = "serialize_string_map")]
    pub vars: std::collections::HashMap<String, String>,
    /// Loop iteration counter, incremented on each `continue_as_new`.
    /// Used to enforce a maximum iteration safeguard.
    #[serde(default)]
    pub loop_iteration: u64,
    /// Serialized `FunctionGraph`, carried across `continue_as_new` generations.
    ///
    /// `df.start()` leaves this `None`, so generation 0 loads the graph from the database.
    /// A root loop re-emits the loaded graph here, so an instance reads `df.nodes` exactly
    /// once no matter how many iterations it runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graph: Option<String>,
    /// Top-level transaction that owns the initial df.instances/df.nodes writes.
    ///
    /// New starts carry this so graph loading can distinguish a still-open caller
    /// transaction from a rollback. Historical inputs omit it and retain the
    /// legacy bounded graph-load activity for replay compatibility.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_xid: Option<String>,
    /// Number of graph-admission polls already made for `origin_xid`.
    ///
    /// Kept separate from `loop_iteration`: admission can compact its history
    /// with continue_as_new before user graph execution begins.
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub graph_wait_attempt: u32,
    /// Number of transient graph-admission `Retry` outcomes already observed
    /// for `origin_xid` (DB errors, query timeouts, snapshot-visibility lag).
    ///
    /// Tracked independently from `graph_wait_attempt`: waiting on the
    /// caller's own open transaction (`InProgress`) is legitimately
    /// unbounded, but waiting on the worker's own machinery is not, so it is
    /// bounded separately (see `MAX_GRAPH_RETRY_ATTEMPTS`).
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub graph_retry_attempt: u32,
}

pub(crate) fn serialize_string_map<S>(
    map: &std::collections::HashMap<String, String>,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    use serde::Serialize;

    map.iter()
        .collect::<std::collections::BTreeMap<_, _>>()
        .serialize(serializer)
}

pub(crate) fn string_map_to_json(
    map: &std::collections::HashMap<String, String>,
) -> Result<String, serde_json::Error> {
    serde_json::to_string(&map.iter().collect::<std::collections::BTreeMap<_, _>>())
}

/// Configuration for HTTP requests
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpConfig {
    pub url: String,
    pub method: String,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub headers: Option<serde_json::Value>,
    #[serde(default = "default_http_timeout")]
    pub timeout_seconds: u64,
    /// Role that called df.start() (audit trail)
    #[serde(default)]
    pub submitted_by: Option<String>,
}

fn default_http_timeout() -> u64 {
    30
}

/// One part of a multipart/form-data body (df.http_multipart).
///
/// `data_b64` is the base64-encoded part payload. The config is serialized to
/// JSON and durably checkpointed as a string, so raw bytes cannot ride inline;
/// base64 keeps it text-safe. Decoded by the execute_multipart activity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultipartPart {
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_type: Option<String>,
    pub data_b64: String,
}

/// Configuration for multipart/form-data HTTP requests (df.http_multipart).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultipartConfig {
    pub url: String,
    pub method: String,
    pub parts: Vec<MultipartPart>,
    #[serde(default)]
    pub headers: Option<serde_json::Value>,
    #[serde(default = "default_http_timeout")]
    pub timeout_seconds: u64,
    /// Role that called df.start() (audit trail)
    #[serde(default)]
    pub submitted_by: Option<String>,
}

// ============================================================================
// Durofut Type - Represents a function node reference
// ============================================================================

/// Valid node types for Durofut nodes.
pub const VALID_NODE_TYPES: &[&str] = &[
    "SQL",
    "THEN",
    "IF",
    "JOIN",
    "LOOP",
    "BREAK",
    "RACE",
    "SLEEP",
    "WAIT_SCHEDULE",
    "HTTP",
    "HTTP_MULTIPART",
    "SIGNAL",
];
const NON_FUTURE_HELPER_GUC: &str = "df.non_future_helper";

pub fn mark_non_future_helper_call(function_name: &str) {
    let name = CString::new(NON_FUTURE_HELPER_GUC).expect("GUC name must not contain NUL bytes");
    let statement_timestamp = unsafe { pgrx::pg_sys::GetCurrentStatementStartTimestamp() };
    let marker = CString::new(format!("{}\n{}", function_name, statement_timestamp))
        .expect("helper name must not contain NUL bytes");

    unsafe {
        pgrx::pg_sys::set_config_option(
            name.as_ptr(),
            marker.as_ptr(),
            pgrx::pg_sys::GucContext::PGC_USERSET,
            pgrx::pg_sys::GucSource::PGC_S_SESSION,
            pgrx::pg_sys::GucAction::GUC_ACTION_LOCAL,
            true,
            pgrx::PgLogLevel::ERROR as i32,
            false,
        );
    }
}

fn deserialize_raw_object<'de, D>(
    deserializer: D,
) -> Result<Option<Box<serde_json::value::RawValue>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Box<serde_json::value::RawValue>>::deserialize(deserializer)?;
    if value
        .as_ref()
        .is_some_and(|raw| !raw.get().trim_start().starts_with('{'))
    {
        return Err(serde::de::Error::custom(
            "Durofut children must be JSON objects",
        ));
    }
    Ok(value)
}

fn deserialize_raw_objects<'de, D>(
    deserializer: D,
) -> Result<Vec<Box<serde_json::value::RawValue>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let values = Vec::<Box<serde_json::value::RawValue>>::deserialize(deserializer)?;
    if values
        .iter()
        .any(|raw| !raw.get().trim_start().starts_with('{'))
    {
        return Err(serde::de::Error::custom(
            "extra_nodes entries must be Durofut JSON objects",
        ));
    }
    Ok(values)
}

fn deserialize_condition_node<'de, D>(
    deserializer: D,
) -> Result<Option<Box<serde_json::value::RawValue>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Box<serde_json::value::RawValue>>::deserialize(deserializer)?;
    if value
        .as_ref()
        .is_some_and(|raw| !raw.get().trim_start().starts_with('{'))
    {
        return Err(serde::de::Error::custom(
            "condition_node must be a Durofut JSON object",
        ));
    }
    Ok(value)
}

/// The Durofut type represents a "durable future" - a reference to a node in the function graph.
/// Children are embedded as opaque JSON objects, not stored as ID references. Keeping them as
/// `RawValue` lets each graph level deserialize independently without serde_json's recursion limit.
/// Node IDs are generated when the graph is materialized, before insertion into df.nodes.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Durofut {
    pub node_type: String,
    #[serde(
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_raw_object",
        default
    )]
    pub left_node: Option<Box<serde_json::value::RawValue>>,
    #[serde(
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_raw_object",
        default
    )]
    pub right_node: Option<Box<serde_json::value::RawValue>>,
    #[serde(
        skip_serializing_if = "Option::is_none",
        deserialize_with = "deserialize_condition_node",
        default
    )]
    pub condition_node: Option<Box<serde_json::value::RawValue>>,
    #[serde(
        skip_serializing_if = "Vec::is_empty",
        deserialize_with = "deserialize_raw_objects",
        default
    )]
    pub extra_nodes: Vec<Box<serde_json::value::RawValue>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_name: Option<String>,
}

impl Durofut {
    pub fn into_raw(self) -> Box<serde_json::value::RawValue> {
        serde_json::value::to_raw_value(&self).expect("failed to serialize Durofut child")
    }

    pub(crate) fn child_from_raw(raw: &serde_json::value::RawValue) -> Result<Self, String> {
        serde_json::from_str(raw.get())
            .map_err(|e| format!("failed to deserialize Durofut child: {}", e))
    }

    fn same_statement_non_future_helper_name(s: &str) -> Option<String> {
        // Fast path: legitimate Durofut envelopes are JSON objects starting
        // with '{'. Anything else (plain text such as "OK", "completed",
        // "failed", "cancelled", error messages, etc.) might be the return
        // value of a non-future helper, so we look up the marker GUC to
        // attribute it by name. Restricting the SPI lookup to non-JSON inputs
        // keeps the common case (JSON envelopes flowing through composers)
        // free of an extra catalog query, while letting *any* helper that
        // calls mark_non_future_helper_call surface a precise error -- not
        // just the ones that happen to return "OK".
        if s.trim_start().starts_with('{') {
            return None;
        }

        let name =
            CString::new(NON_FUTURE_HELPER_GUC).expect("GUC name must not contain NUL bytes");
        let marker = unsafe {
            let value = pgrx::pg_sys::GetConfigOption(name.as_ptr(), true, false);
            (!value.is_null()).then(|| CStr::from_ptr(value).to_string_lossy().into_owned())
        }?;
        let (helper_name, marker_timestamp) = marker.split_once('\n')?;
        let marker_timestamp = marker_timestamp.parse::<pgrx::pg_sys::TimestampTz>().ok()?;
        let statement_timestamp = unsafe { pgrx::pg_sys::GetCurrentStatementStartTimestamp() };

        (marker_timestamp == statement_timestamp).then(|| helper_name.to_string())
    }

    fn non_future_helper_error(helper_name: &str) -> String {
        format!(
            "{} cannot be used as a workflow step. Call {} before df.start().",
            helper_name, helper_name
        )
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("failed to serialize Durofut")
    }

    /// Fallible deserialization from JSON. Preferred over `from_json()` in
    /// production code paths where corrupted data must not crash the worker.
    pub fn try_from_json(s: &str) -> Result<Self, String> {
        serde_json::from_str(s).map_err(|e| format!("failed to deserialize Durofut: {}", e))
    }

    /// Deserialize from JSON, panicking on failure.
    /// Suitable for test code only — use `try_from_json()` in production paths
    /// where invalid input should surface an error rather than crash.
    pub fn from_json(s: &str) -> Self {
        serde_json::from_str(s).expect("failed to deserialize Durofut")
    }

    /// Check if a string is a valid Durofut JSON with a recognized node_type
    pub fn is_durofut(s: &str) -> bool {
        serde_json::from_str::<Durofut>(s)
            .map(|d| VALID_NODE_TYPES.contains(&d.node_type.as_str()))
            .unwrap_or(false)
    }

    /// True when `s` is a JSON object carrying a `node_type` field, i.e. a
    /// Durofut envelope (possibly corrupt) rather than plain SQL text. Uses a
    /// generic JSON parse so it is robust to serialized field ordering.
    fn is_durofut_envelope(s: &str) -> bool {
        matches!(
            serde_json::from_str::<serde_json::Value>(s),
            Ok(v) if v.get("node_type").and_then(|nt| nt.as_str()).is_some()
        )
    }

    /// Ensure a string is a Durofut - if it's already one, parse it; if not, treat as SQL and create a node.
    /// Uses a single deserialization attempt to avoid redundant parsing.
    pub fn ensure(s: &str) -> Self {
        if let Some(helper_name) = Self::same_statement_non_future_helper_name(s) {
            pgrx::error!("{}", Self::non_future_helper_error(&helper_name));
        }
        match serde_json::from_str::<Durofut>(s) {
            Ok(d) if VALID_NODE_TYPES.contains(&d.node_type.as_str()) => d,
            Err(serde_err) if Self::is_durofut_envelope(s) => {
                // A JSON object carrying a node_type is a Durofut envelope that
                // failed to deserialize (e.g. a corrupt or non-object child).
                // Fail loudly instead of silently wrapping the raw envelope as
                // a SQL node, which would later blow up at execution time.
                pgrx::error!(
                    "Invalid Durofut JSON: failed to deserialize workflow step: {}",
                    serde_err
                );
            }
            _ => Durofut {
                node_type: "SQL".to_string(),
                query: Some(s.to_string()),
                ..Default::default()
            },
        }
    }

    /// Strict version of ensure - rejects JSON with unknown node_type instead of wrapping as SQL.
    /// Used by df.start() and other entrypoints where invalid node types should be caught early.
    pub fn ensure_strict(s: &str) -> Result<Self, String> {
        if let Some(helper_name) = Self::same_statement_non_future_helper_name(s) {
            return Err(Self::non_future_helper_error(&helper_name));
        }
        match serde_json::from_str::<Durofut>(s) {
            Ok(d) => {
                if VALID_NODE_TYPES.contains(&d.node_type.as_str()) {
                    Ok(d)
                } else {
                    Err(format!(
                        "Unknown node_type '{}'. Valid types: {}",
                        d.node_type,
                        VALID_NODE_TYPES.join(", ")
                    ))
                }
            }
            Err(serde_err) => {
                // Not valid Durofut JSON - try to parse as generic JSON to check for node_type
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(s) {
                    if let Some(nt) = val.get("node_type").and_then(|v| v.as_str()) {
                        if VALID_NODE_TYPES.contains(&nt) {
                            // Valid node_type but malformed structure
                            return Err(format!(
                                "Malformed Durofut JSON with node_type '{}': {}",
                                nt, serde_err
                            ));
                        }
                        return Err(format!(
                            "Unknown node_type '{}'. Valid types: {}",
                            nt,
                            VALID_NODE_TYPES.join(", ")
                        ));
                    }
                }
                // Not JSON at all or no node_type field - treat as SQL
                Ok(Durofut {
                    node_type: "SQL".to_string(),
                    query: Some(s.to_string()),
                    ..Default::default()
                })
            }
        }
    }

    /// Validate a Durofut node and all its children have valid node_types.
    /// Kept as a compatibility helper for callers that only need validation;
    /// graph entrypoints should consume `flatten_graph` directly.
    pub fn validate_recursive(&self) -> Result<(), String> {
        let mut counter = 0_u32;
        let mut next_id = || {
            counter += 1;
            Ok(format!("{counter:08x}"))
        };
        flatten_graph(self, &mut next_id)
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    fn reject_embedded_config_children(&self) -> Result<(), String> {
        let Some(query) = self.query.as_ref() else {
            return Ok(());
        };
        let Ok(config) = serde_json::from_str::<serde_json::Value>(query) else {
            return Ok(());
        };

        let legacy_field = match self.node_type.as_str() {
            "IF" | "LOOP" if config.get("condition_node").is_some() => Some("condition_node"),
            "JOIN" if config.get("extra_nodes").is_some() => Some("extra_nodes"),
            _ => None,
        };
        if let Some(field) = legacy_field {
            return Err(format!(
                "{} in {} must be a first-class Durofut field, not embedded in query",
                field, self.node_type
            ));
        }

        Ok(())
    }

    fn validate_config_children(&self) -> Result<(), String> {
        let supports_condition = self.node_type == "IF" || self.node_type == "LOOP";
        if self.condition_node.is_some() && !supports_condition {
            return Err(format!(
                "condition_node is not valid for {} nodes",
                self.node_type
            ));
        }
        if !self.extra_nodes.is_empty() && self.node_type != "JOIN" {
            return Err(format!(
                "extra_nodes is not valid for {} nodes",
                self.node_type
            ));
        }

        self.reject_embedded_config_children()?;
        Ok(())
    }

    fn materialized_query(
        &self,
        condition_node: Option<&str>,
        extra_nodes: &[String],
    ) -> Result<Option<String>, String> {
        let has_condition = condition_node.is_some();
        let has_extras = !extra_nodes.is_empty();
        if !has_condition && !has_extras {
            return Ok(self.query.clone());
        }

        let mut config = match self.query.as_ref() {
            Some(query) => serde_json::from_str::<serde_json::Value>(query).map_err(|e| {
                format!(
                    "query in {} must be valid JSON config: {}",
                    self.node_type, e
                )
            })?,
            None => serde_json::json!({}),
        };
        if !config.is_object() {
            return Err(format!(
                "query in {} must be a JSON config object",
                self.node_type
            ));
        }

        if let Some(condition_node) = condition_node {
            config["condition_node"] = serde_json::json!(condition_node);
        }

        if has_extras {
            config["extra_nodes"] = serde_json::json!(extra_nodes);
        }

        Ok(Some(serde_json::to_string(&config).unwrap()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn durofut_raw_children_preserve_wire_format() {
        let json = r#"{"node_type":"THEN","left_node":{"node_type":"SQL","query":"SELECT 1"},"right_node":{"node_type":"SQL","query":"SELECT 2"}}"#;

        let durofut = Durofut::try_from_json(json).unwrap();

        assert_eq!(durofut.to_json(), json);
    }

    #[test]
    fn durofut_deserializes_beyond_serde_recursion_limit() {
        let mut json = r#"{"node_type":"SQL","query":"SELECT 1"}"#.to_string();
        for _ in 0..129 {
            json = format!(
                r#"{{"node_type":"THEN","left_node":{},"right_node":{{"node_type":"SQL","query":"SELECT 1"}}}}"#,
                json
            );
        }

        let durofut = Durofut::try_from_json(&json).unwrap();

        assert!(durofut.validate_recursive().is_ok());
        assert_eq!(durofut.to_json(), json);
    }

    #[test]
    fn deep_join_chain_deserializes_and_validates() {
        // JOIN/RACE nest through left/right RawValue children just like THEN,
        // so a deep JOIN fold must share the corrected opaque-child path.
        let mut json = r#"{"node_type":"SQL","query":"SELECT 1"}"#.to_string();
        for _ in 0..129 {
            json = format!(
                r#"{{"node_type":"JOIN","left_node":{},"right_node":{{"node_type":"SQL","query":"SELECT 1"}}}}"#,
                json
            );
        }

        let durofut = Durofut::try_from_json(&json).unwrap();

        assert!(durofut.validate_recursive().is_ok());
        assert_eq!(durofut.to_json(), json);
    }

    #[test]
    fn is_durofut_envelope_detects_node_type_regardless_of_order() {
        // Robust to serialized field ordering: node_type not first.
        assert!(Durofut::is_durofut_envelope(
            r#"{"query":"SELECT 1","node_type":"SQL"}"#
        ));
        // A corrupt envelope (non-object child) still reads as an envelope.
        assert!(Durofut::is_durofut_envelope(
            r#"{"node_type":"THEN","left_node":123}"#
        ));
        // Plain SQL and non-envelope JSON are not envelopes.
        assert!(!Durofut::is_durofut_envelope("SELECT 1"));
        assert!(!Durofut::is_durofut_envelope(r#"{"foo":1}"#));
    }

    #[test]
    fn whole_value_reference_accepts_single_references() {
        for value in [
            "$payload",
            "$payload?",
            "$resp.body",
            "$resp.body?",
            "$_leading_underscore",
            "{myvar}",
            "{sys_instance_id}",
        ] {
            assert!(
                is_whole_value_reference(value),
                "expected `{value}` to be a whole-value reference"
            );
        }
    }

    #[test]
    fn whole_value_reference_tolerates_surrounding_whitespace() {
        assert!(is_whole_value_reference("  $payload  "));
        assert!(is_whole_value_reference("\n{myvar}\t"));
    }

    #[test]
    fn whole_value_reference_rejects_partial_interpolation() {
        for value in [
            "prefix$payload",
            "$payload suffix",
            "$a$b",
            "{a}{b}",
            "{a}tail",
            "head{a}",
            "$resp.body extra",
        ] {
            assert!(
                !is_whole_value_reference(value),
                "expected `{value}` to be rejected as partial interpolation"
            );
        }
    }

    #[test]
    fn whole_value_reference_rejects_row_set_expansion() {
        // A row-set expansion is never a single opaque value.
        assert!(!is_whole_value_reference("$rows.*"));
    }

    #[test]
    fn whole_value_reference_rejects_malformed_and_plain_text() {
        for value in [
            "",
            "   ",
            "$",
            "$1abc",
            "$resp.",
            "{",
            "{}",
            "{unclosed",
            "aGVsbG8=", // ordinary base64
        ] {
            assert!(
                !is_whole_value_reference(value),
                "expected `{value}` to be rejected"
            );
        }
    }

    #[test]
    fn is_truthy_all_types() {
        // (input, expected, label)
        let cases: Vec<(serde_json::Value, bool, &str)> = vec![
            // Booleans
            (json!(true), true, "bool true"),
            (json!(false), false, "bool false"),
            // Numbers
            (json!(1), true, "int 1"),
            (json!(0), false, "int 0"),
            (json!(-1), true, "int -1"),
            (json!(0.1), true, "float 0.1"),
            (json!(0.0), false, "float 0.0"),
            // String boolean words (+ case variants)
            (json!("true"), true, "str 'true'"),
            (json!("false"), false, "str 'false'"),
            (json!("TRUE"), true, "str 'TRUE'"),
            (json!("FALSE"), false, "str 'FALSE'"),
            (json!("yes"), true, "str 'yes'"),
            (json!("Yes"), true, "str 'Yes'"),
            (json!("no"), false, "str 'no'"),
            (json!("No"), false, "str 'No'"),
            (json!("t"), true, "str 't'"),
            (json!("f"), false, "str 'f'"),
            // String numerics
            (json!("1"), true, "str '1'"),
            (json!("0"), false, "str '0'"),
            (json!("-1"), true, "str '-1'"),
            (json!("3.14"), true, "str '3.14'"),
            (json!("0.0"), false, "str '0.0'"),
            // String edge cases
            (json!(""), false, "empty string"),
            (json!("  true  "), true, "whitespace-padded 'true'"),
            (json!("  false  "), false, "whitespace-padded 'false'"),
            (json!("hello"), true, "arbitrary non-empty string"),
            // Null / Array / Object
            (json!(null), false, "null"),
            (json!([]), false, "empty array"),
            (json!([1]), true, "non-empty array"),
            (json!({}), false, "empty object"),
            (json!({"a": 1}), true, "non-empty object"),
        ];

        for (input, expected, label) in &cases {
            assert_eq!(is_truthy(input), *expected, "is_truthy failed for: {label}");
        }
    }

    #[test]
    fn evaluate_condition_json_rows() {
        let cases: Vec<(&str, bool, &str)> = vec![
            (r#"{"rows":[{"col":true}]}"#, true, "bool true"),
            (r#"{"rows":[{"col":false}]}"#, false, "bool false"),
            (r#"{"rows":[{"col":"false"}]}"#, false, "string 'false'"),
            (r#"{"rows":[{"col":"no"}]}"#, false, "string 'no'"),
            (r#"{"rows":[{"col":0}]}"#, false, "int 0"),
            (r#"{"rows":[{"col":null}]}"#, false, "null"),
            // Empty result set (no rows) should be falsy
            (r#"{"rows":[],"row_count":0}"#, false, "empty rows"),
            (r#"{"rows":[]}"#, false, "empty rows (no row_count)"),
        ];

        for (input, expected, label) in &cases {
            assert_eq!(
                evaluate_condition(input).unwrap(),
                *expected,
                "evaluate_condition failed for JSON rows with: {label}"
            );
        }
    }

    #[test]
    fn evaluate_condition_raw_string_fallback() {
        let cases: Vec<(&str, bool)> = vec![("true", true), ("false", false), ("no", false)];

        for (input, expected) in &cases {
            assert_eq!(
                evaluate_condition(input).unwrap(),
                *expected,
                "evaluate_condition raw fallback failed for: {input}"
            );
        }
    }

    #[test]
    fn configured_host_takes_precedence_over_pghost() {
        assert_eq!(
            resolve_host(
                Some("configured.example.com".to_string()),
                Some("environment.example.com".to_string()),
            ),
            "configured.example.com"
        );
    }

    #[test]
    fn pghost_is_used_when_host_guc_is_unset() {
        assert_eq!(
            resolve_host(None, Some("environment.example.com".to_string())),
            "environment.example.com"
        );
    }

    #[test]
    fn pghost_is_used_when_host_guc_is_empty() {
        assert_eq!(
            resolve_host(
                Some(String::new()),
                Some("environment.example.com".to_string()),
            ),
            "environment.example.com"
        );
    }

    #[test]
    fn host_defaults_to_loopback_when_guc_and_pghost_are_unset() {
        assert_eq!(resolve_host(None, None), "127.0.0.1");
    }

    #[test]
    fn build_connection_url_tcp_host_unchanged() {
        assert_eq!(
            build_connection_url("postgres", "127.0.0.1", 5432, "postgres"),
            "postgres://postgres@127.0.0.1:5432/postgres"
        );
    }

    #[test]
    fn build_connection_url_hostname_unchanged() {
        assert_eq!(
            build_connection_url("worker", "db.internal.example.com", 6432, "app"),
            "postgres://worker@db.internal.example.com:6432/app"
        );
    }

    #[test]
    fn build_connection_url_unix_socket_percent_encoded() {
        assert_eq!(
            build_connection_url("postgres", "/controller/run", 5432, "postgres"),
            "postgres://postgres@%2Fcontroller%2Frun:5432/postgres"
        );
    }

    #[test]
    fn build_connection_url_unix_socket_standard_dir() {
        assert_eq!(
            build_connection_url("postgres", "/var/run/postgresql", 5432, "postgres"),
            "postgres://postgres@%2Fvar%2Frun%2Fpostgresql:5432/postgres"
        );
    }

    #[test]
    fn build_connection_url_socket_parses_to_socket() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        let url = build_connection_url("postgres", "/controller/run", 5432, "postgres");
        let opts = PgConnectOptions::from_str(&url).expect("socket URL should parse");
        assert_eq!(
            opts.get_socket().map(|p| p.to_string_lossy().into_owned()),
            Some("/controller/run".to_string()),
        );
    }

    #[test]
    fn build_connection_url_tcp_parses_to_host() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        let url = build_connection_url("postgres", "127.0.0.1", 5432, "postgres");
        let opts = PgConnectOptions::from_str(&url).expect("TCP URL should parse");
        assert_eq!(opts.get_host(), "127.0.0.1");
        assert!(opts.get_socket().is_none());
    }

    #[test]
    fn build_connection_url_socket_with_special_chars_parses_to_socket() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        let path = "/var/run/pg data";
        let url = build_connection_url("postgres", path, 5432, "postgres");
        let opts = PgConnectOptions::from_str(&url).expect("socket URL should parse");
        assert_eq!(
            opts.get_socket().map(|p| p.to_string_lossy().into_owned()),
            Some(path.to_string()),
        );
    }

    #[test]
    fn build_connection_url_socket_path_is_opaque_no_tcp_injection() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        // A leading-`/` host with URL metacharacters must remain a single opaque
        // socket path (no TCP host or query-parameter interpretation).
        let path = "/@evil.com?sslmode=disable";
        let url = build_connection_url("postgres", path, 5432, "postgres");
        let opts = PgConnectOptions::from_str(&url).expect("socket URL should parse");
        assert_eq!(
            opts.get_socket().map(|p| p.to_string_lossy().into_owned()),
            Some(path.to_string()),
        );
        assert_ne!(opts.get_host(), "evil.com");
    }

    #[test]
    fn build_connection_url_tcp_host_with_query_is_opaque() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        // A configured host carrying URL metacharacters must stay inside the host
        // component; it must not split off and apply connection parameters.
        let url = build_connection_url(
            "postgres",
            "db.example.com?sslmode=disable",
            5432,
            "postgres",
        );
        let opts = PgConnectOptions::from_str(&url).expect("TCP URL should parse");
        assert_ne!(opts.get_host(), "db.example.com");
        assert!(matches!(
            opts.get_ssl_mode(),
            sqlx::postgres::PgSslMode::Prefer
        ));
    }

    #[test]
    fn build_connection_url_tcp_host_with_userinfo_is_opaque() {
        use sqlx::postgres::PgConnectOptions;
        use std::str::FromStr;

        let url = build_connection_url("postgres", "x@evil.com", 5432, "postgres");
        let opts = PgConnectOptions::from_str(&url).expect("TCP URL should parse");
        assert_ne!(opts.get_host(), "evil.com");
    }

    #[test]
    fn build_connection_url_ipv6_host_unchanged() {
        assert_eq!(
            build_connection_url("postgres", "[::1]", 5432, "postgres"),
            "postgres://postgres@[::1]:5432/postgres"
        );
    }

    #[test]
    fn connection_url_application_name_is_encoded() {
        let url = connection_url_with_application_name(
            "postgres://worker@localhost/app",
            WORKER_DUROXIDE_APPLICATION_NAME,
        );
        let opts = sqlx::postgres::PgConnectOptions::from_str(&url)
            .expect("URL with application_name should parse");

        assert_eq!(
            opts.get_application_name(),
            Some(WORKER_DUROXIDE_APPLICATION_NAME)
        );
    }

    #[test]
    fn connection_url_application_name_preserves_existing_parameters() {
        let url = connection_url_with_application_name(
            "postgres://worker@localhost/app?sslmode=disable",
            BACKEND_DUROXIDE_APPLICATION_NAME,
        );
        let opts = sqlx::postgres::PgConnectOptions::from_str(&url)
            .expect("URL with existing parameters should parse");

        assert_eq!(
            opts.get_application_name(),
            Some(BACKEND_DUROXIDE_APPLICATION_NAME)
        );
    }

    #[test]
    fn application_names_are_valid_postgresql_names() {
        for application_name in [
            WORKER_MANAGEMENT_APPLICATION_NAME,
            WORKER_POLL_APPLICATION_NAME,
            WORKER_DUROXIDE_APPLICATION_NAME,
            WORKER_WORKFLOW_SQL_APPLICATION_NAME,
            BACKEND_DUROXIDE_APPLICATION_NAME,
            BACKEND_MONITORING_APPLICATION_NAME,
            BACKEND_NEW_TRANSACTION_APPLICATION_NAME,
        ] {
            assert!(application_name.is_ascii());
            assert!(application_name.len() < 64);
        }
    }

    fn assert_provider_application_name(config: duroxide_pg::ProviderConfig, expected: &str) {
        let duroxide_pg::ConnectionConfig::Url(url) = config.connection else {
            panic!("provider should use URL connection configuration");
        };
        let opts =
            sqlx::postgres::PgConnectOptions::from_str(&url).expect("provider URL should parse");
        assert_eq!(opts.get_application_name(), Some(expected));
    }

    #[test]
    fn backend_provider_uses_backend_application_name() {
        assert_provider_application_name(
            backend_provider_config("postgres://worker@localhost/app", "_duroxide"),
            BACKEND_DUROXIDE_APPLICATION_NAME,
        );
    }

    #[test]
    fn worker_provider_uses_worker_application_name() {
        assert_provider_application_name(
            worker_provider_config("postgres://worker@localhost/app", "_duroxide"),
            WORKER_DUROXIDE_APPLICATION_NAME,
        );
    }

    // ============================================================================
    // Substitution Engine Tests
    // ============================================================================

    fn make_results(entries: &[(&str, &str)]) -> std::collections::HashMap<String, String> {
        entries
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn empty_vars() -> std::collections::HashMap<String, String> {
        std::collections::HashMap::new()
    }

    #[test]
    fn replay_maps_serialize_canonically() {
        let forward = make_results(&[("alpha", "1"), ("beta", "2"), ("gamma", "3")]);
        let reverse = make_results(&[("gamma", "3"), ("beta", "2"), ("alpha", "1")]);

        let forward_json = string_map_to_json(&forward).unwrap();
        let reverse_json = string_map_to_json(&reverse).unwrap();

        assert_eq!(forward_json, r#"{"alpha":"1","beta":"2","gamma":"3"}"#);
        assert_eq!(forward_json, reverse_json);

        let forward_input = FunctionInput {
            instance_id: "instance".to_string(),
            label: None,
            vars: forward,
            loop_iteration: 0,
            graph: None,
            origin_xid: None,
            graph_wait_attempt: 0,
            graph_retry_attempt: 0,
        };
        let reverse_input = FunctionInput {
            instance_id: "instance".to_string(),
            label: None,
            vars: reverse,
            loop_iteration: 0,
            graph: None,
            origin_xid: None,
            graph_wait_attempt: 0,
            graph_retry_attempt: 0,
        };
        assert_eq!(
            serde_json::to_string(&forward_input).unwrap(),
            serde_json::to_string(&reverse_input).unwrap()
        );
    }

    #[test]
    fn function_input_origin_xid_is_backward_compatible() {
        let legacy_json = r#"{"instance_id":"abc12345","label":null,"vars":{},"loop_iteration":0}"#;
        let legacy: FunctionInput = serde_json::from_str(legacy_json).unwrap();
        assert_eq!(legacy.origin_xid, None);
        assert!(!serde_json::to_string(&legacy)
            .unwrap()
            .contains("origin_xid"));

        let current = FunctionInput {
            instance_id: "abc12345".to_string(),
            label: None,
            vars: std::collections::HashMap::new(),
            loop_iteration: 0,
            graph: None,
            origin_xid: Some("123456".to_string()),
            graph_wait_attempt: 0,
            graph_retry_attempt: 0,
        };
        let current_json = serde_json::to_string(&current).unwrap();
        assert!(current_json.ends_with(r#","origin_xid":"123456"}"#));
        assert_eq!(
            serde_json::from_str::<FunctionInput>(&current_json)
                .unwrap()
                .origin_xid
                .as_deref(),
            Some("123456")
        );

        let compacted = FunctionInput {
            graph_wait_attempt: 64,
            ..current
        };
        let compacted_json = serde_json::to_string(&compacted).unwrap();
        assert!(compacted_json.ends_with(r#","graph_wait_attempt":64}"#));

        let retry_compacted = FunctionInput {
            graph_retry_attempt: 3,
            ..compacted
        };
        let retry_compacted_json = serde_json::to_string(&retry_compacted).unwrap();
        assert!(
            retry_compacted_json.ends_with(r#","graph_wait_attempt":64,"graph_retry_attempt":3}"#)
        );
        assert_eq!(
            serde_json::from_str::<FunctionInput>(&retry_compacted_json)
                .unwrap()
                .graph_retry_attempt,
            3
        );
    }

    fn sys_vars() -> SystemVars {
        SystemVars {
            instance_id: "test-id".to_string(),
            label: None,
        }
    }

    #[test]
    fn user_variable_substitution_does_not_rescan_inserted_values() {
        let vars = make_results(&[("a", "{b}"), ("b", "value")]);

        let out = substitute_all_raw("{a} / {b}", &empty_vars(), &vars, &sys_vars()).unwrap();

        assert_eq!(out, "{b} / value");
    }

    #[test]
    fn user_variable_substitution_is_independent_of_map_insertion_order() {
        let forward = make_results(&[("a", "{b}"), ("b", "value")]);
        let reverse = make_results(&[("b", "value"), ("a", "{b}")]);

        let forward_out =
            substitute_all_raw("{a} / {b}", &empty_vars(), &forward, &sys_vars()).unwrap();
        let reverse_out =
            substitute_all_raw("{a} / {b}", &empty_vars(), &reverse, &sys_vars()).unwrap();

        assert_eq!(forward_out, reverse_out);
        assert_eq!(forward_out, "{b} / value");
    }

    #[test]
    fn braced_substitution_preserves_unknowns_and_resolves_system_vars_once() {
        let vars = make_results(&[("name", "{sys_instance_id}")]);
        let system = SystemVars {
            instance_id: "instance-42".to_string(),
            label: Some("billing".to_string()),
        };

        let out = substitute_all_raw(
            "{sys_instance_id}/{sys_label}/{name}/{unknown}",
            &empty_vars(),
            &vars,
            &system,
        )
        .unwrap();

        assert_eq!(out, "instance-42/billing/{sys_instance_id}/{unknown}");
    }

    #[test]
    fn test_dot_notation_string() {
        let results =
            make_results(&[("doc", r#"{"rows":[{"id":1,"name":"Alice"}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $doc.name", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT 'Alice'");
    }

    #[test]
    fn test_dot_notation_number() {
        let results = make_results(&[(
            "doc",
            r#"{"rows":[{"id":42,"name":"Alice"}],"row_count":1}"#,
        )]);
        let out = substitute_all("SELECT $doc.id", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT 42");
    }

    #[test]
    fn envelope_fields_resolve_without_a_rows_array() {
        // HTTP / HTTP_MULTIPART results are flat response envelopes.
        let results = make_results(&[(
            "resp",
            r#"{"status":200,"body":"aGVsbG8=","encoding":"base64","ok":true,"duration_ms":12}"#,
        )]);
        assert_eq!(
            substitute_all_raw("$resp.body", &results, &empty_vars(), &sys_vars()).unwrap(),
            "aGVsbG8="
        );
        assert_eq!(
            substitute_all_raw("$resp.encoding", &results, &empty_vars(), &sys_vars()).unwrap(),
            "base64"
        );
        assert_eq!(
            substitute_all("SELECT $resp.status", &results, &empty_vars(), &sys_vars()).unwrap(),
            "SELECT 200"
        );
        assert_eq!(
            substitute_all("SELECT $resp.ok", &results, &empty_vars(), &sys_vars()).unwrap(),
            "SELECT true"
        );
    }

    #[test]
    fn envelope_missing_field_fails_raw_but_stays_literal_in_sql() {
        let results = make_results(&[("resp", r#"{"status":200,"ok":true}"#)]);
        // A raw context — URL, header, multipart field — has no parser to catch a
        // leftover pattern, so a missing field must fail rather than travel over
        // the wire verbatim.
        let err = substitute_all_raw("$resp.nope", &results, &empty_vars(), &sys_vars())
            .expect_err("a missing field must fail loudly in a raw context");
        assert!(
            err.contains("no field 'nope'") && err.contains("available: ok, status"),
            "unexpected error: {err}"
        );
        // In SQL the pattern is still left for PostgreSQL to complain about.
        assert_eq!(
            substitute_all("SELECT $resp.nope", &results, &empty_vars(), &sys_vars()).unwrap(),
            "SELECT $resp.nope"
        );
    }

    #[test]
    fn envelope_null_field_honours_null_safe_suffix() {
        let results = make_results(&[("resp", r#"{"status":200,"body":null}"#)]);
        assert_eq!(
            substitute_all("SELECT $resp.body?", &results, &empty_vars(), &sys_vars()).unwrap(),
            "SELECT NULL"
        );
        let err = substitute_all("SELECT $resp.body", &results, &empty_vars(), &sys_vars())
            .expect_err("a NULL field without `?` must fail loudly");
        assert!(
            err.contains("$resp.body is NULL"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn dot_notation_on_a_non_object_result_still_fails() {
        // A JSON scalar or array is neither a row set nor an envelope.
        for body in [r#"[1,2,3]"#, r#""just a string""#, "42"] {
            let results = make_results(&[("resp", body)]);
            let err = substitute_all("SELECT $resp.body", &results, &empty_vars(), &sys_vars())
                .expect_err("expected dot notation to fail on a non-object result");
            assert!(
                err.contains("neither a row set nor a JSON object"),
                "unexpected error for `{body}`: {err}"
            );
        }
    }

    #[test]
    fn rows_array_still_takes_precedence_over_top_level_fields() {
        // `row_count` exists at the top level, but a row set must resolve
        // against the first row — and report the field as missing there.
        let results = make_results(&[("doc", r#"{"rows":[{"id":7}],"row_count":1}"#)]);
        let err = substitute_all_raw("$doc.row_count", &results, &empty_vars(), &sys_vars())
            .expect_err("row_count must resolve against the row, not the top level");
        assert!(
            err.contains("no field 'row_count'") && err.contains("available: id"),
            "unexpected error: {err}"
        );
        assert_eq!(
            substitute_all_raw("$doc.id", &results, &empty_vars(), &sys_vars()).unwrap(),
            "7"
        );
    }

    #[test]
    fn test_dot_notation_bool() {
        let results = make_results(&[("doc", r#"{"rows":[{"active":true}],"row_count":1}"#)]);
        let out =
            substitute_all("SELECT $doc.active", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT true");
    }

    #[test]
    fn test_bare_name_backward_compat() {
        let results = make_results(&[("x", r#"{"rows":[{"num":100}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $x::text", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT 100::text");
    }

    #[test]
    fn test_no_rows_strict_fail() {
        let results = make_results(&[("doc", r#"{"rows":[],"row_count":0}"#)]);
        let out = substitute_all("SELECT $doc", &results, &empty_vars(), &sys_vars());
        assert!(out.is_err());
        assert!(out.unwrap_err().contains("has no rows"));
    }

    #[test]
    fn test_null_strict_fail() {
        let results = make_results(&[("doc", r#"{"rows":[{"val":null}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $doc", &results, &empty_vars(), &sys_vars());
        assert!(out.is_err());
        assert!(out.unwrap_err().contains("is NULL"));
    }

    #[test]
    fn test_null_safe_no_rows() {
        let results = make_results(&[("doc", r#"{"rows":[],"row_count":0}"#)]);
        let out = substitute_all("SELECT $doc?", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT NULL");
    }

    #[test]
    fn test_null_safe_null_col() {
        let results = make_results(&[("doc", r#"{"rows":[{"name":null}],"row_count":1}"#)]);
        let out =
            substitute_all("SELECT $doc.name?", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT NULL");
    }

    #[test]
    fn test_null_safe_has_value() {
        let results = make_results(&[("x", r#"{"rows":[{"num":42}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $x?", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT 42");
    }

    #[test]
    fn test_dot_notation_missing_col() {
        let results = make_results(&[("doc", r#"{"rows":[{"id":1}],"row_count":1}"#)]);
        let out = substitute_all(
            "SELECT $doc.nonexistent",
            &results,
            &empty_vars(),
            &sys_vars(),
        )
        .unwrap();
        // Missing column is left as-is
        assert_eq!(out, "SELECT $doc.nonexistent");
    }

    #[test]
    fn test_multiple_refs() {
        let results = make_results(&[
            ("a", r#"{"rows":[{"id":1}],"row_count":1}"#),
            ("b", r#"{"rows":[{"name":"Bob"}],"row_count":1}"#),
        ]);
        let out = substitute_all(
            "SELECT $a.id, $b.name",
            &results,
            &empty_vars(),
            &sys_vars(),
        )
        .unwrap();
        assert_eq!(out, "SELECT 1, 'Bob'");
    }

    #[test]
    fn test_substitution_order() {
        // Ensure $doc.id doesn't partially match as $doc first
        let results = make_results(&[("doc", r#"{"rows":[{"id":7,"name":"X"}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $doc.id", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "SELECT 7");
    }

    #[test]
    fn test_row_set_expansion_sql() {
        let results = make_results(&[(
            "batch",
            r#"{"rows":[{"id":1,"val":"a"},{"id":2,"val":"b"}],"row_count":2}"#,
        )]);
        let out = substitute_all(
            "SELECT * FROM $batch.*",
            &results,
            &empty_vars(),
            &sys_vars(),
        )
        .unwrap();
        assert!(out.contains("VALUES"));
        assert!(out.contains(r#"AS "batch"("#));
    }

    #[test]
    fn test_row_set_expansion_empty() {
        let results = make_results(&[("batch", r#"{"rows":[],"row_count":0}"#)]);
        let out = substitute_all(
            "SELECT * FROM $batch.*",
            &results,
            &empty_vars(),
            &sys_vars(),
        )
        .unwrap();
        assert!(out.contains("SELECT NULL WHERE false"));
    }

    #[test]
    fn test_validate_result_name_valid() {
        assert!(validate_result_name("batch").is_ok());
        assert!(validate_result_name("my_result").is_ok());
        assert!(validate_result_name("_private").is_ok());
        assert!(validate_result_name("A123").is_ok());
    }

    #[test]
    fn test_validate_result_name_invalid() {
        assert!(validate_result_name("").is_err());
        assert!(validate_result_name("123abc").is_err());
        assert!(validate_result_name("x) UNION SELECT version()--").is_err());
        assert!(validate_result_name("name with spaces").is_err());
        assert!(validate_result_name("a-b").is_err());
        assert!(validate_result_name("drop;--").is_err());
    }

    #[test]
    fn test_expand_row_set_quoted_columns() {
        // Column names from PostgreSQL can contain special characters
        let json = r#"{"rows":[{"normal":1,"has space":2}],"row_count":1}"#;
        let result = expand_row_set("tbl", json, true).unwrap();
        assert!(result.contains(r#""normal""#));
        assert!(result.contains(r#""has space""#));
        assert!(result.contains(r#"AS "tbl"("#));
    }

    #[test]
    fn test_expand_row_set_empty_quoted_name() {
        let json = r#"{"rows":[],"row_count":0}"#;
        let result = expand_row_set("batch", json, true).unwrap();
        assert_eq!(result, r#"(SELECT NULL WHERE false) AS "batch""#);
    }
    #[test]
    fn test_row_set_expansion_raw() {
        let results = make_results(&[("batch", r#"{"rows":[{"id":1}],"row_count":1}"#)]);
        let out =
            substitute_all_raw("data: $batch.*", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, r#"data: [{"id":1}]"#);
    }

    #[test]
    fn test_no_partial_match_longer_name() {
        // $doc should not match inside $document
        let results = make_results(&[("doc", r#"{"rows":[{"id":1}],"row_count":1}"#)]);
        let out = substitute_all("SELECT $document", &results, &empty_vars(), &sys_vars()).unwrap();
        // $document is not a known result — left as-is
        assert_eq!(out, "SELECT $document");
    }

    #[test]
    fn test_dot_notation_no_sql_quoting() {
        let results = make_results(&[("doc", r#"{"rows":[{"name":"Alice"}],"row_count":1}"#)]);
        let out =
            substitute_all_raw("Hello $doc.name", &results, &empty_vars(), &sys_vars()).unwrap();
        assert_eq!(out, "Hello Alice");
    }

    #[test]
    fn test_validate_recursive_depth_limit() {
        // Build a chain deeper than MAX_GRAPH_DEPTH
        let mut node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        for _ in 0..MAX_GRAPH_DEPTH + 1 {
            node = Durofut {
                node_type: "THEN".to_string(),
                left_node: Some(node.into_raw()),
                right_node: Some(
                    Durofut {
                        node_type: "SQL".to_string(),
                        query: Some("SELECT 1".to_string()),
                        ..Default::default()
                    }
                    .into_raw(),
                ),
                ..Default::default()
            };
        }
        let result = node.validate_recursive();
        assert!(result.is_err(), "should reject graph exceeding depth limit");
        assert!(
            result.unwrap_err().contains("maximum nesting depth"),
            "error should mention depth limit"
        );
    }

    #[test]
    fn test_validate_recursive_within_depth_limit() {
        // Build a chain at exactly the limit — should succeed
        let mut node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        // MAX_GRAPH_DEPTH nestings (the root counts as depth 0)
        for _ in 0..MAX_GRAPH_DEPTH {
            node = Durofut {
                node_type: "THEN".to_string(),
                left_node: Some(node.into_raw()),
                right_node: Some(
                    Durofut {
                        node_type: "SQL".to_string(),
                        query: Some("SELECT 1".to_string()),
                        ..Default::default()
                    }
                    .into_raw(),
                ),
                ..Default::default()
            };
        }
        let result = node.validate_recursive();
        assert!(result.is_ok(), "should accept graph within depth limit");
    }

    /// Build a wide JOIN node with `n` extra children for testing node-count limits.
    /// Serializes the template node once and clones, keeping memory predictable.
    fn build_wide_join(n: usize) -> Durofut {
        let sql_node = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        };
        let extra_node = sql_node.clone().into_raw();

        Durofut {
            node_type: "JOIN".to_string(),
            left_node: Some(sql_node.clone().into_raw()),
            right_node: Some(sql_node.into_raw()),
            extra_nodes: vec![extra_node; n],
            ..Default::default()
        }
    }

    #[test]
    fn test_flatten_graph_preserves_condition_nodes_query_format() {
        for node_type in ["IF", "LOOP"] {
            let condition = Durofut {
                node_type: "SQL".to_string(),
                query: Some("SELECT true".to_string()),
                ..Default::default()
            };
            let node = Durofut {
                node_type: node_type.to_string(),
                condition_node: Some(condition.into_raw()),
                ..Default::default()
            };

            let mut ids = ["root", "condition-id"].into_iter().map(str::to_string);
            let (root_id, nodes) = flatten_graph(&node, &mut || Ok(ids.next().unwrap())).unwrap();
            assert_eq!(nodes[0].id, root_id);
            assert_eq!(nodes[1].id, "condition-id");
            assert_eq!(
                nodes[0].query.as_deref(),
                Some(r#"{"condition_node":"condition-id"}"#)
            );
        }
    }

    #[test]
    fn test_flatten_graph_preserves_existing_query() {
        let condition = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT true".to_string()),
            ..Default::default()
        };
        let node = Durofut {
            node_type: "IF".to_string(),
            condition_node: Some(condition.into_raw()),
            query: Some(r#"{"a":1}"#.to_string()),
            ..Default::default()
        };

        let mut ids = ["root", "condition-id"].into_iter().map(str::to_string);
        let (_, nodes) = flatten_graph(&node, &mut || Ok(ids.next().unwrap())).unwrap();
        assert_eq!(
            nodes[0].query.as_deref(),
            Some(r#"{"a":1,"condition_node":"condition-id"}"#)
        );
    }

    #[test]
    fn test_flatten_graph_preserves_extra_nodes_query_format() {
        let extra = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 3".to_string()),
            ..Default::default()
        };
        let node = Durofut {
            node_type: "JOIN".to_string(),
            extra_nodes: vec![extra.into_raw()],
            ..Default::default()
        };

        let mut ids = ["root", "extra-id"].into_iter().map(str::to_string);
        let (_, nodes) = flatten_graph(&node, &mut || Ok(ids.next().unwrap())).unwrap();
        assert_eq!(nodes[1].id, "extra-id");
        assert_eq!(
            nodes[0].query.as_deref(),
            Some(r#"{"extra_nodes":["extra-id"]}"#)
        );
    }

    #[test]
    fn test_rejects_config_children_embedded_in_query() {
        let legacy_if = Durofut {
            node_type: "IF".to_string(),
            query: Some(
                r#"{"condition_node":{"node_type":"SQL","query":"SELECT true"}}"#.to_string(),
            ),
            ..Default::default()
        };
        let legacy_join = Durofut {
            node_type: "JOIN".to_string(),
            query: Some(r#"{"extra_nodes":[{"node_type":"SQL","query":"SELECT 3"}]}"#.to_string()),
            ..Default::default()
        };

        let legacy_loop = Durofut {
            node_type: "LOOP".to_string(),
            query: Some(
                r#"{"condition_node":{"node_type":"SQL","query":"SELECT true"}}"#.to_string(),
            ),
            ..Default::default()
        };

        assert!(legacy_if
            .validate_recursive()
            .unwrap_err()
            .contains("condition_node in IF must be a first-class Durofut field"));
        assert!(legacy_loop
            .validate_recursive()
            .unwrap_err()
            .contains("condition_node in LOOP must be a first-class Durofut field"));
        let mut ids = || Ok("unused".to_string());
        assert!(flatten_graph(&legacy_join, &mut ids)
            .unwrap_err()
            .to_string()
            .contains("extra_nodes in JOIN must be a first-class Durofut field"));
    }

    #[test]
    fn test_config_children_require_json_object_query() {
        let condition = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT true".to_string()),
            ..Default::default()
        }
        .into_raw();
        for query in ["SELECT 1", "42"] {
            let node = Durofut {
                node_type: "IF".to_string(),
                condition_node: Some(condition.clone()),
                query: Some(query.to_string()),
                ..Default::default()
            };

            assert!(node
                .validate_recursive()
                .unwrap_err()
                .contains("query in IF must be"));
        }
    }

    #[test]
    fn test_config_children_reject_fields_on_wrong_node_types() {
        let child = Durofut {
            node_type: "SQL".to_string(),
            query: Some("SELECT 1".to_string()),
            ..Default::default()
        }
        .into_raw();
        let sql_with_condition = Durofut {
            node_type: "SQL".to_string(),
            condition_node: Some(child.clone()),
            ..Default::default()
        };
        let race_with_extras = Durofut {
            node_type: "RACE".to_string(),
            extra_nodes: vec![child],
            ..Default::default()
        };

        assert!(sql_with_condition
            .validate_recursive()
            .unwrap_err()
            .contains("condition_node is not valid for SQL nodes"));
        assert!(race_with_extras
            .validate_recursive()
            .unwrap_err()
            .contains("extra_nodes is not valid for RACE nodes"));
    }

    #[test]
    fn test_extra_nodes_deserialization_rejects_invalid_shapes() {
        for json in [
            r#"{"node_type":"JOIN","extra_nodes":["a1b2c3d4"]}"#,
            r#"{"node_type":"JOIN","extra_nodes":[42]}"#,
        ] {
            let error = Durofut::try_from_json(json).unwrap_err();
            assert!(
                error.contains("extra_nodes entries must be Durofut JSON objects"),
                "should identify the invalid extra_nodes entry: {error}"
            );
        }

        let non_array = r#"{"node_type":"JOIN","extra_nodes":{"node_type":"SQL"}}"#;
        assert!(
            Durofut::try_from_json(non_array).is_err(),
            "should reject non-array extra_nodes"
        );
    }

    #[test]
    fn test_flatten_graph_reports_invalid_child_path() {
        let invalid = Durofut {
            node_type: "NOT_A_NODE".to_string(),
            ..Default::default()
        };
        let root = Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(
                Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                }
                .into_raw(),
            ),
            right_node: Some(invalid.into_raw()),
            ..Default::default()
        };
        let mut counter = 0;
        let error = flatten_graph(&root, &mut || {
            counter += 1;
            Ok(format!("N{counter}"))
        })
        .unwrap_err();

        assert_eq!(error.path, "root.right");
        assert!(error.message.contains("Unknown node_type 'NOT_A_NODE'"));
    }

    #[test]
    fn test_flatten_graph_assigns_unique_preorder_ids_and_forward_references() {
        let root = Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(
                Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                }
                .into_raw(),
            ),
            right_node: Some(
                Durofut {
                    node_type: "THEN".to_string(),
                    left_node: Some(
                        Durofut {
                            node_type: "SQL".to_string(),
                            query: Some("SELECT 2".to_string()),
                            ..Default::default()
                        }
                        .into_raw(),
                    ),
                    right_node: Some(
                        Durofut {
                            node_type: "SQL".to_string(),
                            query: Some("SELECT 3".to_string()),
                            ..Default::default()
                        }
                        .into_raw(),
                    ),
                    ..Default::default()
                }
                .into_raw(),
            ),
            ..Default::default()
        };
        let mut counter = 0;
        let (root_id, nodes) = flatten_graph(&root, &mut || {
            counter += 1;
            Ok(format!("{counter:08x}"))
        })
        .unwrap();

        assert_eq!(nodes[0].id, root_id);
        assert_eq!(
            nodes
                .iter()
                .map(|node| node.node_type.as_str())
                .collect::<Vec<_>>(),
            ["THEN", "SQL", "THEN", "SQL", "SQL"]
        );
        let positions = nodes
            .iter()
            .enumerate()
            .map(|(index, node)| (node.id.as_str(), index))
            .collect::<std::collections::HashMap<_, _>>();
        assert_eq!(positions.len(), nodes.len());
        for (index, node) in nodes.iter().enumerate() {
            for child_id in [node.left_node.as_deref(), node.right_node.as_deref()]
                .into_iter()
                .flatten()
            {
                assert!(positions[child_id] > index);
            }
        }
    }

    #[test]
    fn test_validate_recursive_node_count_limit() {
        // Build a shallow-but-wide graph: a JOIN with many extra_nodes.
        // This stays at depth 1 but exceeds MAX_GRAPH_NODES.
        let join_node = build_wide_join(MAX_GRAPH_NODES);

        let result = join_node.validate_recursive();
        assert!(result.is_err(), "should reject graph exceeding node count");
        assert!(
            result.unwrap_err().contains("maximum node count"),
            "error should mention node count limit"
        );
    }

    #[test]
    fn test_flatten_graph_bounds_id_generation_for_oversized_join() {
        let join_node = build_wide_join(MAX_GRAPH_NODES);
        let mut id_calls = 0;

        let result = flatten_graph(&join_node, &mut || {
            id_calls += 1;
            Ok(format!("{id_calls:08x}"))
        });

        assert!(result.is_err());
        assert_eq!(id_calls, MAX_GRAPH_NODES);
        assert_eq!(result.unwrap_err().path, "root.extra_nodes[9997]");
    }

    #[test]
    fn test_flatten_graph_reports_id_source_failure_at_child_path() {
        let root = Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(
                Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                }
                .into_raw(),
            ),
            right_node: Some(
                Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 2".to_string()),
                    ..Default::default()
                }
                .into_raw(),
            ),
            ..Default::default()
        };
        let mut calls = 0;
        let result = flatten_graph(&root, &mut || {
            calls += 1;
            if calls == 2 {
                Err("ID source exhausted".to_string())
            } else {
                Ok(format!("{calls:08x}"))
            }
        });

        assert_eq!(
            result.unwrap_err(),
            GraphError {
                path: "root.left".to_string(),
                message: "ID source exhausted".to_string(),
            }
        );
    }

    #[test]
    fn test_validate_recursive_node_count_within_limit() {
        // Root + left + right + extra nodes totals exactly MAX_GRAPH_NODES.
        let join_node = build_wide_join(MAX_GRAPH_NODES - 3);

        let result = join_node.validate_recursive();
        assert!(
            result.is_ok(),
            "should accept graph exactly at node count limit"
        );
    }

    #[test]
    fn test_row_set_expansion_rejects_oversized_result() {
        // Build a JSON result with more than 10,000 rows
        let mut rows = Vec::new();
        for i in 0..10_001 {
            rows.push(serde_json::json!({"id": i}));
        }
        let json_str = serde_json::json!({"rows": rows, "row_count": 10_001}).to_string();
        let results = make_results(&[("big", &json_str)]);

        let result = substitute_all("SELECT * FROM $big.*", &results, &empty_vars(), &sys_vars());
        assert!(
            result.is_err(),
            "Should reject row-set expansion > 10,000 rows"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("exceeding the maximum"),
            "Error should mention the limit, got: {err}"
        );
    }

    #[test]
    fn test_row_set_expansion_accepts_within_limit() {
        // Build a JSON result with exactly 100 rows (well within limit)
        let mut rows = Vec::new();
        for i in 0..100 {
            rows.push(serde_json::json!({"id": i, "name": format!("item_{i}")}));
        }
        let json_str = serde_json::json!({"rows": rows, "row_count": 100}).to_string();
        let results = make_results(&[("batch", &json_str)]);

        let result = substitute_all(
            "SELECT * FROM $batch.*",
            &results,
            &empty_vars(),
            &sys_vars(),
        );
        assert!(
            result.is_ok(),
            "Should accept row-set expansion within limit"
        );
        let sql = result.unwrap();
        assert!(sql.contains("VALUES"), "Should produce VALUES clause");
    }
}
