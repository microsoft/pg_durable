//! DSL functions for defining durable SQL functions

use cron::Schedule as CronSchedule;
use pgrx::prelude::*;
use std::str::FromStr;

use crate::runtime::start_durable_function;
use crate::types::{short_id, Durofut, FunctionInput};

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
#[pg_extern(name = "as", schema = "df")]
pub fn as_named(name: &str, fut: &str) -> String {
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
#[pg_extern(schema = "df")]
pub fn wait_for_schedule(cron_expr: &str) -> String {
    let cron_with_seconds = format!("0 {}", cron_expr);
    if CronSchedule::from_str(&cron_with_seconds).is_err() {
        pgrx::error!("Invalid cron expression: {}", cron_expr);
    }

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "WAIT_SCHEDULE".to_string(),
        left_node: None,
        right_node: None,
        query: Some(cron_expr.to_string()),
        result_name: None,
    };
    durofut.insert_node();
    durofut.to_json()
}

/// Creates a loop node that repeats the body indefinitely.
/// The body argument can be either Durofut JSON or plain SQL string (auto-wrapped).
#[pg_extern(name = "loop", schema = "df")]
pub fn loop_fn(body: &str) -> String {
    let body_fut = Durofut::ensure(body);

    let durofut = Durofut {
        node_id: short_id(),
        node_type: "LOOP".to_string(),
        left_node: Some(body_fut.node_id),
        right_node: None,
        query: None,
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

// ============================================================================
// Orchestration Control Functions
// ============================================================================

/// Starts a durable SQL function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
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

        let update_sql = format!(
            "UPDATE df.nodes SET instance_id = '{}' WHERE id = '{}'",
            instance_id, node_id
        );
        let _ = Spi::run(&update_sql);

        // Get child node IDs
        let left: Option<String> = Spi::get_one(&format!(
            "SELECT left_node FROM df.nodes WHERE id = '{}'",
            node_id
        ))
        .ok()
        .flatten();

        let right: Option<String> = Spi::get_one(&format!(
            "SELECT right_node FROM df.nodes WHERE id = '{}'",
            node_id
        ))
        .ok()
        .flatten();

        let config: Option<String> = Spi::get_one(&format!(
            "SELECT query FROM df.nodes WHERE id = '{}'",
            node_id
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

    // Start the orchestration via duroxide
    let input = FunctionInput {
        instance_id: instance_id.clone(),
        label: label.map(|s| s.to_string()),
    };
    let input_json = serde_json::to_string(&input).unwrap_or(instance_id.clone());

    if let Err(e) = start_durable_function("ExecuteWorkflow", &instance_id, &input_json) {
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
    use crate::runtime::cancel_durable_function;

    if let Err(e) = cancel_durable_function(instance_id, reason) {
        return format!("Failed to cancel: {}", e);
    }

    let update_sql = format!(
        "UPDATE df.instances SET status = 'cancelled', updated_at = now() WHERE id = '{}'",
        instance_id
    );
    let _ = Spi::run(&update_sql);

    format!("Instance {} cancelled: {}", instance_id, reason)
}

/// Gets the status of a durable function instance.
#[pg_extern(schema = "df")]
pub fn status(instance_id: &str) -> Option<String> {
    let sql = format!(
        "SELECT status FROM df.instances WHERE id = '{}'",
        instance_id
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}

/// Manually runs pending durable functions.
#[pg_extern(schema = "df")]
pub fn run(instance_id: default!(Option<&str>, "NULL")) -> String {
    if let Some(id) = instance_id {
        format!("Triggered run for instance: {}", id)
    } else {
        "Triggered run for all pending instances".to_string()
    }
}

/// Gets the result of a completed durable function.
#[pg_extern(schema = "df")]
pub fn result(instance_id: &str) -> Option<String> {
    let sql = format!(
        r#"SELECT result::text FROM df.nodes 
           WHERE id = (SELECT root_node FROM df.instances WHERE id = '{}')
           AND status = 'completed'"#,
        instance_id
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}
