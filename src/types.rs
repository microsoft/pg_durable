// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Core types and configuration for pg_durable

use pgrx::{pg_extern, Spi};

use chrono::{DateTime, Utc};
use cron::Schedule as CronSchedule;
use serde::{Deserialize, Serialize};
use std::borrow::Cow;
use std::ffi::CString;
use std::str::FromStr;
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use uuid::Uuid;

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

/// Get the execution acquire timeout as a Duration.
pub fn get_execution_acquire_timeout() -> Duration {
    Duration::from_secs(crate::EXECUTION_ACQUIRE_TIMEOUT.get() as u64)
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
pub async fn is_role_superuser_name(pool: &sqlx::PgPool, role_name: &str) -> Result<bool, String> {
    sqlx::query_scalar::<_, bool>("SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = $1")
        .bind(role_name)
        .fetch_optional(pool)
        .await
        .map_err(|e| format!("superuser check failed for role '{}': {}", role_name, e))
        .and_then(|opt| opt.ok_or_else(|| format!("role '{}' not found in pg_roles", role_name)))
}

/// Maximum nesting depth for workflow graphs. Prevents stack overflow from
/// deeply nested operator chains (e.g., 10,000 levels of `~>`).
pub const MAX_GRAPH_DEPTH: usize = 256;

/// Maximum number of nodes allowed in a single workflow instance. Prevents
/// unbounded INSERTs and memory exhaustion from extremely large graphs.
pub const MAX_GRAPH_NODES: usize = 10_000;

/// Generate a short 8-character instance ID from a UUID
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
    let host = std::env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = unsafe { pgrx::pg_sys::PostPortNumber };
    let user = get_worker_role();
    let database = get_database();

    format!("postgres://{user}@{host}:{port}/{database}")
}

/// Get the PostgreSQL host for connections
pub fn get_host() -> String {
    std::env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".to_string())
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

fn normalize_role_name_for_connection(user: &str) -> Result<Cow<'_, str>, String> {
    if !user.starts_with('"') {
        if user.ends_with('"') {
            return Err(format!(
                "Invalid role name '{}': unexpected trailing double quote in connection username",
                user
            ));
        }
        return Ok(Cow::Borrowed(user));
    }

    if !user.ends_with('"') || user.len() < 2 {
        return Err(format!(
            "Invalid role name '{}': unterminated quoted identifier in connection username",
            user
        ));
    }

    let inner = &user[1..user.len() - 1];
    let mut normalized = String::with_capacity(inner.len());
    let mut chars = inner.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch != '"' {
            normalized.push(ch);
            continue;
        }

        if chars.peek() == Some(&'"') {
            normalized.push('"');
            chars.next();
            continue;
        }

        return Err(format!(
            "Invalid quoted role name '{}': expected doubled double quotes inside identifier",
            user
        ));
    }

    Ok(Cow::Owned(normalized))
}

