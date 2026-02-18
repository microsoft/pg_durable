//! Noop/log backend for metrics
//!
//! This backend logs metrics to PostgreSQL log for development and testing.

use super::adapter::MetricEmitter;
use pgrx::prelude::*;
use std::collections::HashMap;

/// Noop emitter that logs metrics to PostgreSQL log
pub struct NoopEmitter;

impl NoopEmitter {
    pub fn new() -> Self {
        NoopEmitter
    }
}

impl MetricEmitter for NoopEmitter {
    fn emit_gauge(&self, name: &str, value: i64, dimensions: &HashMap<String, String>) {
        // Format dimensions as key=value pairs
        let dims: Vec<String> = dimensions
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect();
        let dims_str = if dims.is_empty() {
            String::new()
        } else {
            format!(" [{}]", dims.join(", "))
        };

        log!("METRIC: {} = {}{}", name, value, dims_str);
    }
}
