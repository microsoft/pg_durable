//! Client operations for user session calls — SPI-based
//!
//! This module provides direct SPI-based calls for df.start(), df.signal(),
//! and df.cancel(). Operations are executed synchronously within the current
//! PostgreSQL backend process — no TCP connections, no async runtime, no
//! connection pools.
//!
//! All operations enqueue WorkItems to the duroxide orchestrator queue via
//! the `duroxide.enqueue_orchestrator_work()` stored procedure.

use pgrx::prelude::*;

use crate::types::DUROXIDE_SCHEMA;

/// Enqueue a WorkItem to the duroxide orchestrator queue via SPI.
///
/// This is the core primitive used by start/cancel/signal operations.
/// It calls the `duroxide.enqueue_orchestrator_work()` stored procedure
/// that was installed as part of `CREATE EXTENSION pg_durable`.
fn enqueue_orchestrator_work(instance_id: &str, work_item_json: &str) -> Result<(), String> {
    let safe_id = instance_id.replace('\'', "''");
    let safe_json = work_item_json.replace('\'', "''");

    let sql = format!(
        "SELECT {DUROXIDE_SCHEMA}.enqueue_orchestrator_work(\
         '{safe_id}', '{safe_json}', NOW(), \
         (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT)"
    );

    Spi::connect(|client| {
        client
            .select(&sql, None, &[])
            .map_err(|e| format!("Failed to enqueue work item: {e:?}"))?;
        Ok(())
    })
}

/// Start a durable function by enqueuing a StartOrchestration work item.
///
/// This directly inserts into the duroxide orchestrator queue via SPI,
/// bypassing the need for any async runtime or TCP connection.
pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    log!(
        "pg_durable: start_durable_function for instance {}",
        instance_id
    );

    // Build the WorkItem::StartOrchestration JSON (serde externally-tagged format)
    let work_item = serde_json::json!({
        "StartOrchestration": {
            "instance": instance_id,
            "orchestration": function_name,
            "input": input,
            "version": null,
            "parent_instance": null,
            "parent_id": null,
            "execution_id": 1
        }
    });

    enqueue_orchestrator_work(instance_id, &work_item.to_string())
}

/// Cancel a durable function by enqueuing a CancelInstance work item.
pub fn cancel_durable_function(instance_id: &str, reason: &str) -> Result<(), String> {
    let work_item = serde_json::json!({
        "CancelInstance": {
            "instance": instance_id,
            "reason": reason
        }
    });

    enqueue_orchestrator_work(instance_id, &work_item.to_string())
}

/// Raise an external event (signal) to a running orchestration.
pub fn raise_external_event(
    instance_id: &str,
    event_name: &str,
    data: &str,
) -> Result<(), String> {
    let work_item = serde_json::json!({
        "ExternalRaised": {
            "instance": instance_id,
            "name": event_name,
            "data": data
        }
    });

    enqueue_orchestrator_work(instance_id, &work_item.to_string())
}
