//! DSL functions for defining durable SQL functions

use chrono::Utc;
use cron::Schedule as CronSchedule;
use pgrx::prelude::*;
use std::str::FromStr;

use crate::client::start_durable_function;
use crate::types::{short_id, Durofut, FunctionInput};

/// Check if we're running inside a workflow context (background worker connection).
/// The background worker sets df.in_workflow='true' on all its connections.
fn is_in_workflow_context() -> bool {
    // Check the session variable set by the background worker
    // current_setting with missing_ok=true returns NULL if not set
    let result: Option<String> = Spi::get_one("SELECT current_setting('df.in_workflow', true)")
        .ok()
        .flatten();

    result.as_deref() == Some("true")
}

// ============================================================================
// Version & Debug Functions
// ============================================================================

/// Returns the pg_durable version (semver + build timestamp)
#[pg_extern(schema = "df")]
pub fn version() -> String {
    format!(
        "{} (built {})",
        env!("CARGO_PKG_VERSION"),
        env!("BUILD_TIMESTAMP")
    )
}

/// Debug function to see what duroxide connection is being used
#[pg_extern(schema = "df")]
pub fn debug_connection() -> String {
    use crate::types::{postgres_connection_string, DUROXIDE_SCHEMA};
    format!(
        "{} (schema: {})",
        postgres_connection_string(),
        DUROXIDE_SCHEMA
    )
}

// ============================================================================
// Variable Functions
// ============================================================================

/// Sets a workflow variable. Must be called BEFORE df.start(), not inside a workflow.
/// Variables are captured at df.start() and remain immutable during execution.
#[pg_extern(schema = "df")]
pub fn setvar(name: &str, value: &str) -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.setvar() cannot be called inside a workflow - set variables before starting the workflow");
    }

    let sql = format!(
        "INSERT INTO df.vars (name, value) VALUES ('{}', '{}')
         ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value",
        name.replace('\'', "''"),
        value.replace('\'', "''")
    );
    if let Err(e) = Spi::run(&sql) {
        pgrx::error!("Failed to set variable: {:?}", e);
    }
    "OK".to_string()
}

/// Gets a workflow variable value.
#[pg_extern(schema = "df")]
pub fn getvar(name: &str) -> Option<String> {
    let sql = format!(
        "SELECT value FROM df.vars WHERE name = '{}'",
        name.replace('\'', "''")
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}

/// Removes a workflow variable.
#[pg_extern(schema = "df")]
pub fn unsetvar(name: &str) -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.unsetvar() cannot be called inside a workflow - manage variables before starting the workflow");
    }

    let sql = format!(
        "DELETE FROM df.vars WHERE name = '{}'",
        name.replace('\'', "''")
    );
    if let Err(e) = Spi::run(&sql) {
        pgrx::error!("Failed to unset variable: {:?}", e);
    }
    "OK".to_string()
}

/// Clears all workflow variables.
#[pg_extern(schema = "df")]
pub fn clearvars() -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.clearvars() cannot be called inside a workflow - manage variables before starting the workflow");
    }

    if let Err(e) = Spi::run("DELETE FROM df.vars") {
        pgrx::error!("Failed to clear variables: {:?}", e);
    }
    "OK".to_string()
}

// ============================================================================
// Node Creation Functions
// ============================================================================

