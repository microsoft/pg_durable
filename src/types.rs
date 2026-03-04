//! Core types and configuration for pg_durable

use chrono::{DateTime, Utc};
use cron::Schedule as CronSchedule;
use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::str::FromStr;
use std::time::Duration;
use uuid::Uuid;

// ============================================================================
// Configuration Functions
// ============================================================================

/// Get the worker role from the `pg_durable.worker_role` GUC.
/// Falls back to `"azuresu"` if the GUC is not set.
pub fn get_worker_role() -> String {
    crate::WORKER_ROLE
        .get()
        .map(|cs: CString| cs.to_string_lossy().into_owned())
        .unwrap_or_else(|| "azuresu".to_string())
}

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
    let database = std::env::var("POSTGRES_DB")
        .or_else(|_| std::env::var("PGDATABASE"))
        .unwrap_or_else(|_| "postgres".to_string());

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
    std::env::var("POSTGRES_DB")
        .or_else(|_| std::env::var("PGDATABASE"))
        .unwrap_or_else(|_| "postgres".to_string())
}

/// Create a single PostgreSQL connection authenticated as `login_role`,
/// then SET ROLE to `effective_role`.
pub async fn connect_as_user(
    login_role: &str,
    effective_role: &str,
) -> Result<sqlx::postgres::PgConnection, String> {
    use sqlx::postgres::PgConnectOptions;
    use sqlx::Connection;

    let mut options = PgConnectOptions::new()
        .username(login_role)
        .database(&target_database())
        .port(get_port());

    let host = get_host();
    if !host.is_empty() {
        options = options.host(&host);
    }

    let mut conn = sqlx::postgres::PgConnection::connect_with(&options)
        .await
        .map_err(|e| {
            format!(
                "Failed to connect as '{}' (for effective role '{}'). Error: {}",
                login_role, effective_role, e
            )
        })?;

    // Switch to effective role if different from login role
    if login_role != effective_role {
        sqlx::query(&format!(
            "SET ROLE \"{}\"",
            effective_role.replace('"', "\"\"")
        ))
        .execute(&mut conn)
        .await
        .map_err(|e| format!("SET ROLE {} failed: {}", effective_role, e))?;
    }

    // Prevent recursive df.start() calls
    sqlx::query("SET df.in_workflow = 'true'")
        .execute(&mut conn)
        .await
        .map_err(|e| format!("SET df.in_workflow failed: {}", e))?;

    Ok(conn)
}

/// Schema name for Duroxide internal tables
pub const DUROXIDE_SCHEMA: &str = "duroxide";

/// Create a `ProviderConfig` for backend (request/response) operations.
///
/// - `VerifyOnly`: never create schema/tables, reject unknown migrations
/// - `long_poll` disabled: avoid a dedicated listener connection per backend session
pub fn backend_provider_config() -> duroxide_pg_opt::ProviderConfig {
    let mut config = duroxide_pg_opt::ProviderConfig::default();
    config.schema_name = Some(DUROXIDE_SCHEMA.to_string());
    config.migration_policy = duroxide_pg_opt::MigrationPolicy::VerifyOnly;
    config.long_poll.enabled = false;
    config
}

