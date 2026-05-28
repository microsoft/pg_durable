// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteSQL activity - runs SQL queries against PostgreSQL
//!
//! Connects as the submitting user (submitted_by) for proper privilege isolation.
//! The submitted_by value comes from the in-memory FunctionGraph cached by
//! duroxide after load_function_graph runs.  Within a single orchestration
//! generation that cache is immutable: post-load tampering of df.nodes cannot
//! change the identity used by execute_sql.
//!
//! ⚠️  Loop functions use continue_as_new, which discards duroxide history and
//! starts a fresh orchestration generation.  load_function_graph is therefore
//! called again at the start of every loop iteration, re-reading submitted_by
//! from df.instances and df.nodes.  A tamper applied between iterations is
//! caught by load_function_graph's superuser check on the next re-read, which
//! fails the instance rather than executing SQL under a forged identity.
//!
//! Connection count is gated by a semaphore sized from the
//! pg_durable.max_user_connections GUC.
//!
//! ## Result JSON contract
//!
//! Each column value is serialized based on its PostgreSQL type:
//!
//! | Postgres Type        | JSON Representation                  |
//! |----------------------|--------------------------------------|
//! | bool                 | JSON boolean                         |
//! | int2/int4/int8       | JSON integer                         |
//! | float4/float8        | JSON number (NaN/Inf → error)        |
//! | text/varchar/bpchar  | JSON string                          |
//! | numeric/decimal      | JSON string (exact, preserves scale) |
//! | uuid                 | JSON string (canonical)              |
//! | timestamptz          | JSON string (RFC3339)                |
//! | timestamp            | JSON string (RFC3339, no timezone)   |
//! | date                 | JSON string (YYYY-MM-DD)             |
//! | jsonb/json           | Native JSON value                    |
//! | void                 | JSON null (e.g. pg_sleep)            |
//! | SQL NULL             | JSON null (for any type above)       |
//! | other/unsupported    | Error (fail loudly)                  |

use duroxide::ActivityContext;
use serde::{Deserialize, Serialize};
use sqlx::{Column, Row, TypeInfo};
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
    /// Target database (None = extension database)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
}

/// Decode a single column value from a PostgreSQL row into a `serde_json::Value`.
///
/// Dispatches based on the column's declared PostgreSQL type name. Returns an
/// error for unsupported types or non-finite float values rather than silently
/// producing `null`.
fn decode_column(
    row: &sqlx::postgres::PgRow,
    col: &sqlx::postgres::PgColumn,
) -> Result<serde_json::Value, String> {
    let col_name = col.name();
    let type_name = col.type_info().name();

    match type_name {
        "BOOL" => match row.try_get::<Option<bool>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::Bool(v)),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode BOOL column '{col_name}': {e}")),
        },
        "INT2" => match row.try_get::<Option<i16>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::Number(v.into())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode INT2 column '{col_name}': {e}")),
        },
        "INT4" => match row.try_get::<Option<i32>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::Number(v.into())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode INT4 column '{col_name}': {e}")),
        },
        "INT8" => match row.try_get::<Option<i64>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::Number(v.into())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode INT8 column '{col_name}': {e}")),
        },
        "FLOAT4" => match row.try_get::<Option<f32>, _>(col_name) {
            Ok(Some(v)) => {
                if v.is_nan() || v.is_infinite() {
                    Err(format!(
                        "FLOAT4 column '{col_name}' contains non-finite value (NaN or Inf)"
                    ))
                } else if let Some(n) = serde_json::Number::from_f64(v as f64) {
                    Ok(serde_json::Value::Number(n))
                } else {
                    Err(format!(
                        "FLOAT4 column '{col_name}': value cannot be represented as JSON number"
                    ))
                }
            }
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode FLOAT4 column '{col_name}': {e}")),
        },
        "FLOAT8" => match row.try_get::<Option<f64>, _>(col_name) {
            Ok(Some(v)) => {
                if v.is_nan() || v.is_infinite() {
                    Err(format!(
                        "FLOAT8 column '{col_name}' contains non-finite value (NaN or Inf)"
                    ))
                } else if let Some(n) = serde_json::Number::from_f64(v) {
                    Ok(serde_json::Value::Number(n))
                } else {
                    Err(format!(
                        "FLOAT8 column '{col_name}': value cannot be represented as JSON number"
                    ))
                }
            }
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode FLOAT8 column '{col_name}': {e}")),
        },
        "TEXT" | "VARCHAR" | "BPCHAR" | "NAME" => {
            match row.try_get::<Option<String>, _>(col_name) {
                Ok(Some(v)) => Ok(serde_json::Value::String(v)),
                Ok(None) => Ok(serde_json::Value::Null),
                Err(e) => Err(format!("Failed to decode text column '{col_name}': {e}")),
            }
        }
        "NUMERIC" => match row.try_get::<Option<bigdecimal::BigDecimal>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::String(v.to_string())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode NUMERIC column '{col_name}': {e}")),
        },
        "UUID" => match row.try_get::<Option<uuid::Uuid>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::String(v.to_string())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode UUID column '{col_name}': {e}")),
        },
        "TIMESTAMPTZ" => match row.try_get::<Option<chrono::DateTime<chrono::Utc>>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::String(v.to_rfc3339())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!(
                "Failed to decode TIMESTAMPTZ column '{col_name}': {e}"
            )),
        },
        "TIMESTAMP" => match row.try_get::<Option<chrono::NaiveDateTime>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::String(
                v.format("%Y-%m-%dT%H:%M:%S%.f").to_string(),
            )),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!(
                "Failed to decode TIMESTAMP column '{col_name}': {e}"
            )),
        },
        "DATE" => match row.try_get::<Option<chrono::NaiveDate>, _>(col_name) {
            Ok(Some(v)) => Ok(serde_json::Value::String(v.to_string())),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode DATE column '{col_name}': {e}")),
        },
        "JSONB" | "JSON" => match row.try_get::<Option<serde_json::Value>, _>(col_name) {
            Ok(Some(v)) => Ok(v),
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode JSON column '{col_name}': {e}")),
        },
        // VOID-returning functions (e.g. pg_sleep, perform_*) have no meaningful
        // value; represent them as JSON null.
        "VOID" => Ok(serde_json::Value::Null),
        other => Err(format!(
            "Unsupported column type '{other}' for column '{col_name}'. \
             Supported types: bool, int2, int4, int8, float4, float8, \
             text, varchar, numeric, uuid, timestamptz, timestamp, date, jsonb, json, void."
        )),
    }
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
        "Executing SQL as '{}'{}: {}",
        input.submitted_by,
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

    let mut conn = connect_as_user(&input.submitted_by, input.database.as_deref()).await?;

    // SECURITY: Dynamic SQL is intentional. The query is authored by the submitting
    // user via df.sql() and executes under their own role via connect_as_user().
    // This is equivalent to the user running SQL directly.
    // See docs/spec-security-model.md §4 for the full threat model.
    match sqlx::query(&input.query).fetch_all(&mut conn).await {
        Ok(rows) => {
            let mut result_rows: Vec<serde_json::Value> = Vec::new();
            for row in &rows {
                let columns = row.columns();
                let mut row_obj = serde_json::Map::new();

                for col in columns {
                    let col_name = col.name().to_string();
                    let value = decode_column(row, col)?;
                    row_obj.insert(col_name, value);
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
