//! Metric emitter trait definition
//!
//! This module defines the core abstraction for emitting metrics to various backends.

use std::collections::HashMap;

/// Trait for emitting metrics to a backend
pub trait MetricEmitter: Send + Sync {
    /// Emit a gauge metric (current value)
    ///
    /// # Arguments
    /// * `name` - Metric name (e.g., "pg_durable.instances.started")
    /// * `value` - Current value to emit
    /// * `dimensions` - Key-value pairs for dimensions/tags (always includes at least "version")
    fn emit_gauge(&self, name: &str, value: i64, dimensions: &HashMap<String, String>);
}
