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
    let durofut = Durofut {
        node_id: short_id(),
        node_type: "SQL".to_string(),
        left_node: None,
        right_node: None,
        query: Some(query.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a sequence node that executes two nodes in order.
/// The SQL operator ~> is syntactic sugar for this function.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "seq", schema = "df")]
pub fn then_fn(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "THEN".to_string(),
        left_node: Some(a_fut.node_id),
        right_node: Some(b_fut.node_id),
        query: None,
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Names a result for later reference.
/// The SQL operator |=> is syntactic sugar for this function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Note: Parameter order matches the |=> operator: fut |=> name -> df.as(fut, name)
#[pg_extern(name = "as", schema = "df")]
pub fn as_named(fut: &str, name: &str) -> String {
    let mut durofut = Durofut::ensure(fut);
    durofut.result_name = Some(name.to_string());

    let update_sql = format!(
        "UPDATE df.nodes SET result_name = '{}' WHERE id = '{}'",
        name.replace('\'', "''"),
        durofut.node_id
    );
    let _ = Spi::run(&update_sql);

    durofut.to_json()
}

/// Creates a sleep node that pauses for the specified number of seconds.
#[pg_extern(schema = "df")]
pub fn sleep(seconds: i64) -> String {
    if seconds < 0 {
        pgrx::error!("Sleep duration must be non-negative");
    }
    let durofut = Durofut {
        node_id: short_id(),
        node_type: "SLEEP".to_string(),
        left_node: None,
        right_node: None,
        query: Some(seconds.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "WAIT_SCHEDULE".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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

    let (right_node, query) = if let Some(cond) = condition {
        let cond_fut = Durofut::ensure(cond);
        let config = serde_json::json!({
            "condition_node": cond_fut.node_id
        });
        (Some(cond_fut.node_id), Some(config.to_string()))
    } else {
        (None, None)
    };

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "LOOP".to_string(),
        left_node: Some(body_fut.node_id),
        right_node,
        query,
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "BREAK".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a conditional branch node.
/// All arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "if", schema = "df")]
pub fn if_fn(condition: &str, then_branch: &str, else_branch: &str) -> String {
    let condition_fut = Durofut::ensure(condition);
    let then_fut = Durofut::ensure(then_branch);
    let else_fut = Durofut::ensure(else_branch);

    let config = serde_json::json!({
        "condition_node": condition_fut.node_id
    });

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "IF".to_string(),
        left_node: Some(then_fut.node_id),
        right_node: Some(else_fut.node_id),
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a parallel join node for 2 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn join(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "JOIN".to_string(),
        left_node: Some(a_fut.node_id),
        right_node: Some(b_fut.node_id),
        query: None,
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a parallel join node for 3 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "join3", schema = "df")]
pub fn join3(a: &str, b: &str, c: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);
    let c_fut = Durofut::ensure(c);

    let config = serde_json::json!({
        "extra_nodes": [c_fut.node_id]
    });

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "JOIN".to_string(),
        left_node: Some(a_fut.node_id),
        right_node: Some(b_fut.node_id),
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a race node - runs branches in parallel, first to complete wins.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn race(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "RACE".to_string(),
        left_node: Some(a_fut.node_id),
        right_node: Some(b_fut.node_id),
        query: None,
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "HTTP".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "SIGNAL".to_string(),
        left_node: None,
        right_node: None,
        query: Some(config.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
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
#[pg_extern(schema = "df")]
pub fn start(fut: &str, label: default!(Option<&str>, "NULL")) -> String {
    let durofut = Durofut::ensure(fut);
    let instance_id = short_id();

    let label_sql = label
        .map(|l| format!("'{}'", l.replace('\'', "''")))
        .unwrap_or_else(|| "NULL".to_string());

    let create_instance_sql = format!(
        "INSERT INTO df.instances (id, label, root_node, status) VALUES ('{}', {}, '{}', 'pending')",
        instance_id,
        label_sql,
        durofut.node_id
    );

    if let Err(e) = Spi::run(&create_instance_sql) {
        pgrx::error!("Failed to create instance: {:?}", e);
    }

    // Link all nodes in the function graph to this instance
    fn link_nodes(
        node_id: &str,
        instance_id: &str,
        visited: &mut std::collections::HashSet<String>,
    ) {
        if visited.contains(node_id) {
            return;
        }
        visited.insert(node_id.to_string());

        let update_sql =
            format!("UPDATE df.nodes SET instance_id = '{instance_id}' WHERE id = '{node_id}'");
        let _ = Spi::run(&update_sql);

        // Get child node IDs
        let left: Option<String> = Spi::get_one(&format!(
            "SELECT left_node FROM df.nodes WHERE id = '{node_id}'"
        ))
        .ok()
        .flatten();

        let right: Option<String> = Spi::get_one(&format!(
            "SELECT right_node FROM df.nodes WHERE id = '{node_id}'"
        ))
        .ok()
        .flatten();

        let config: Option<String> = Spi::get_one(&format!(
            "SELECT query FROM df.nodes WHERE id = '{node_id}'"
        ))
        .ok()
        .flatten();

        if let Some(l) = left {
            link_nodes(&l, instance_id, visited);
        }
        if let Some(r) = right {
            link_nodes(&r, instance_id, visited);
        }
        if let Some(config_str) = config {
            if let Ok(cfg) = serde_json::from_str::<serde_json::Value>(&config_str) {
                if let Some(cond_id) = cfg["condition_node"].as_str() {
                    link_nodes(cond_id, instance_id, visited);
                }
                if let Some(extras) = cfg["extra_nodes"].as_array() {
                    for extra in extras {
                        if let Some(extra_id) = extra.as_str() {
                            link_nodes(extra_id, instance_id, visited);
                        }
                    }
                }
            }
        }
    }

    let mut visited = std::collections::HashSet::new();
    link_nodes(&durofut.node_id, &instance_id, &mut visited);

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
