//! Telemetry module for periodic metrics publishing
//!
//! This module provides a modular system for emitting pg_durable metrics to various backends:
//! - Noop/log (default): Logs metrics to PostgreSQL log
//! - StatsD (feature: telemetry-statsd): Emits to StatsD-compatible server via UDP
//! - MDM/Geneva (feature: telemetry-mdm): Emits to Azure MDM via UDP
//!
//! Metrics are published as gauges every 5 seconds by the background worker.

pub mod adapter;
pub mod noop;

#[cfg(feature = "telemetry-statsd")]
pub mod statsd;

#[cfg(feature = "telemetry-mdm")]
pub mod mdm;

use adapter::MetricEmitter;
use duroxide::Client;
use noop::NoopEmitter;
use pgrx::prelude::*;
use std::collections::HashMap;
use std::sync::Arc;

#[cfg(feature = "telemetry-statsd")]
use statsd::StatsdEmitter;

#[cfg(feature = "telemetry-mdm")]
use mdm::MdmEmitter;

/// Initialize metric emitters based on enabled features
pub fn create_emitters() -> Vec<Box<dyn MetricEmitter>> {
    let mut emitters: Vec<Box<dyn MetricEmitter>> = Vec::new();

    // Always include noop/log emitter (default)
    emitters.push(Box::new(NoopEmitter::new()));

    // Add StatsD emitter if feature is enabled
    #[cfg(feature = "telemetry-statsd")]
    {
        match StatsdEmitter::new("127.0.0.1", 8125, "pg_durable") {
            Ok(emitter) => {
                log!("pg_durable: StatsD telemetry enabled");
                emitters.push(Box::new(emitter));
            }
            Err(e) => {
                log!("pg_durable: Failed to initialize StatsD emitter: {}", e);
            }
        }
    }

    // Add MDM emitter if feature is enabled
    #[cfg(feature = "telemetry-mdm")]
    {
        match MdmEmitter::new("127.0.0.1", 8186, "pg_durable_account", "pg_durable") {
            Ok(emitter) => {
                log!("pg_durable: MDM telemetry enabled");
                emitters.push(Box::new(emitter));
            }
            Err(e) => {
                log!("pg_durable: Failed to initialize MDM emitter: {}", e);
            }
        }
    }

    emitters
}

/// Publish metrics using the Duroxide client
///
/// Fetches system metrics from Duroxide and emits them to all configured backends.
/// Always includes a "version" dimension.
pub async fn publish_metrics(client: &Client, emitters: &[Box<dyn MetricEmitter>]) {
    // Get metrics from Duroxide
    let metrics = match client.get_system_metrics().await {
        Ok(m) => m,
        Err(e) => {
            log!("pg_durable: Failed to get system metrics: {}", e);
            return;
        }
    };

    // Prepare dimensions (always include version)
    let mut dimensions = HashMap::new();
    dimensions.insert("version".to_string(), env!("CARGO_PKG_VERSION").to_string());

    // Emit each metric as a gauge
    let metric_values = [
        ("pg_durable.instances.started", metrics.total_instances as i64),
        ("pg_durable.instances.completed", metrics.completed_instances as i64),
        ("pg_durable.instances.failed", metrics.failed_instances as i64),
    ];

    for (name, value) in &metric_values {
        for emitter in emitters {
            emitter.emit_gauge(name, *value, &dimensions);
        }
    }
}

/// Start the metrics publishing loop
///
/// This function runs indefinitely, publishing metrics every 5 seconds until
/// the shutdown signal is received.
pub async fn start_metrics_loop(
    client: Arc<Client>,
    emitters: Vec<Box<dyn MetricEmitter>>,
    shutdown_check: impl Fn() -> bool,
) {
    log!("pg_durable: Starting metrics publishing loop (interval: 5 seconds)");

    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));

    loop {
        interval.tick().await;

        // Check for shutdown
        if shutdown_check() {
            log!("pg_durable: Metrics publishing loop shutting down");
            break;
        }

        // Publish metrics
        publish_metrics(&client, &emitters).await;
    }
}
