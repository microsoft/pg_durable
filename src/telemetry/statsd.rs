//! StatsD backend for metrics using cadence
//!
//! This backend emits metrics to a StatsD-compatible server over UDP.

use super::adapter::MetricEmitter;
use cadence::prelude::*;
use cadence::{StatsdClient, UdpMetricSink};
use pgrx::prelude::*;
use std::collections::HashMap;
use std::net::UdpSocket;

/// StatsD emitter using cadence
pub struct StatsdEmitter {
    client: StatsdClient,
}

impl StatsdEmitter {
    /// Create a new StatsD emitter
    ///
    /// # Arguments
    /// * `host` - StatsD server host (e.g., "127.0.0.1")
    /// * `port` - StatsD server port (e.g., 8125)
    /// * `prefix` - Metric prefix (e.g., "pg_durable")
    pub fn new(host: &str, port: u16, prefix: &str) -> Result<Self, String> {
        let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("UDP bind failed: {}", e))?;
        socket
            .set_nonblocking(true)
            .map_err(|e| format!("Set nonblocking failed: {}", e))?;

        let sink = UdpMetricSink::from((host, port), socket)
            .map_err(|e| format!("Sink creation failed: {}", e))?;

        let client = StatsdClient::from_sink(prefix, sink);

        log!(
            "pg_durable: StatsD emitter initialized at {}:{} with prefix '{}'",
            host,
            port,
            prefix
        );
        Ok(StatsdEmitter { client })
    }
}

impl MetricEmitter for StatsdEmitter {
    fn emit_gauge(&self, name: &str, value: i64, dimensions: &HashMap<String, String>) {
        // Format: JSON key (Account/Namespace/Metric/Dims), value, type=gauge
        // Encode dimensions as part of the metric name for StatsD compatibility
        let mut metric_name = name.to_string();

        // Add dimensions to metric name (StatsD/DogStatsD format with tags)
        if !dimensions.is_empty() {
            let tags: Vec<String> = dimensions
                .iter()
                .map(|(k, v)| format!("{}:{}", k, v))
                .collect();
            metric_name = format!("{}.{}", metric_name, tags.join("."));
        }

        if let Err(e) = self.client.gauge(&metric_name, value) {
            log!("pg_durable: StatsD emit error for {}: {}", name, e);
        }
    }
}
