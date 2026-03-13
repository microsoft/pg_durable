//! ExecuteSQL activity - runs SQL queries against PostgreSQL
//!
//! Connects as the submitting user's login_role and SET ROLE to submitted_by
//! for proper privilege isolation.

use duroxide::ActivityContext;
use serde::{Deserialize, Serialize};
use sqlx::{Column, PgPool, Row};
use std::sync::Arc;

use crate::types::connect_as_user;

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

/// Split a SQL string by semicolons, respecting single-quoted string literals
/// and PostgreSQL dollar-quoted strings (e.g. $$ ... $$, $tag$ ... $tag$).
fn split_statements(sql: &str) -> Vec<&str> {
    let mut statements = Vec::new();
    let mut start = 0;
    let bytes = sql.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        match bytes[i] {
            b'\'' => {
                // Skip single-quoted string: advance past closing quote
                // (doubled '' is an escaped quote, not end-of-string)
                i += 1;
                while i < len {
                    if bytes[i] == b'\'' {
                        i += 1;
                        if i < len && bytes[i] == b'\'' {
                            // escaped quote '', keep going
                            i += 1;
                            continue;
                        }
                        break;
                    }
                    i += 1;
                }
            }
            b'$' => {
                // Check for dollar-quoted string: $$ or $tag$
                if let Some(tag_end) = sql[i + 1..].find('$') {
                    let tag = &sql[i..i + 1 + tag_end + 1]; // e.g. "$$" or "$tag$"
                                                            // Validate tag content (between $ signs) is a valid identifier or empty
                    let tag_body = &tag[1..tag.len() - 1];
                    if tag_body.is_empty()
                        || tag_body.chars().all(|c| c.is_alphanumeric() || c == '_')
                    {
                        // Find the matching closing tag
                        let after_open = i + tag.len();
                        if let Some(close_pos) = sql[after_open..].find(tag) {
                            i = after_open + close_pos + tag.len();
                            continue;
                        }
                    }
                }
                i += 1;
            }
            b'-' if i + 1 < len && bytes[i + 1] == b'-' => {
                // Skip single-line comment
                i += 2;
                while i < len && bytes[i] != b'\n' {
                    i += 1;
                }
                i += 1; // skip the newline
            }
            b'/' if i + 1 < len && bytes[i + 1] == b'*' => {
                // Skip block comment (non-nested)
                i += 2;
                while i + 1 < len {
                    if bytes[i] == b'*' && bytes[i + 1] == b'/' {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            }
            b';' => {
                let stmt = sql[start..i].trim();
                if !stmt.is_empty() {
                    statements.push(stmt);
                }
                start = i + 1;
                i += 1;
            }
            _ => {
                i += 1;
            }
        }
    }

    // Last segment (after final semicolon or if no semicolons)
    let last = sql[start..].trim();
    if !last.is_empty() {
        statements.push(last);
    }

    statements
}

/// Convert sqlx rows to JSON value
fn rows_to_json(rows: Vec<sqlx::postgres::PgRow>) -> Vec<serde_json::Value> {
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
    result_rows
}

/// Execute a SQL query as the submitting user and return results as JSON.
/// Supports multiple semicolon-separated statements; the result of the last
/// statement is returned.
pub async fn execute(
    ctx: ActivityContext,
    _pool: Arc<PgPool>,
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

    // Create a single connection as login_role, SET ROLE to submitted_by
    let mut conn = connect_as_user(
        &input.login_role,
        &input.submitted_by,
        input.database.as_deref(),
    )
    .await?;

    let statements = split_statements(&input.query);

    // Single statement: fast path (no splitting overhead)
    if statements.len() <= 1 {
        let stmt = statements.first().copied().unwrap_or("");
        return execute_single_statement(&ctx, &mut conn, stmt).await;
    }

    // Multiple statements: wrap in a transaction for atomicity
    ctx.trace_info(format!(
        "Multi-statement SQL: {} statements detected, executing in transaction",
        statements.len()
    ));

    sqlx::query("BEGIN")
        .execute(&mut conn)
        .await
        .map_err(|e| format!("Failed to BEGIN transaction: {e}"))?;

    let mut last_result = None;
    for (i, stmt) in statements.iter().enumerate() {
        ctx.trace_info(format!(
            "Executing statement {}/{}: {}",
            i + 1,
            statements.len(),
            stmt
        ));
        match execute_single_statement(&ctx, &mut conn, stmt).await {
            Ok(result) => last_result = Some(result),
            Err(e) => {
                // Rollback on failure (best-effort; connection may be in error state)
                let _ = sqlx::query("ROLLBACK").execute(&mut conn).await;
                return Err(e);
            }
        }
    }

    sqlx::query("COMMIT")
        .execute(&mut conn)
        .await
        .map_err(|e| format!("Failed to COMMIT transaction: {e}"))?;

    Ok(last_result.unwrap_or_else(|| serde_json::json!({"rows": [], "row_count": 0}).to_string()))
}

async fn execute_single_statement(
    ctx: &ActivityContext,
    conn: &mut sqlx::postgres::PgConnection,
    stmt: &str,
) -> Result<String, String> {
    match sqlx::query(stmt).fetch_all(&mut *conn).await {
        Ok(rows) => {
            let result_rows = rows_to_json(rows);
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
