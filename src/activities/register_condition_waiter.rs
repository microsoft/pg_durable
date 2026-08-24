// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! RegisterConditionWaiter activity - records a node blocked in
//! `df.wait_for_condition()` so the worker's NOTIFY listener can wake it.
//!
//! A row exists only while a wait carrying a `notify_key` is outstanding. A
//! wait without a key registers nothing and relies purely on its interval.
//!
//! The insert is idempotent (`ON CONFLICT DO NOTHING` on the primary key), so
//! duroxide's at-least-once activity execution is harmless.

use duroxide::ActivityContext;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::register-condition-waiter";

/// Input for the register/unregister condition waiter activities.
#[derive(Debug, Serialize, Deserialize)]
pub struct ConditionWaiterInput {
    /// The duroxide instance id (`ctx.instance_id()`), which for a node inside
    /// a loop body is a composite subtree id, not the 8-char df instance id.
    pub instance_id: String,
    pub node_id: String,
    /// Only set on register; unregister deletes by primary key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify_key: Option<String>,
}

/// Process-global cache for whether `df.condition_waiters` exists.
///
/// 0 = unknown, 1 = present, 2 = absent. The table is added by the
/// 0.2.5 → 0.2.6 upgrade; a binary newer than the schema (Scenario B1) must run
/// against an older schema that lacks it. We cache "present" permanently once
/// seen, but re-probe on "unknown"/"absent" so an in-place ALTER EXTENSION
/// UPDATE that adds the table is picked up without a worker restart.
static WAITERS_TABLE: AtomicU8 = AtomicU8::new(0);

pub(crate) async fn waiters_table_present(pool: &PgPool) -> bool {
    if WAITERS_TABLE.load(Ordering::Relaxed) == 1 {
        return true;
    }
    let present = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables \
         WHERE table_schema = 'df' AND table_name = 'condition_waiters')",
    )
    .fetch_one(pool)
    .await
    .unwrap_or(false);
    WAITERS_TABLE.store(if present { 1 } else { 2 }, Ordering::Relaxed);
    present
}

pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: ConditionWaiterInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid register_condition_waiter input: {e}"))?;

    let notify_key = match input.notify_key {
        Some(k) => k,
        None => return Ok("{}".to_string()),
    };

    // Missing table means the .so is newer than the schema. The interval
    // backstop still fires, so degrade to polling rather than failing the node.
    if !waiters_table_present(&pool).await {
        ctx.trace_info(
            "df.condition_waiters is absent (schema predates 0.2.6); \
             condition wait will rely on max_check_interval only",
        );
        return Ok("{}".to_string());
    }

    sqlx::query(
        "INSERT INTO df.condition_waiters (instance_id, node_id, notify_key) \
         VALUES ($1, $2, $3) ON CONFLICT (instance_id, node_id) DO NOTHING",
    )
    .bind(&input.instance_id)
    .bind(&input.node_id)
    .bind(&notify_key)
    .execute(&*pool)
    .await
    .map_err(|e| format!("Failed to register condition waiter: {e}"))?;

    ctx.trace_info(format!(
        "Registered condition waiter {}/{} on key '{}'",
        input.instance_id, input.node_id, notify_key
    ));

    Ok("{}".to_string())
}
