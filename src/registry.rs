//! Registry builders for activities and orchestrations

use std::sync::Arc;

use duroxide::{runtime::registry::ActivityRegistry, ActivityContext, OrchestrationRegistry};
use sqlx::PgPool;
use tokio::sync::Semaphore;

use crate::activities;
use crate::orchestrations;

/// Create the activity registry with all registered activities
pub fn create_activity_registry(pool: Arc<PgPool>, semaphore: Arc<Semaphore>) -> ActivityRegistry {
    let sql_semaphore = semaphore;
    let graph_pool = pool.clone();
    let status_pool = pool.clone();
    let node_status_pool = pool.clone();

    ActivityRegistry::builder()
        .register(activities::execute_sql::NAME, move |ctx: ActivityContext, input_json: String| {
            let sem = sql_semaphore.clone();
            async move { activities::execute_sql::execute(ctx, sem, input_json).await }
        })
        .register(activities::load_function_graph::NAME, move |ctx: ActivityContext, instance_id: String| {
            let pool = graph_pool.clone();
            async move { activities::load_function_graph::execute(ctx, pool, instance_id).await }
        })
        .register(activities::update_instance_status::NAME, move |ctx: ActivityContext, input_json: String| {
            let pool = status_pool.clone();
            async move { activities::update_instance_status::execute(ctx, pool, input_json).await }
        })
        .register(activities::update_node_status::NAME, move |ctx: ActivityContext, input_json: String| {
            let pool = node_status_pool.clone();
            async move { activities::update_node_status::execute(ctx, pool, input_json).await }
        })
        .register(activities::execute_http::NAME, |ctx: ActivityContext, config_json: String| {
            async move { activities::execute_http::execute(ctx, config_json).await }
        })
        .build()
}

/// Create the orchestration registry with all registered orchestrations
pub fn create_orchestration_registry() -> OrchestrationRegistry {
    OrchestrationRegistry::builder()
        .register(
            orchestrations::execute_function_graph::NAME,
            orchestrations::execute_function_graph::execute,
        )
        .register(
            orchestrations::execute_function_graph::SUBTREE_NAME,
            orchestrations::execute_function_graph::execute_subtree,
        )
        .build()
}
