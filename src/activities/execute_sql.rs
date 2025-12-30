//! ExecuteSQL activity - runs SQL queries against PostgreSQL

use duroxide::ActivityContext;
use sqlx::{Column, PgPool, Row};
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-sql";

/// Execute a SQL query and return results as JSON
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    query: String,
) -> Result<String, String> {
    ctx.trace_info(format!("Executing SQL: {query}"));

    match sqlx::query(&query).fetch_all(pool.as_ref()).await {
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