/// Creates a SQL node in the function graph.
#[pg_extern(schema = "df")]
pub fn sql(query: &str) -> String {
    Durofut {
        node_type: "SQL".to_string(),
        query: Some(query.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a sequence node that executes two nodes in order.
/// The SQL operator ~> is syntactic sugar for this function.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "seq", schema = "df")]
pub fn then_fn(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "THEN".to_string(),
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
        ..Default::default()
    }
    .to_json()
}

/// Names a result for later reference.
/// The SQL operator |=> is syntactic sugar for this function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Note: Parameter order matches the |=> operator: fut |=> name -> df.as(fut, name)
#[pg_extern(name = "as", schema = "df")]
pub fn as_named(fut: &str, name: &str) -> String {
    let mut durofut = Durofut::ensure(fut);
    durofut.result_name = Some(name.to_string());

    durofut.to_json()
}

/// Creates a sleep node that pauses for the specified number of seconds.
#[pg_extern(schema = "df")]
pub fn sleep(seconds: i64) -> String {
    if seconds < 0 {
        pgrx::error!("Sleep duration must be non-negative");
    }
    Durofut {
        node_type: "SLEEP".to_string(),
        query: Some(seconds.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a wait-for-schedule node that waits until the next cron match.
/// The wait duration is computed at DSL time (when this function is called)
/// to ensure deterministic replay in the orchestration.
#[pg_extern(schema = "df")]
pub fn wait_for_schedule(cron_expr: &str) -> String {
    let cron_with_seconds = format!("0 {cron_expr}");
    let schedule = match CronSchedule::from_str(&cron_with_seconds) {
        Ok(s) => s,
        Err(e) => pgrx::error!("Invalid cron expression '{}': {}", cron_expr, e),
    };

    // Compute wait duration NOW (at DSL time) for deterministic orchestration replay
    let now = Utc::now();
    let next = match schedule.upcoming(Utc).next() {
        Some(t) => t,
        None => pgrx::error!("No upcoming schedule found for '{}'", cron_expr),
    };

    let duration_secs = (next - now).num_seconds().max(0) as u64;

    // Store pre-computed seconds, not the cron expression
    let config = serde_json::json!({
        "cron_expr": cron_expr,
        "wait_seconds": duration_secs
    });

    Durofut {
        node_type: "WAIT_SCHEDULE".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a loop node.
///
/// With one argument: repeats the body indefinitely (infinite loop).
/// With two arguments: repeats while the condition is true (while loop).
///
/// The body and condition can be either Durofut JSON or plain SQL strings (auto-wrapped).
/// The condition is evaluated after each iteration (do-while semantics).
///
/// # Examples
/// ```sql
/// -- Infinite loop
/// df.loop('SELECT process_item()')
///
/// -- While loop - continues while condition is true
/// df.loop('SELECT process_item()', 'SELECT count(*) > 0 FROM queue')
/// ```
#[pg_extern(name = "loop", schema = "df")]
pub fn loop_fn(body: &str, condition: default!(Option<&str>, "NULL")) -> String {
    let body_fut = Durofut::ensure(body);

    let query = if let Some(cond) = condition {
        let cond_fut = Durofut::ensure(cond);
        let config = serde_json::json!({
            "condition_node": cond_fut
        });
        Some(config.to_string())
    } else {
        None
    };

    Durofut {
        node_type: "LOOP".to_string(),
        left_node: Some(Box::new(body_fut)),
        query,
        ..Default::default()
    }
    .to_json()
}

/// Creates a break node that exits the enclosing loop.
///
/// When executed, the loop terminates and returns the provided value (or null).
///
/// # Examples
/// ```sql
/// -- Break with no value
/// df.break()
///
/// -- Break with a return value
/// df.break('{"status": "complete"}')
/// ```
#[pg_extern(name = "break", schema = "df")]
pub fn break_fn(value: default!(Option<&str>, "NULL")) -> String {
    let config = serde_json::json!({
        "break_value": value
    });

    Durofut {
        node_type: "BREAK".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a conditional branch node.
/// All arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "if", schema = "df")]
pub fn if_fn(condition: &str, then_branch: &str, else_branch: &str) -> String {
    let condition_fut = Durofut::ensure(condition);
    let then_fut = Durofut::ensure(then_branch);
    let else_fut = Durofut::ensure(else_branch);

    let config = serde_json::json!({
        "condition_node": condition_fut
    });

    Durofut {
        node_type: "IF".to_string(),
        left_node: Some(Box::new(then_fut)),
        right_node: Some(Box::new(else_fut)),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a parallel join node for 2 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn join(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "JOIN".to_string(),
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
        ..Default::default()
    }
    .to_json()
}

/// Creates a parallel join node for 3 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "join3", schema = "df")]
pub fn join3(a: &str, b: &str, c: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);
    let c_fut = Durofut::ensure(c);

    let config = serde_json::json!({
        "extra_nodes": [c_fut]
    });

    Durofut {
        node_type: "JOIN".to_string(),
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a race node - runs branches in parallel, first to complete wins.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn race(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "RACE".to_string(),
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
        ..Default::default()
    }
    .to_json()
}

/// Creates an HTTP request node.
/// Makes an HTTP request to the specified URL and returns the response.
///
/// # Arguments
/// * `url` - The URL to request
/// * `method` - HTTP method (GET, POST, PUT, DELETE, PATCH). Default: POST
/// * `body` - Request body (typically JSON). Supports $variable substitution
/// * `headers` - JSONB object of headers. Example: '{"Authorization": "Bearer token"}'
/// * `timeout_seconds` - Request timeout in seconds. Default: 30
///
/// # Returns
/// JSON object with: status, body, headers, ok (boolean), duration_ms
#[pg_extern(schema = "df")]
pub fn http(
    url: &str,
    method: default!(&str, "'POST'"),
    body: default!(Option<&str>, "NULL"),
    headers: default!(Option<pgrx::JsonB>, "NULL"),
    timeout_seconds: default!(i32, "30"),
) -> String {
    // Validate method
    let method_upper = method.to_uppercase();
    if !["GET", "POST", "PUT", "DELETE", "PATCH"].contains(&method_upper.as_str()) {
        pgrx::error!(
            "Invalid HTTP method: {}. Must be GET, POST, PUT, DELETE, or PATCH",
            method
        );
    }

    if timeout_seconds <= 0 {
        pgrx::error!("Timeout must be positive");
    }

    let config = serde_json::json!({
        "url": url,
        "method": method_upper,
        "body": body,
        "headers": headers.as_ref().map(|h| &h.0),
        "timeout_seconds": timeout_seconds
    });

    Durofut {
        node_type: "HTTP".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

// ============================================================================
// Signals
// ============================================================================

/// Wait for an external signal to be sent to this durable function instance.
///
/// Signals allow external code to send events to running durable functions, enabling:
/// - Human-in-the-loop approval workflows
/// - Webhook callbacks from external systems
/// - Event-driven coordination between processes
///
/// # Arguments
/// * `name` - Name of the signal to wait for
/// * `timeout_seconds` - Optional timeout in seconds (NULL = wait forever)
///
/// # Returns
/// JSON object with: signal_name, timed_out (boolean), data (the signal payload)
#[pg_extern(schema = "df")]
pub fn wait_for_signal(name: &str, timeout_seconds: default!(Option<i32>, "NULL")) -> String {
    if name.is_empty() {
        pgrx::error!("Signal name cannot be empty");
    }

    if let Some(timeout) = timeout_seconds {
        if timeout <= 0 {
            pgrx::error!("Timeout must be positive");
        }
    }

    let config = serde_json::json!({
        "signal_name": name,
        "timeout_seconds": timeout_seconds
    });

    Durofut {
        node_type: "SIGNAL".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Send a signal to a running durable function instance.
///
/// # Arguments
/// * `instance_id` - The durable function instance ID to signal
/// * `signal_name` - Name of the signal (must match what the instance is waiting for)
/// * `signal_data` - JSON payload to send with the signal (defaults to '{}')
///
/// # Returns
/// 'OK' on success, raises error on failure
#[pg_extern(schema = "df")]
pub fn signal(instance_id: &str, signal_name: &str, signal_data: default!(&str, "'{}'")) -> String {
    use crate::client::raise_external_event;

    if instance_id.is_empty() {
        pgrx::error!("Instance ID cannot be empty");
    }

    if signal_name.is_empty() {
        pgrx::error!("Signal name cannot be empty");
    }

    // Validate signal_data is valid JSON
    if serde_json::from_str::<serde_json::Value>(signal_data).is_err() {
        pgrx::error!("Signal data must be valid JSON");
    }

    match raise_external_event(instance_id, signal_name, signal_data) {
        Ok(_) => "OK".to_string(),
        Err(e) => pgrx::error!("Failed to send signal: {}", e),
    }
}

// ============================================================================
// Orchestration Control Functions
// ============================================================================

/// Starts a durable SQL function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Variables from df.vars are captured and passed to the orchestration.
/// Optional database parameter targets a specific database on the cluster.
#[pg_extern(schema = "df")]
pub fn start(
    fut: &str,
    label: default!(Option<&str>, "NULL"),
    database: default!(Option<&str>, "NULL"),
) -> String {
    let durofut = match Durofut::ensure_strict(fut) {
        Ok(d) => d,
        Err(e) => pgrx::error!("Invalid durable function: {}", e),
    };

    // Validate the entire graph recursively before inserting
    if let Err(e) = durofut.validate_recursive() {
        pgrx::error!("Invalid durable function graph: {}", e);
    }
    let instance_id = short_id();

    // Validate that the target database exists (if specified)
    if let Some(db) = database {
        let exists: bool = match Spi::get_one(&format!(
            "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname = '{}')",
            db.replace('\'', "''")
        )) {
            Ok(Some(v)) => v,
            Ok(None) => false,
            Err(e) => pgrx::error!("failed to check database existence: {}", e),
        };
        if !exists {
            pgrx::error!("database \"{}\" does not exist", db);
        }
    }

    // Capture user identity for privilege isolation
    let session_user_oid = unsafe { pgrx::pg_sys::GetSessionUserId() };
    let outer_user_oid = unsafe { pgrx::pg_sys::GetOuterUserId() };

    let label_sql = label
        .map(|l| format!("'{}'", l.replace('\'', "''")))
        .unwrap_or_else(|| "NULL".to_string());

    let outer_oid_u32: u32 = outer_user_oid.into();
    let session_oid_u32: u32 = session_user_oid.into();

    // Insert all nodes from the nested graph into df.nodes, returning root node ID
    fn insert_nodes(
        node: &Durofut,
        instance_id: &str,
        outer_user_oid: u32,
        session_user_oid: u32,
        database: Option<&str>,
    ) -> String {
        let node_id = short_id();

        // Recursively insert children FIRST to get their IDs
        let left_id = node
            .left_node
            .as_ref()
            .map(|n| insert_nodes(n, instance_id, outer_user_oid, session_user_oid, database));
        let right_id = node
            .right_node
            .as_ref()
            .map(|n| insert_nodes(n, instance_id, outer_user_oid, session_user_oid, database));

        // Process config JSON to recursively insert embedded nodes and get their IDs
        let query_escaped = match node.transform_config_children(|child| {
            Ok(insert_nodes(
                child,
                instance_id,
                outer_user_oid,
                session_user_oid,
                database,
            ))
        }) {
            Ok(Some(updated_query)) => {
                format!("'{}'", updated_query.replace('\'', "''"))
            }
            Ok(None) => "NULL".to_string(),
            Err(e) => pgrx::error!("Invalid config in {} node: {}", node.node_type, e),
        };

        let result_name_escaped = node
            .result_name
            .as_ref()
            .map(|n| format!("'{}'", n.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());

        let left_node_escaped = left_id
            .as_ref()
            .map(|id| format!("'{id}'"))
            .unwrap_or_else(|| "NULL".to_string());

        let right_node_escaped = right_id
            .as_ref()
            .map(|id| format!("'{id}'"))
            .unwrap_or_else(|| "NULL".to_string());

        let database_escaped = database
            .map(|db| format!("'{}'", db.replace('\'', "''")))
            .unwrap_or_else(|| "NULL".to_string());

        // Insert this node with the generated ID
        let insert_sql = format!(
            "INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, database)
             VALUES ('{}', '{}', '{}', {}, {}, {}, {}, {}::oid::regrole, {}::oid::regrole, {})",
            node_id,
            instance_id,
            node.node_type.replace('\'', "''"),
            query_escaped,
            result_name_escaped,
            left_node_escaped,
            right_node_escaped,
            outer_user_oid,
            session_user_oid,
            database_escaped
        );

        if let Err(e) = Spi::run(&insert_sql) {
            pgrx::error!("Failed to insert node {}: {:?}", node_id, e);
        }

        // Return the generated ID for parent to reference
        node_id
    }

    let root_node_id = insert_nodes(
        &durofut,
        &instance_id,
        outer_oid_u32,
        session_oid_u32,
        database,
    );

    let database_sql = database
        .map(|db| format!("'{}'", db.replace('\'', "''")))
        .unwrap_or_else(|| "NULL".to_string());

    // Create instance record with root node ID
    let create_instance_sql = format!(
        "INSERT INTO df.instances (id, label, root_node, status, submitted_by, login_role, database) VALUES ('{}', {}, '{}', 'pending', {}::oid::regrole, {}::oid::regrole, {})",
        instance_id,
        label_sql,
        root_node_id,
        outer_oid_u32,
        session_oid_u32,
        database_sql
    );

    if let Err(e) = Spi::run(&create_instance_sql) {
        pgrx::error!("Failed to create instance: {:?}", e);
    }

    // Capture vars from df.vars table
    let vars: std::collections::HashMap<String, String> = Spi::connect(|client| {
        let mut vars = std::collections::HashMap::new();
        if let Ok(table) = client.select("SELECT name, value FROM df.vars", None, &[]) {
            for row in table {
                if let (Ok(Some(name)), Ok(Some(value))) =
                    (row.get::<String>(1), row.get::<String>(2))
                {
                    vars.insert(name, value);
                }
            }
        }
        vars
    });

    // Start the orchestration via duroxide
    let input = FunctionInput {
        instance_id: instance_id.clone(),
        label: label.map(|s| s.to_string()),
        vars,
    };
    let input_json = serde_json::to_string(&input).unwrap_or(instance_id.clone());

    if let Err(e) = start_durable_function(
        crate::orchestrations::execute_function_graph::NAME,
        &instance_id,
        &input_json,
    ) {
        pgrx::log!(
            "pg_durable: Warning - failed to start durable function: {}",
            e
        );
    }

    instance_id
}

/// Cancels a running durable function.
#[pg_extern(schema = "df")]
pub fn cancel(instance_id: &str, reason: default!(&str, "'Cancelled by user'")) -> String {
    use crate::client::cancel_durable_function;

    if let Err(e) = cancel_durable_function(instance_id, reason) {
        return format!("Failed to cancel: {e}");
    }

    let update_sql = format!(
        "UPDATE df.instances SET status = 'cancelled', updated_at = now() WHERE id = '{instance_id}'"
    );
    let _ = Spi::run(&update_sql);

    format!("Instance {instance_id} cancelled: {reason}")
}

/// Gets the status of a durable function instance.
#[pg_extern(schema = "df")]
pub fn status(instance_id: &str) -> Option<String> {
    let sql = format!("SELECT status FROM df.instances WHERE id = '{instance_id}'");
    Spi::get_one::<String>(&sql).ok().flatten()
}

/// Manually runs pending durable functions.
#[pg_extern(schema = "df")]
pub fn run(instance_id: default!(Option<&str>, "NULL")) -> String {
    if let Some(id) = instance_id {
        format!("Triggered run for instance: {id}")
    } else {
        "Triggered run for all pending instances".to_string()
    }
}

/// Gets the result of a completed durable function.
#[pg_extern(schema = "df")]
pub fn result(instance_id: &str) -> Option<String> {
    let sql = format!(
        r#"SELECT result::text FROM df.nodes 
           WHERE id = (SELECT root_node FROM df.instances WHERE id = '{instance_id}')
           AND status = 'completed'"#
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}

/// Waits for a durable function to complete, returning its final status.
/// Polls the instance status every 100ms until it reaches a terminal state
/// (completed, failed, or cancelled) or the timeout is exceeded.
///
/// This is a helper function for pg_regress tests to simplify polling logic
/// and ensure deterministic test output.
///
/// # Arguments
/// * `instance_id` - The durable function instance ID to wait for
/// * `timeout_seconds` - Maximum time to wait in seconds (default: 30)
///
/// # Returns
/// The final status as a string: 'completed', 'failed', or 'cancelled'
///
/// # Errors
/// Raises an error if the timeout is exceeded without reaching a terminal state
#[pg_extern(schema = "df")]
pub fn wait_for_completion(
    instance_id: &str,
    timeout_seconds: default!(i32, "30"),
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    if timeout_seconds <= 0 {
        pgrx::error!("Timeout must be positive");
    }

    let max_attempts = timeout_seconds * 10; // Poll every 100ms
    let mut attempts = 0;

    loop {
        // Query instance status
        let sql = format!(
            "SELECT status FROM df.instances WHERE id = '{}'",
            instance_id.replace('\'', "''")
        );

        let status: Option<String> =
            Spi::get_one(&sql).map_err(|e| format!("Failed to query status: {:?}", e))?;

        if let Some(ref s) = status {
            let s_lower = s.to_lowercase();
            if s_lower == "completed" || s_lower == "failed" || s_lower == "cancelled" {
                return Ok(s_lower);
            }
        } else {
            return Err(format!("Instance not found: {}", instance_id).into());
        }

        attempts += 1;
        if attempts >= max_attempts {
            return Err(format!(
                "Timeout after {}s waiting for instance {} (status: {}). Check if background worker is running.",
                timeout_seconds,
                instance_id,
                status.unwrap_or_else(|| "unknown".to_string())
            )
            .into());
        }

        // Sleep 100ms
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}
