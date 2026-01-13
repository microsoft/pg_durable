//! ExecuteSQL activity - runs SQL queries against PostgreSQL

use duroxide::ActivityContext;
use pgrx::prelude::*;
use std::sync::Mutex;
use once_cell::sync::Lazy;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-sql";

/// Global lock to prevent concurrent SPI access
/// The background worker runs a single-threaded tokio runtime, but we need to ensure
/// that only one activity enters SPI at a time
static SPI_LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

/// Execute a SQL query and return results as JSON
/// 
/// This function loads the security context from df.instances and uses SPI
/// with SetUserIdAndSecContext to execute the query with the submitting user's privileges.
pub async fn execute(
    ctx: ActivityContext,
    input_json: String,
) -> Result<String, String> {
    // Parse input
    let input: serde_json::Value = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid execute_sql input: {}", e))?;
    
    let instance_id = input["instance_id"]
        .as_str()
        .ok_or("Missing instance_id in execute_sql input")?
        .to_string();
    
    let query = input["query"]
        .as_str()
        .ok_or("Missing query in execute_sql input")?
        .to_string();
    
    ctx.trace_info(format!("Executing SQL: {query}"));

    // Acquire SPI lock to prevent concurrent access
    let _lock = SPI_LOCK.lock().unwrap();

    // Load security context from df.instances
    let sec_ctx = load_security_context(&instance_id)?;
    
    // Execute SQL with security context switch
    execute_sql_with_security_context(sec_ctx, query)
}

/// Load security context from df.instances table
fn load_security_context(instance_id: &str) -> Result<crate::types::SecurityContext, String> {
    use crate::types::SecurityContext;
    
    Spi::connect(|client| {
        let query = "SELECT security_context::text FROM df.instances WHERE id = $1";
        let result = client
            .select(query, None, Some(vec![(PgOid::BuiltIn(PgBuiltInOids::TEXTOID), instance_id.into_datum())]))
            .map_err(|e| format!("Failed to load security context: {:?}", e))?;
        
        let row = result.first();
        let sec_ctx_json: String = row
            .get_by_name("security_context")
            .map_err(|e| format!("Failed to get security_context column: {:?}", e))?
            .ok_or("security_context is NULL")?;
        
        SecurityContext::from_json(&sec_ctx_json)
    })
}

/// Execute SQL within a specific user's security context
/// 
/// # Safety
/// Uses unsafe PostgreSQL C APIs for security context switching.
/// Context is always restored via RAII guard, even on error/panic.
#[pg_guard]
fn execute_sql_with_security_context(
    security_ctx: crate::types::SecurityContext,
    query: String,
) -> Result<String, String> {
    // Save current context
    let saved_context = unsafe {
        let mut userid: pg_sys::Oid = 0;
        let mut sec_context: i32 = 0;
        pg_sys::GetUserIdAndSecContext(&mut userid, &mut sec_context);
        (userid, sec_context)
    };

    // RAII guard ensures context is always restored
    struct ContextGuard(pg_sys::Oid, i32);
    impl Drop for ContextGuard {
        fn drop(&mut self) {
            unsafe { pg_sys::SetUserIdAndSecContext(self.0, self.1); }
        }
    }
    let _guard = ContextGuard(saved_context.0, saved_context.1);

    // Switch to submitting user's context
    unsafe {
        pg_sys::SetUserIdAndSecContext(
            security_ctx.user_oid,
            saved_context.1 | pg_sys::SECURITY_LOCAL_USERID_CHANGE as i32,
        );
    }

    // Execute SQL via SPI - runs with user's privileges
    Spi::connect(|mut client| {
        // Set search_path to match user's session
        client
            .update(
                "SELECT set_config('search_path', $1, true)",
                None,
                Some(vec![(PgOid::BuiltIn(PgBuiltInOids::TEXTOID), security_ctx.search_path.into_datum())]),
            )
            .map_err(|e| format!("Failed to set search_path: {:?}", e))?;

        // Execute user's query
        let result = client
            .select(&query, None, None)
            .map_err(|e| format!("SQL execution failed: {:?}", e))?;

        // Convert results to JSON
        let mut result_rows: Vec<serde_json::Value> = Vec::new();
        for row in result {
            let mut row_obj = serde_json::Map::new();
            
            // Iterate over columns (pgrx columns are 1-indexed)
            for ordinal in 1..=row.columns().len() {
                let col_name = row.columns().get(ordinal - 1)
                    .map(|c| c.name())
                    .unwrap_or("unknown");
                
                // Try to extract value as different types
                if let Ok(Some(val)) = row.get::<String>(ordinal) {
                    row_obj.insert(col_name.to_string(), serde_json::Value::String(val));
                } else if let Ok(Some(val)) = row.get::<i64>(ordinal) {
                    row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                } else if let Ok(Some(val)) = row.get::<i32>(ordinal) {
                    row_obj.insert(col_name.to_string(), serde_json::Value::Number(val.into()));
                } else if let Ok(Some(val)) = row.get::<bool>(ordinal) {
                    row_obj.insert(col_name.to_string(), serde_json::Value::Bool(val));
                } else if let Ok(Some(val)) = row.get::<f64>(ordinal) {
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

        Ok(result.to_string())
    })
    // _guard dropped here → context restored
}
