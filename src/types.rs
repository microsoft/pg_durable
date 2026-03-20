//! Core types and configuration for pg_durable

use pgrx::pg_extern;

use chrono::{DateTime, Utc};
use cron::Schedule as CronSchedule;
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

/// Get the database from the `pg_durable.database` GUC.
/// Falls back to `"postgres"` if the GUC is not set.
pub fn get_database() -> String {
    crate::DATABASE
        .get()
        .map(|cs: CString| cs.to_string_lossy().into_owned())
        .unwrap_or_else(|| "postgres".to_string())
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

/// Create a single PostgreSQL connection authenticated as `login_role`,
/// then SET ROLE to `effective_role`.
pub async fn connect_as_user(
    login_role: &str,
    effective_role: &str,
    database: Option<&str>,
) -> Result<sqlx::postgres::PgConnection, String> {
    use sqlx::postgres::PgConnectOptions;
    use sqlx::Connection;

    let default_db = target_database();
    let db = database.unwrap_or(&default_db);
    let mut options = PgConnectOptions::new()
        .username(login_role)
        .database(db)
        .port(get_port());

    let host = get_host();
    if !host.is_empty() {
        options = options.host(&host);
    }

    let mut conn = sqlx::postgres::PgConnection::connect_with(&options)
        .await
        .map_err(|e| {
            format!(
                "Failed to connect to database '{}' as '{}' (for effective role '{}'). Error: {}",
                db, login_role, effective_role, e
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
/// - `ApplyAll`: applies pending duroxide migrations at startup; creates tables
///   inside the extension-owned `duroxide` schema. Safe because the BGW verifies
///   schema ownership via `pg_depend` before calling `PostgresProvider::new_with_config`.
/// - Long-polling intentionally left enabled (default) for the BGW runtime,
///   unlike backend sessions where it's disabled to save resources.
pub fn worker_provider_config() -> duroxide_pg_opt::ProviderConfig {
    let mut config = duroxide_pg_opt::ProviderConfig::default();
    config.schema_name = Some(DUROXIDE_SCHEMA.to_string());
    config.migration_policy = duroxide_pg_opt::MigrationPolicy::ApplyAll;
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
    /// Authenticated connection role (audit trail)
    #[serde(default)]
    pub login_role: Option<String>,
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
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("failed to serialize Durofut")
    }

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
    pub fn validate_recursive(&self) -> Result<(), String> {
        if !VALID_NODE_TYPES.contains(&self.node_type.as_str()) {
            return Err(format!(
                "Unknown node_type '{}'. Valid types: {}",
                self.node_type,
                VALID_NODE_TYPES.join(", ")
            ));
        }
        if let Some(ref left) = self.left_node {
            left.validate_recursive()?;
        }
        if let Some(ref right) = self.right_node {
            right.validate_recursive()?;
        }
        // Validate config-embedded nodes (condition_node, extra_nodes)
        self.for_each_config_child(|child| child.validate_recursive())?;
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
}
