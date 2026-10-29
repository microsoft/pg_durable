// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteSQL activity - runs SQL queries against PostgreSQL
//!
//! Connects as the submitting user (submitted_by) for proper privilege isolation.
//! The submitted_by value comes from the in-memory FunctionGraph that
//! load_function_graph produced at instance start.  That snapshot is loaded once
//! per instance and then carried inline — into every child sub-orchestration
//! input and across every continue_as_new generation — so it is immutable for
//! the instance's whole lifetime.  Post-start tampering of df.nodes therefore
//! cannot change the identity used by execute_sql: the tampered value is simply
//! never read.
//!
//! Role deletion and privilege changes are still enforced at execution time
//! rather than by re-reading: connect_as_user() opens a connection *as*
//! submitted_by (there is no SET ROLE indirection), so a dropped role or one
//! that has lost LOGIN fails the node.  The HTTP activities re-check EXECUTE
//! privilege on df.http()/df.http_multipart() per request.
//!
//! Not covered: pg_durable.enable_superuser_instances is evaluated once, when
//! the instance is admitted.  Turning it off does not stop already-running
//! superuser instances.
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
//! | float4/float8        | JSON number (NaN/Inf → null)         |
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

use crate::types::{
    connect_as_user, get_execution_acquire_timeout, get_max_user_connections, SqlQuotingVersion,
};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-sql";

/// Input for the execute_sql activity
#[derive(Debug, Serialize, Deserialize)]
pub struct ExecuteSqlInput {
    pub query: String,
    pub submitted_by: String,
    /// Target database (None = extension database). Historical inputs include the null.
    pub database: Option<String>,
    #[serde(default, skip_serializing_if = "SqlQuotingVersion::is_legacy")]
    pub sql_quoting_version: SqlQuotingVersion,
}

pub(crate) async fn prepare_sql_quoting(
    conn: &mut sqlx::PgConnection,
    version: SqlQuotingVersion,
) -> Result<(), String> {
    if version.is_legacy() {
        // Pin an already-enabled setting so a configuration reload cannot make
        // historical literals unsafe between this check and query parsing.
        let setting = sqlx::query_scalar::<_, String>(
            "SELECT pg_catalog.set_config('standard_conforming_strings', 'on', false)
             WHERE pg_catalog.current_setting('standard_conforming_strings')
                   OPERATOR(pg_catalog.=) 'on'",
        )
        .fetch_optional(conn)
        .await
        .map_err(|e| format!("Failed to enforce legacy SQL quoting: {e}"))?;
        if setting.is_none() {
            return Err(
                "Legacy workflow SQL requires standard_conforming_strings=on; \
                 replay-compatible literals are unsafe when it is off"
                    .to_string(),
            );
        }
    }
    Ok(())
}

/// Decode a single column value from a PostgreSQL row into a `serde_json::Value`.
///
/// Dispatches based on the column's declared PostgreSQL type name. Returns an
/// error for unsupported types. Non-finite float values (NaN / ±Infinity) are
/// represented as JSON `null` since JSON has no representation for them.
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
                    Ok(serde_json::Value::Null)
                } else {
                    Ok(serde_json::Value::Number(
                        serde_json::Number::from_f64(v as f64).unwrap_or_else(|| {
                            panic!("finite f32 {v} must convert to JSON number")
                        }),
                    ))
                }
            }
            Ok(None) => Ok(serde_json::Value::Null),
            Err(e) => Err(format!("Failed to decode FLOAT4 column '{col_name}': {e}")),
        },
        "FLOAT8" => match row.try_get::<Option<f64>, _>(col_name) {
            Ok(Some(v)) => {
                if v.is_nan() || v.is_infinite() {
                    Ok(serde_json::Value::Null)
                } else {
                    Ok(serde_json::Value::Number(
                        serde_json::Number::from_f64(v).unwrap_or_else(|| {
                            panic!("finite f64 {v} must convert to JSON number")
                        }),
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
    execute_in_origin(ctx, semaphore, input_json, None, None).await
}

pub(crate) async fn execute_in_origin(
    ctx: ActivityContext,
    semaphore: Arc<Semaphore>,
    input_json: String,
    origin: Option<crate::origin::Origin>,
    mut source: Option<&mut crate::origin::Route>,
) -> Result<String, String> {
    let input: ExecuteSqlInput =
        serde_json::from_str(&input_json).map_err(|e| format!("Invalid execute_sql input: {e}"))?;

    ctx.trace_info(format!(
        "Executing SQL as '{}'{}{}",
        input.submitted_by,
        input
            .database
            .as_ref()
            .map(|db| format!(" in database '{db}'"))
            .unwrap_or_default(),
        if crate::types::log_workflow_sql_enabled() {
            format!(": {}", input.query)
        } else {
            String::new()
        }
    ));

    // Acquire a permit from the user-connection semaphore. The permit is held
    // for the entire SQL execution and released automatically when dropped.
    let _permit = crate::types::acquire_execution_permit(
        &semaphore,
        get_execution_acquire_timeout(),
        get_max_user_connections(),
    )
    .await?;

    if let Some(source) = source.as_mut() {
        source.validate().await?;
    }
    let mut conn = connect_as_user(&input.submitted_by, input.database.as_deref()).await?;
    if let Some(source) = source.as_mut() {
        source.validate().await?;
    }

    if let Some(origin) = origin {
        crate::origin::validate_execution_connection(&mut conn, &origin).await?;
    }
    prepare_sql_quoting(&mut conn, input.sql_quoting_version).await?;
    if let Some(source) = source {
        source.validate().await?;
    }

    execute_query(&ctx, &mut conn, &input.query).await
}

async fn execute_query(
    ctx: &ActivityContext,
    conn: &mut sqlx::PgConnection,
    query: &str,
) -> Result<String, String> {
    // SECURITY: Dynamic SQL is intentional. The query is authored by the submitting
    // user via df.sql() and executes under their own role via connect_as_user().
    // This is equivalent to the user running SQL directly.
    // See docs/spec-security-model.md §4 for the full threat model.
    match sqlx::query(query).fetch_all(conn).await {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sql_quoting_version_preserves_legacy_activity_bytes() {
        for legacy in [
            r#"{"query":"SELECT '\\path'","submitted_by":"reader","database":null}"#,
            r#"{"query":"SELECT '\\path'","submitted_by":"reader","database":"other"}"#,
        ] {
            let input: ExecuteSqlInput = serde_json::from_str(legacy).unwrap();
            assert_eq!(input.sql_quoting_version, SqlQuotingVersion::Legacy);
            assert_eq!(serde_json::to_string(&input).unwrap(), legacy);
        }
    }

    #[test]
    fn sql_quoting_version_is_explicit_for_new_activities() {
        let current = r#"{"query":"SELECT 1","submitted_by":"reader","database":null,"sql_quoting_version":"v1"}"#;
        let input: ExecuteSqlInput = serde_json::from_str(current).unwrap();
        assert_eq!(input.sql_quoting_version, SqlQuotingVersion::V1);
        assert_eq!(serde_json::to_string(&input).unwrap(), current);
        assert!(serde_json::from_str::<ExecuteSqlInput>(
            r#"{"query":"SELECT 1","submitted_by":"reader","database":null,"sql_quoting_version":"v2"}"#
        )
        .is_err());
    }
}
