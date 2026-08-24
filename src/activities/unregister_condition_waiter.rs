// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! UnregisterConditionWaiter activity - removes the row written by
//! [`crate::activities::register_condition_waiter`] once the predicate is true.
//!
//! Deleting by primary key is idempotent, so a replayed or duplicated execution
//! is harmless.

use duroxide::ActivityContext;
use sqlx::PgPool;
use std::sync::Arc;

use super::register_condition_waiter::{waiters_table_present, ConditionWaiterInput};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::unregister-condition-waiter";

pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: ConditionWaiterInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid unregister_condition_waiter input: {e}"))?;

    if !waiters_table_present(&pool).await {
        return Ok("{}".to_string());
    }

    sqlx::query("DELETE FROM df.condition_waiters WHERE instance_id = $1 AND node_id = $2")
        .bind(&input.instance_id)
        .bind(&input.node_id)
        .execute(&*pool)
        .await
        .map_err(|e| format!("Failed to unregister condition waiter: {e}"))?;

    ctx.trace_info(format!(
        "Unregistered condition waiter {}/{}",
        input.instance_id, input.node_id
    ));

    Ok("{}".to_string())
}
