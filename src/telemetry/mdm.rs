//! MDM/Geneva backend for metrics
//!
//! This backend emits metrics to Azure MDM (Geneva) over UDP using manual datagram formatting.

use super::adapter::MetricEmitter;
use pgrx::prelude::*;
use serde_json::json;
use std::collections::HashMap;
use std::net::UdpSocket;

/// MDM/Geneva emitter
pub struct MdmEmitter {
    socket: UdpSocket,
    endpoint: String,
    account: String,
    namespace: String,
}

impl MdmEmitter {
    /// Create a new MDM emitter
    ///
    /// # Arguments
    /// * `host` - MDM server host (e.g., "127.0.0.1")
    /// * `port` - MDM server port (e.g., 8186)
    /// * `account` - MDM account name
    /// * `namespace` - MDM namespace
    pub fn new(host: &str, port: u16, account: &str, namespace: &str) -> Result<Self, String> {
        let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("UDP bind failed: {}", e))?;
        socket
            .set_nonblocking(true)
            .map_err(|e| format!("Set nonblocking failed: {}", e))?;

        let endpoint = format!("{}:{}", host, port);

        log!(
            "pg_durable: MDM emitter initialized at {} with account '{}', namespace '{}'",
            endpoint,
            account,
            namespace
        );

        Ok(MdmEmitter {
            socket,
            endpoint,
            account: account.to_string(),
            namespace: namespace.to_string(),
        })
    }
}

impl MetricEmitter for MdmEmitter {
    fn emit_gauge(&self, name: &str, value: i64, dimensions: &HashMap<String, String>) {
        // Format: JSON key (Account/Namespace/Metric/Dims), value, type=gauge (|g)
        // MDM expects: {"Account":"...","Namespace":"...","Metric":"...","Dims":{"key":"value"}}:value|g
        
        let metric_key = json!({
            "Account": self.account,
            "Namespace": self.namespace,
            "Metric": name,
            "Dims": dimensions
        });

        let datagram = format!("{}:{}|g", metric_key, value);

        if let Err(e) = self.socket.send_to(datagram.as_bytes(), &self.endpoint) {
            log!("pg_durable: MDM emit error for {}: {}", name, e);
        }
    }
}
