//! ExecuteSQL activity - runs SQL queries against PostgreSQL
//!
//! Connects as the submitting user's login_role and SET ROLE to submitted_by
//! for proper privilege isolation. Connection count is gated by a semaphore
//! sized from the pg_durable.max_user_connections GUC.

use duroxide::ActivityContext;
use serde::{Deserialize, Serialize};
use sqlx::{Column, Row};
use std::sync::Arc;
use tokio::sync::Semaphore;

use crate::types::{connect_as_user, get_execution_acquire_timeout, get_max_user_connections};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-sql";

/// Input for the execute_sql activity
#[derive(Debug, Serialize, Deserialize)]
pub struct ExecuteSqlInput {
    pub query: String,
    pub submitted_by: String,
    pub login_role: String,
    /// Target database (None = extension database)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
}

/// Execute a SQL query as the submitting user and return results as JSON
pub async fn execute(
    ctx: ActivityContext,
    semaphore: Arc<Semaphore>,
    input_json: String,
) -> Result<String, String> {
    let input: ExecuteSqlInput =
        serde_json::from_str(&input_json).map_err(|e| format!("Invalid execute_sql input: {e}"))?;

    ctx.trace_info(format!(
        "Executing SQL as '{}' (connected as '{}'){}: {}",
        input.submitted_by,
        input.login_role,
        input
            .database
            .as_ref()
            .map(|db| format!(" in database '{db}'"))
            .unwrap_or_default(),
        input.query
    ));

    // Acquire a permit from the user-connection semaphore. The permit is held
    // for the entire SQL execution and released automatically when dropped.
    let timeout = get_execution_acquire_timeout();
    let limit = get_max_user_connections();
    let _permit = match tokio::time::timeout(timeout, semaphore.acquire()).await {
        Ok(Ok(permit)) => permit,
        Ok(Err(_)) => {
            return Err(format!(
                "pg_durable: connection limit reached (max_user_connections={limit}). \
                 Semaphore closed unexpectedly."
            ));
        }
        Err(_) => {
            return Err(format!(
                "pg_durable: connection limit reached (max_user_connections={limit}). \
                 Timed out after {}s waiting for an available execution slot.",
                timeout.as_secs()
            ));
        }
    };

    // Create a single connection as login_role, SET ROLE to submitted_by
    let mut conn = connect_as_user(
        &input.login_role,
        &input.submitted_by,
        input.database.as_deref(),
    )
    .await?;

    match sqlx::query(&input.query).fetch_all(&mut conn).await {
        Ok(rows) => {
            let mut result_rows: Vec<serde_json::Value> = Vec::new();
            for row in rows {
                let columns = row.columns();
                let mut row_obj = serde_json::Map::new();

                for col in columns {
                    let col_name = col.name();
                    if let Ok(val) = row.try_get::<String, _>(col_name) {
                        row_obj.insert(col_name.to_string(), serde_json::Value::String(val));
                    } else if let Ok(val) = row.try_get::<i64, _>(col_name) {
                        row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                    } else if let Ok(val) = row.try_get::<i32, _>(col_name) {
                        row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                    } else if let Ok(val) = row.try_get::<bool, _>(col_name) {
                        row_obj.insert(col_name.to_string(), serde_json::Value::Bool(val));
                    } else if let Ok(val) = row.try_get::<f64, _>(col_name) {
                        if let Some(n) = serde_json::Number::from_f64(val) {
                            row_obj.insert(col_name.to_string(), serde_json::Value::Number(n));
                        }
                    } else {
                        row_obj.insert(col_name.to_string(), serde_json::Value::Null);
                    }
                }
                result_rows.push(serde_json::Value::Object(row_obj));
            }

            let result = serde_json::json!({
                "rows": result_rows,
                "row_count": result_rows.len()
            });

            ctx.trace_info(format!("SQL returned {} rows", result_rows.len()));
            Ok(result.to_string())
        }
        Err(e) => {
            let err_msg = format!("SQL execution failed: {e}");
            ctx.trace_info(&err_msg);
            Err(err_msg)
        }
    }
}
