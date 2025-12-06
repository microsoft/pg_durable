//! Core types and configuration for pg_durable

use pgrx::prelude::*;
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use std::time::Duration;
use cron::Schedule as CronSchedule;
use chrono::{DateTime, Utc};
use std::str::FromStr;

// ============================================================================
// Configuration Functions
// ============================================================================

/// Generate a short 8-character instance ID from a UUID
pub fn short_id() -> String {
    let uuid = Uuid::new_v4();
    uuid.to_string().chars().rev().take(8).collect::<String>().chars().rev().collect()
}

/// Path to the shared SQLite database for duroxide.
pub fn duroxide_db_path() -> String {
    if let Ok(path) = std::env::var("PG_DURABLE_STORE_PATH") {
        return path;
    }
    
    if let Ok(pgdata) = std::env::var("PGDATA") {
        return format!("{}/pg_durable_duroxide.db", pgdata);
    }
    
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    
    for version in &["17", "16", "15", "14", "13"] {
        let pgrx_data = format!("{}/.pgrx/data-{}", home, version);
        if std::path::Path::new(&pgrx_data).exists() {
            return format!("{}/pg_durable_duroxide.db", pgrx_data);
        }
    }
    
    if let Ok(Some(data_dir)) = Spi::get_one::<String>("SELECT current_setting('data_directory')") {
        return format!("{}/pg_durable_duroxide.db", data_dir);
    }
    
    format!("{}/pg_durable_duroxide.db", home)
}

/// Connection string for the duroxide SQLite store
pub fn duroxide_connection_string() -> String {
    duroxide_db_path()
}

/// PostgreSQL connection string for the background worker
pub fn postgres_connection_string() -> String {
    let host = std::env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("PGPORT").unwrap_or_else(|_| {
        if let Ok(pgdata) = std::env::var("PGDATA") {
            if pgdata.contains(".pgrx") {
                "28817".to_string()
            } else {
                "5432".to_string()
            }
        } else {
            "28817".to_string()
        }
    });
    let user = std::env::var("PGUSER")
        .or_else(|_| std::env::var("USER"))
        .unwrap_or_else(|_| "postgres".to_string());
    let database = std::env::var("POSTGRES_DB")
        .or_else(|_| std::env::var("PGDATABASE"))
        .unwrap_or_else(|_| "postgres".to_string());
    
    format!("postgres://{}@{}:{}/{}", user, host, port, database)
}

/// Calculate the duration until the next cron schedule match
pub fn calculate_cron_wait(cron_expr: &str) -> Result<Duration, String> {
    let cron_with_seconds = format!("0 {}", cron_expr);
    
    let schedule = CronSchedule::from_str(&cron_with_seconds)
        .map_err(|e| format!("Invalid cron expression '{}': {}", cron_expr, e))?;
    
    let now: DateTime<Utc> = Utc::now();
    
    let next = schedule.upcoming(Utc)
        .next()
        .ok_or_else(|| "No upcoming schedule found".to_string())?;
    
    let duration = (next - now).to_std()
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
    Ok(matches!(lower.as_str(), "true" | "t" | "yes" | "1") || 
       lower.parse::<i64>().map(|n| n != 0).unwrap_or(false))
}

fn is_truthy(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::Number(n) => {
            n.as_i64().map(|i| i != 0).unwrap_or(false) ||
            n.as_f64().map(|f| f != 0.0).unwrap_or(false)
        }
        serde_json::Value::String(s) => {
            let lower = s.to_lowercase();
            matches!(lower.as_str(), "true" | "t" | "yes" | "1") ||
            s.parse::<i64>().map(|n| n != 0).unwrap_or(!s.is_empty())
        }
        serde_json::Value::Array(a) => !a.is_empty(),
        serde_json::Value::Object(o) => !o.is_empty(),
        serde_json::Value::Null => false,
    }
}

/// Substitute $name variables in a query with values from results map
pub fn substitute_variables(query: &str, results: &std::collections::HashMap<String, String>) -> String {
    let mut result = query.to_string();
    for (name, value) in results {
        let pattern = format!("${}", name);
        if result.contains(&pattern) {
            let replacement = if let Ok(json) = serde_json::from_str::<serde_json::Value>(value) {
                if let Some(rows) = json.get("rows").and_then(|r| r.as_array()) {
                    if let Some(first_row) = rows.first() {
                        if let Some(obj) = first_row.as_object() {
                            if let Some((_, val)) = obj.iter().next() {
                                match val {
                                    serde_json::Value::String(s) => s.clone(),
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
                } else {
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

// ============================================================================
// Workflow Graph Types
// ============================================================================

/// Represents a node in the workflow graph
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowNode {
    pub id: String,
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
}

/// Represents the entire workflow graph for an instance
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowGraph {
    pub instance_id: String,
    pub root_node_id: String,
    pub nodes: std::collections::HashMap<String, WorkflowNode>,
}

/// Input structure passed to duroxide orchestrations
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestrationInput {
    pub instance_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

// ============================================================================
// Durofut Type - Represents a workflow node reference
// ============================================================================

/// The Durofut type represents a "durable future" - a reference to a node in the workflow graph.
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

    /// Insert this node into the durable.nodes table
    pub fn insert_node(&self) {
        let query_escaped = self.query.as_ref()
            .map(|q| q.replace('\'', "''"))
            .map(|q| format!("'{}'", q))
            .unwrap_or_else(|| "NULL".to_string());
        
        let result_name_escaped = self.result_name.as_ref()
            .map(|n| format!("'{}'", n.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());
        
        let left_node = self.left_node.as_ref()
            .map(|id| format!("'{}'::uuid", id))
            .unwrap_or_else(|| "NULL".to_string());
        
        let right_node = self.right_node.as_ref()
            .map(|id| format!("'{}'::uuid", id))
            .unwrap_or_else(|| "NULL".to_string());

        let sql = format!(
            r#"INSERT INTO durable.nodes (id, node_type, query, result_name, left_node, right_node)
               VALUES ('{}', '{}', {}, {}, {}, {})"#,
            self.node_id, self.node_type, query_escaped, result_name_escaped, left_node, right_node
        );
        
        Spi::run(&sql).expect("failed to insert node");
    }
}