/// Create a `ProviderConfig` for the background worker runtime.
///
/// - `VerifyOnly`: never create schema/tables, reject unknown migrations
/// - Long-polling intentionally left enabled (default) for the BGW runtime,
///   unlike backend sessions where it's disabled to save resources.
pub fn worker_provider_config() -> duroxide_pg_opt::ProviderConfig {
    let mut config = duroxide_pg_opt::ProviderConfig::default();
    config.schema_name = Some(DUROXIDE_SCHEMA.to_string());
    config.migration_policy = duroxide_pg_opt::MigrationPolicy::VerifyOnly;
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

/// Evaluate a condition result to determine if it's truthy
pub fn evaluate_condition(result: &str) -> Result<bool, String> {
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(result) {
        if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
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

    let lower = result.to_lowercase().trim().to_string();
    Ok(matches!(lower.as_str(), "true" | "t" | "yes" | "1")
        || lower.parse::<i64>().map(|n| n != 0).unwrap_or(false))
}

pub fn is_truthy(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::Number(n) => {
            n.as_i64().map(|i| i != 0).unwrap_or(false)
                || n.as_f64().map(|f| f != 0.0).unwrap_or(false)
        }
        serde_json::Value::String(s) => {
            let lower = s.to_lowercase();
            matches!(lower.as_str(), "true" | "t" | "yes" | "1")
                || s.parse::<i64>().map(|n| n != 0).unwrap_or(!s.is_empty())
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

/// Substitute all variable types in a query:
/// - {name} for user vars (from FunctionInput.vars) - values are inserted as-is
/// - {sys_instance_id}, {sys_label} for system vars - inserted as-is
/// - $name for result naming (from |=>) - may be quoted for JSON values
///
/// User vars and system vars are substituted without quoting - the user should
/// handle SQL escaping in the original query if needed.
pub fn substitute_all_with_options(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
    quote_results_for_sql: bool,
) -> String {
    let mut result = query.to_string();

    // 1. Substitute system vars: {sys_*} (inserted as-is)
    result = result.replace("{sys_instance_id}", &sys_vars.instance_id);
    result = result.replace("{sys_label}", sys_vars.label.as_deref().unwrap_or(""));

    // 2. Substitute user vars: {name} (inserted as-is, no quoting)
    for (name, value) in vars {
        let pattern = format!("{{{name}}}");
        if result.contains(&pattern) {
            result = result.replace(&pattern, value);
        }
    }

    // 3. Substitute results: $name
    for (name, value) in results {
        let pattern = format!("${name}");
        if result.contains(&pattern) {
            let replacement = if let Ok(json) = serde_json::from_str::<serde_json::Value>(value) {
                // Check if this is a SQL result format with rows
                if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
                    if let Some(first_row) = rows.first() {
                        if let Some(obj) = first_row.as_object() {
                            if let Some((_, val)) = obj.iter().next() {
                                match val {
                                    serde_json::Value::String(s) => {
                                        if quote_results_for_sql {
                                            let escaped = s.replace('\'', "''");
                                            format!("'{escaped}'")
                                        } else {
                                            s.clone()
                                        }
                                    }
                                    serde_json::Value::Number(n) => n.to_string(),
                                    serde_json::Value::Bool(b) => b.to_string(),
                                    _ => val.to_string(),
                                }
                            } else {
                                value.clone()
                            }
                        } else {
                            value.clone()
                        }
                    } else {
                        value.clone()
                    }
                } else if quote_results_for_sql {
                    // This is a JSON object/array (like HTTP response) - quote it for SQL
                    // so it can be cast to jsonb: '{"key": "value"}'::jsonb
                    let escaped = value.replace('\'', "''");
                    format!("'{escaped}'")
                } else {
                    // Raw mode - no quoting for non-SQL contexts
                    value.clone()
                }
            } else {
                value.clone()
            };
            result = result.replace(&pattern, &replacement);
        }
    }

    result
}

/// Substitute all variables with SQL quoting (default for SQL contexts)
pub fn substitute_all(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
) -> String {
    substitute_all_with_options(query, results, vars, sys_vars, true)
}

/// Substitute all variables without SQL quoting (for URLs, headers, etc.)
pub fn substitute_all_raw(
    query: &str,
    results: &std::collections::HashMap<String, String>,
    vars: &std::collections::HashMap<String, String>,
    sys_vars: &SystemVars,
) -> String {
    substitute_all_with_options(query, results, vars, sys_vars, false)
}

/// Legacy function for backward compatibility - only substitutes $name results
pub fn substitute_variables(
    query: &str,
    results: &std::collections::HashMap<String, String>,
) -> String {
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
    /// Effective role (outer user) for privilege isolation
    pub submitted_by: String,
    /// Authenticated role (session user) for connection authentication
    pub login_role: String,
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
}

fn default_http_timeout() -> u64 {
    30
}

// ============================================================================
// Durofut Type - Represents a function node reference
// ============================================================================

/// The Durofut type represents a "durable future" - a reference to a node in the function graph.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Durofut {
    pub node_id: String,
    pub node_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub left_node: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right_node: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_name: Option<String>,
}

impl Durofut {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("failed to serialize Durofut")
    }

    pub fn from_json(s: &str) -> Self {
        serde_json::from_str(s).expect("failed to deserialize Durofut")
    }

    /// Check if a string is a valid Durofut JSON
    /// Returns true if it's valid JSON with a node_id field that looks like our format
    pub fn is_durofut(s: &str) -> bool {
        if let Ok(fut) = serde_json::from_str::<Durofut>(s) {
            // Check if node_id is 8 hex characters (our format)
            fut.node_id.len() == 8 && fut.node_id.chars().all(|c| c.is_ascii_hexdigit())
        } else {
            false
        }
    }

    /// Ensure a string is a Durofut - if it's already one, parse it; if not, treat as SQL and create a node
    pub fn ensure(s: &str) -> Self {
        if Self::is_durofut(s) {
            Self::from_json(s)
        } else {
            // It's a plain SQL string - create a SQL node for it
            let fut = Durofut {
                node_id: short_id(),
                node_type: "SQL".to_string(),
                left_node: None,
                right_node: None,
                query: Some(s.to_string()),
                result_name: None,
            };
            fut.insert_node();
            fut
        }
    }

    /// Insert this node into the appropriate table (df.nodes or temp table in explain mode)
    pub fn insert_node(&self) {
        let query_escaped = self
            .query
            .as_ref()
            .map(|q| q.replace('\'', "''"))
            .map(|q| format!("'{q}'"))
            .unwrap_or_else(|| "NULL".to_string());

        let result_name_escaped = self
            .result_name
            .as_ref()
            .map(|n| format!("'{}'", n.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());

        let left_node = self
            .left_node
            .as_ref()
            .map(|id| format!("'{id}'"))
            .unwrap_or_else(|| "NULL".to_string());

        let right_node = self
            .right_node
            .as_ref()
            .map(|id| format!("'{id}'"))
            .unwrap_or_else(|| "NULL".to_string());

        // Check if we're in explain mode - use temp table if so
        let target_table = if is_explain_mode() {
            "_durable_explain_nodes"
        } else {
            "df.nodes"
        };

        let sql = format!(
            r#"INSERT INTO {} (id, node_type, query, result_name, left_node, right_node)
               VALUES ('{}', '{}', {}, {}, {}, {})"#,
            target_table,
            self.node_id,
            self.node_type,
            query_escaped,
            result_name_escaped,
            left_node,
            right_node
        );

        Spi::run(&sql).expect("failed to insert node");
    }
}

/// Check if we're in explain mode (for dry-run graph visualization)
pub fn is_explain_mode() -> bool {
    Spi::get_one::<bool>(
        "SELECT COALESCE(current_setting('df._explain_mode', true), 'false') = 'true'",
    )
    .ok()
    .flatten()
    .unwrap_or(false)
}
