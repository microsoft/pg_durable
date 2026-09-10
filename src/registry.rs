// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

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
    let router = Arc::new(crate::origin::Router::new(pool));
    let sql_pool = router.clone();
    let graph_pool = router.clone();
    let transaction_graph_pool = router.clone();
    let status_pool = router.clone();
    let node_status_pool = router.clone();
    let http_pool = router.clone();
    let multipart_pool = router;

    ActivityRegistry::builder()
        .register(
            activities::execute_sql::NAME,
            move |ctx: ActivityContext, input_json: String| {
                let sem = sql_semaphore.clone();
                let router = sql_pool.clone();
                async move {
                    let route = router.route(ctx.instance_id()).await?;
                    let mut execution_origin = None;
                    let input_json = if let Some(database) = route.database.as_deref() {
                        let mut input: activities::execute_sql::ExecuteSqlInput =
                            serde_json::from_str(&input_json).map_err(|error| error.to_string())?;
                        if input.database.is_none() {
                            input.database = Some(database.to_string());
                        }
                        if input.database.as_deref() == Some(database) {
                            execution_origin =
                                crate::origin::Origin::from_engine_id(ctx.instance_id())?;
                        }
                        serde_json::to_string(&input).map_err(|error| error.to_string())?
                    } else {
                        input_json
                    };
                    let result = activities::execute_sql::execute_in_origin(
                        ctx,
                        sem,
                        input_json,
                        execution_origin,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::load_function_graph::NAME,
            move |ctx: ActivityContext, instance_id: String| {
                let pool = graph_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result = activities::load_function_graph::execute(
                        ctx,
                        route.pool.clone(),
                        instance_id,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::load_function_graph::TRANSACTION_AWARE_NAME,
            move |ctx: ActivityContext, input_json: String| {
                let pool = transaction_graph_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result = activities::load_function_graph::probe_transaction(
                        ctx,
                        route.pool.clone(),
                        input_json,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::update_instance_status::NAME,
            move |ctx: ActivityContext, input_json: String| {
                let pool = status_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result = activities::update_instance_status::execute(
                        ctx,
                        route.pool.clone(),
                        input_json,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::update_node_status::NAME,
            move |ctx: ActivityContext, input_json: String| {
                let pool = node_status_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result = activities::update_node_status::execute(
                        ctx,
                        route.pool.clone(),
                        input_json,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::execute_http::NAME,
            move |ctx: ActivityContext, config_json: String| {
                let pool = http_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result =
                        activities::execute_http::execute(ctx, route.pool.clone(), config_json)
                            .await;
                    route.close().await;
                    result
                }
            },
        )
        .register(
            activities::execute_multipart::NAME,
            move |ctx: ActivityContext, config_json: String| {
                let pool = multipart_pool.clone();
                async move {
                    let route = pool.route(ctx.instance_id()).await?;
                    let result = activities::execute_multipart::execute(
                        ctx,
                        route.pool.clone(),
                        config_json,
                    )
                    .await;
                    route.close().await;
                    result
                }
            },
        )
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