/// Create a single PostgreSQL connection authenticated as `user`.
pub async fn connect_as_user(
    user: &str,
    database: Option<&str>,
) -> Result<sqlx::postgres::PgConnection, String> {
    use sqlx::postgres::PgConnectOptions;
    use sqlx::Connection;

    /// Connection timeout for per-user SQL connections (seconds).
    const CONNECT_TIMEOUT_SECS: u64 = 30;

    let normalized_user = normalize_role_name_for_connection(user)?;
    let default_db = target_database();
    let db = database.unwrap_or(&default_db);
    let mut options = PgConnectOptions::new()
        .username(normalized_user.as_ref())
        .database(db)
        .port(get_port());

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
                db,
                normalized_user.as_ref(),
                CONNECT_TIMEOUT_SECS
            )
        })?
        .map_err(|e| {
            format!(
                "Failed to connect to database '{}' as '{}'. Error: {}",
                db,
                normalized_user.as_ref(),
                e
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
    let mut config = duroxide_pg::ProviderConfig::url(database_url);
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
    let mut config = duroxide_pg::ProviderConfig::url(database_url);
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

/// Extract a specific column from the first row (`$name.col` / `$name.col?`).
/// Returns the original pattern when the column does not exist in the result.
fn extract_column_value(
    name: &str,
    json_str: &str,
    col: &str,
    null_safe: bool,
    for_sql: bool,
) -> Result<String, String> {
    let json: serde_json::Value = serde_json::from_str(json_str)
        .map_err(|_| format!("${name}.{col}: result is not valid JSON"))?;

    let rows = json
        .get("rows")
        .and_then(|r| r.as_array())
        .ok_or_else(|| format!("${name}.{col}: result has no rows array"))?;

    if rows.is_empty() {
        return if null_safe {
            Ok("NULL".to_string())
        } else {
            Err(format!("${name} has no rows — query returned zero results"))
        };
    }

    let first_row = rows[0]
        .as_object()
        .ok_or_else(|| format!("${name}.{col}: first row is not an object"))?;

    let val = match first_row.get(col) {
        Some(v) => v,
        None => {
            // Missing column — leave the pattern as-is so PostgreSQL reports the error
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
    let mut result = query.to_string();

    // 1. Substitute system vars: {sys_*} (inserted as-is)
    result = result.replace("{sys_instance_id}", &sys_vars.instance_id);
    result = result.replace("{sys_label}", sys_vars.label.as_deref().unwrap_or(""));

    // SECURITY: Raw substitution of user vars is by design — variables are
    // intended for SQL fragments (table names, expressions), not just values.
    // The user controls both the variable content and the query template, and
    // SQL executes under their own role via connect_as_user().
    // See docs/spec-security-model.md §4.3, T10.
    // 2. Substitute user vars: {name} (inserted as-is, no quoting)
    for (name, value) in vars {
        let pattern = format!("{{{name}}}");
        if result.contains(&pattern) {
            result = result.replace(&pattern, value);
        }
    }

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

/// Represents the entire function graph for an instance
/// Note: Uses BTreeMap for deterministic serialization order (required for Duroxide replay)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionGraph {
    pub instance_id: String,
    pub root_node_id: String,
    pub nodes: std::collections::BTreeMap<String, FunctionNode>,
}

/// Input structure passed to duroxide functions
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionInput {
    pub instance_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub vars: std::collections::HashMap<String, String>,
    /// Loop iteration counter, incremented on each `continue_as_new`.
    /// Used to enforce a maximum iteration safeguard.
    #[serde(default)]
    pub loop_iteration: u64,
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
    "SIGNAL",
];
const NON_FUTURE_HELPER_GUC: &str = "df.non_future_helper";

pub fn mark_non_future_helper_call(function_name: &str) {
    if let Err(e) = Spi::run_with_args(
        "SELECT pg_catalog.set_config('df.non_future_helper', $1 || E'\n' || pg_catalog.statement_timestamp()::text, true)",
        &[function_name.into()],
    ) {
        pgrx::error!("Failed to mark helper call: {:?}", e);
    }
}

/// The Durofut type represents a "durable future" - a reference to a node in the function graph.
/// Children are embedded as nested structures, not stored as ID references.
/// Node IDs are generated during insertion into df.nodes, not during graph construction.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Durofut {
    pub node_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub left_node: Option<Box<Durofut>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right_node: Option<Box<Durofut>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_name: Option<String>,
}

impl Durofut {
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

        let marker = Spi::get_one::<String>(&format!(
            "SELECT pg_catalog.current_setting('{}', true)",
            NON_FUTURE_HELPER_GUC
        ))
        .ok()
        .flatten()?;
        let (helper_name, marker_timestamp) = marker.split_once('\n')?;
        let statement_timestamp =
            Spi::get_one::<String>("SELECT pg_catalog.statement_timestamp()::text")
                .ok()
                .flatten()?;

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

    /// Ensure a string is a Durofut - if it's already one, parse it; if not, treat as SQL and create a node.
    /// Uses a single deserialization attempt to avoid redundant parsing.
    pub fn ensure(s: &str) -> Self {
        if let Some(helper_name) = Self::same_statement_non_future_helper_name(s) {
            pgrx::error!("{}", Self::non_future_helper_error(&helper_name));
        }
        match serde_json::from_str::<Durofut>(s) {
            Ok(d) if VALID_NODE_TYPES.contains(&d.node_type.as_str()) => d,
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
    /// Used during insertion in df.start() to catch invalid nested nodes.
    /// Also enforces MAX_GRAPH_NODES so oversized graphs fail fast without
    /// needing a second traversal during insertion.
    pub fn validate_recursive(&self) -> Result<(), String> {
        let mut node_count = 0;
        self.validate_recursive_inner(0, &mut node_count)
    }

    fn validate_recursive_inner(&self, depth: usize, node_count: &mut usize) -> Result<(), String> {
        *node_count += 1;
        if *node_count > MAX_GRAPH_NODES {
            return Err(format!(
                "Workflow exceeds maximum node count of {}. \
                 Simplify the workflow or break it into multiple instances.",
                MAX_GRAPH_NODES
            ));
        }
        if depth > MAX_GRAPH_DEPTH {
            return Err(format!(
                "Graph exceeds maximum nesting depth of {}. \
                 Simplify the workflow or break it into multiple instances.",
                MAX_GRAPH_DEPTH
            ));
        }
        if !VALID_NODE_TYPES.contains(&self.node_type.as_str()) {
            return Err(format!(
                "Unknown node_type '{}'. Valid types: {}",
                self.node_type,
                VALID_NODE_TYPES.join(", ")
            ));
        }
        if let Some(ref left) = self.left_node {
            left.validate_recursive_inner(depth + 1, node_count)?;
        }
        if let Some(ref right) = self.right_node {
            right.validate_recursive_inner(depth + 1, node_count)?;
        }
        // Validate config-embedded nodes (condition_node, extra_nodes)
        let d = depth + 1;
        self.for_each_config_child(|child| child.validate_recursive_inner(d, node_count))?;
        Ok(())
    }

    /// Extract config-embedded Durofut children from the `query` JSON field and apply
    /// a callback to each. This is the single source of truth for walking `condition_node`
    /// (in IF/LOOP nodes) and `extra_nodes` (in JOIN nodes).
    ///
    /// The callback receives each embedded child and returns `Result<(), String>`.
    /// Parsing failures are always treated as errors — a `condition_node` or `extra_nodes`
    /// entry that cannot be deserialized as a valid Durofut is rejected.
    pub fn for_each_config_child<F>(&self, mut f: F) -> Result<(), String>
    where
        F: FnMut(&Durofut) -> Result<(), String>,
    {
        let query_str = match self.query.as_ref() {
            Some(s) => s,
            None => return Ok(()),
        };
        let config = match serde_json::from_str::<serde_json::Value>(query_str) {
            Ok(c) => c,
            Err(_) => return Ok(()), // not JSON config, nothing to walk
        };

        // IF/LOOP nodes: condition_node
        if self.node_type == "IF" || self.node_type == "LOOP" {
            if let Some(cond) = config.get("condition_node") {
                let cond_node = serde_json::from_value::<Durofut>(cond.clone()).map_err(|e| {
                    format!(
                        "condition_node in {} must be a valid Durofut object, got {}: {}",
                        self.node_type,
                        summarize_json_type(cond),
                        e
                    )
                })?;
                f(&cond_node)?;
            }
        }

        // JOIN nodes: extra_nodes array
        if self.node_type == "JOIN" {
            if let Some(extras) = config.get("extra_nodes").and_then(|e| e.as_array()) {
                for (i, extra) in extras.iter().enumerate() {
                    let extra_node =
                        serde_json::from_value::<Durofut>(extra.clone()).map_err(|e| {
                            format!(
                                "extra_nodes[{}] in {} must be a valid Durofut object: {}",
                                i, self.node_type, e
                            )
                        })?;
                    f(&extra_node)?;
                }
            }
        }

        Ok(())
    }

    /// Transform config-embedded Durofut children into string IDs via a callback,
    /// returning the updated query JSON string. Used by `insert_nodes` and `collect_nodes`
    /// to replace nested Durofut objects with generated node IDs.
    ///
    /// The callback receives each embedded child and returns the generated ID string.
    /// Parsing failures are always treated as errors.
    pub fn transform_config_children<F>(&self, mut f: F) -> Result<Option<String>, String>
    where
        F: FnMut(&Durofut) -> Result<String, String>,
    {
        let query_str = match self.query.as_ref() {
            Some(s) => s,
            None => return Ok(None),
        };
        let mut config = match serde_json::from_str::<serde_json::Value>(query_str) {
            Ok(c) => c,
            Err(_) => return Ok(Some(query_str.clone())), // not JSON, pass through as-is
        };

        // IF/LOOP nodes: condition_node
        if self.node_type == "IF" || self.node_type == "LOOP" {
            if let Some(cond) = config.get("condition_node") {
                let cond_node = serde_json::from_value::<Durofut>(cond.clone()).map_err(|e| {
                    format!(
                        "condition_node in {} must be a valid Durofut object, got {}: {}",
                        self.node_type,
                        summarize_json_type(cond),
                        e
                    )
                })?;
                let cond_id = f(&cond_node)?;
                config["condition_node"] = serde_json::json!(cond_id);
            }
        }

        // JOIN nodes: extra_nodes array
        if self.node_type == "JOIN" {
            if let Some(extras) = config.get("extra_nodes").and_then(|e| e.as_array()) {
                let mut extra_ids: Vec<String> = Vec::new();
                for (i, extra) in extras.iter().enumerate() {
                    let extra_node =
                        serde_json::from_value::<Durofut>(extra.clone()).map_err(|e| {
                            format!(
                                "extra_nodes[{}] in {} must be a valid Durofut object: {}",
                                i, self.node_type, e
                            )
                        })?;
                    extra_ids.push(f(&extra_node)?);
                }
                if !extra_ids.is_empty() {
                    config["extra_nodes"] = serde_json::json!(extra_ids);
                }
            }
        }

        Ok(Some(serde_json::to_string(&config).unwrap()))
    }
}

/// Helper to describe a JSON value type for error messages
fn summarize_json_type(v: &serde_json::Value) -> &'static str {
    match v {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "a boolean",
        serde_json::Value::Number(_) => "a number",
        serde_json::Value::String(_) => "a string",
        serde_json::Value::Array(_) => "an array",
        serde_json::Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    fn normalize_role_name_keeps_raw_rolname() {
        let normalized = normalize_role_name_for_connection("plain_role").unwrap();
        assert_eq!(normalized.as_ref(), "plain_role");
    }

    #[test]
    fn normalize_role_name_keeps_mixed_case_rolname() {
        let normalized = normalize_role_name_for_connection("labUser").unwrap();
        assert_eq!(normalized.as_ref(), "labUser");
    }

    #[test]
    fn normalize_role_name_unquotes_regrole_text_output() {
        let normalized = normalize_role_name_for_connection("\"Role Name\"").unwrap();
        assert_eq!(normalized.as_ref(), "Role Name");
    }

    #[test]
    fn normalize_role_name_unescapes_embedded_quotes() {
        let normalized = normalize_role_name_for_connection("\"Role \"\"Name\"\"\"").unwrap();
        assert_eq!(normalized.as_ref(), "Role \"Name\"");
    }

    #[test]
    fn normalize_role_name_rejects_malformed_quoted_identifier() {
        let err = normalize_role_name_for_connection("\"bad\"name\"").unwrap_err();
        assert!(err.contains("Invalid quoted role name"));
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

    fn sys_vars() -> SystemVars {
        SystemVars {
            instance_id: "test-id".to_string(),
            label: None,
        }
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
                left_node: Some(Box::new(node)),
                right_node: Some(Box::new(Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                })),
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
        // MAX_GRAPH_DEPTH - 1 nestings (the root counts as depth 0)
        for _ in 0..MAX_GRAPH_DEPTH - 1 {
            node = Durofut {
                node_type: "THEN".to_string(),
                left_node: Some(Box::new(node)),
                right_node: Some(Box::new(Durofut {
                    node_type: "SQL".to_string(),
                    query: Some("SELECT 1".to_string()),
                    ..Default::default()
                })),
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
        let sql_value = serde_json::to_value(&sql_node).unwrap();
        let extra_nodes: Vec<serde_json::Value> = vec![sql_value; n];
        let config = serde_json::json!({ "extra_nodes": extra_nodes });

        Durofut {
            node_type: "JOIN".to_string(),
            left_node: Some(Box::new(sql_node.clone())),
            right_node: Some(Box::new(sql_node)),
            query: Some(config.to_string()),
            ..Default::default()
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
    fn test_validate_recursive_node_count_within_limit() {
        // A graph with a moderate number of nodes should pass
        let join_node = build_wide_join(50);

        let result = join_node.validate_recursive();
        assert!(
            result.is_ok(),
            "should accept graph within node count limit"
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
