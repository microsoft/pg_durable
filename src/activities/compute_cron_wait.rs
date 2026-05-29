//! ComputeCronWait activity - computes remaining seconds until a target timestamp
//!
//! This activity is called by the WAIT_SCHEDULE orchestration node with a
//! pre-captured target timestamp (the next cron tick). It computes
//! `max(0, target - now())` at actual execution time, which correctly accounts
//! for any delay between `df.start()` and when the background worker processes
//! the WAIT_SCHEDULE node.
//!
//! Using an activity for this I/O (reading the wall clock) keeps the
//! orchestration itself deterministic, as required by duroxide replay safety.

use chrono::{DateTime, Utc};
use duroxide::ActivityContext;
use serde::{Deserialize, Serialize};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::compute-cron-wait";

/// Input for the compute_cron_wait activity
#[derive(Debug, Serialize, Deserialize)]
pub struct ComputeCronWaitInput {
    /// RFC 3339 timestamp of the next cron tick, captured at DSL time
    pub target_timestamp: String,
    /// Original cron expression, used only for tracing
    pub cron_expr: String,
}

/// Output for the compute_cron_wait activity
#[derive(Debug, Serialize, Deserialize)]
pub struct ComputeCronWaitOutput {
    /// Seconds remaining until the target timestamp (clamped to 0 if in the past)
    pub wait_seconds: u64,
}

/// Compute the number of seconds to wait until the target timestamp.
///
/// The target was captured at DSL time; the actual remaining duration is
/// measured here, at activity-execution time, so the timer is always correct
/// even if there was a delay between `df.start()` and when the worker ran.
pub async fn execute(ctx: ActivityContext, input_json: String) -> Result<String, String> {
    let input: ComputeCronWaitInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid compute_cron_wait input: {e}"))?;

    let target: DateTime<Utc> = input
        .target_timestamp
        .parse()
        .map_err(|e| format!("Invalid target_timestamp '{}' (expected RFC 3339): {e}", input.target_timestamp))?;

    let now = Utc::now();
    let wait_seconds = (target - now).num_seconds().max(0) as u64;

    ctx.trace_info(format!(
        "compute_cron_wait: cron='{}', target={}, now={}, wait={}s",
        input.cron_expr,
        input.target_timestamp,
        now.to_rfc3339(),
        wait_seconds
    ));

    let output = ComputeCronWaitOutput { wait_seconds };
    serde_json::to_string(&output).map_err(|e| format!("Failed to serialize output: {e}"))
}
