use duroxide::providers::{ExecutionMetadata, Provider, WorkItem};
use duroxide::{Event, EventKind};
use duroxide_pg_opt::PostgresProvider;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc as StdArc;
use std::time::{Duration, Instant};

#[allow(dead_code)]
fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

/// Check if we're running against a localhost database.
/// Remote databases have higher latency and need relaxed timing thresholds.
#[allow(dead_code)]
pub fn is_localhost() -> bool {
    let url = get_database_url();
    url.contains("localhost") || url.contains("127.0.0.1")
}

#[allow(dead_code)]
fn next_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..]; // Last 8 characters
    format!("e2e_test_{suffix}")
}

#[allow(dead_code)]
pub async fn wait_for_history<F>(
    store: StdArc<dyn Provider>,
    instance: &str,
    predicate: F,
    timeout_ms: u64,
) -> bool
where
    F: Fn(&Vec<Event>) -> bool,
{
    wait_for_history_event(
        store,
        instance,
        |hist| if predicate(hist) { Some(()) } else { None },
        timeout_ms,
    )
    .await
    .is_some()
}

#[allow(dead_code)]
pub async fn wait_for_subscription(
    store: StdArc<dyn Provider>,
    instance: &str,
    name: &str,
    timeout_ms: u64,
) -> bool {
    wait_for_history(
        store,
        instance,
        |hist| {
            hist.iter().any(
                |e| matches!(&e.kind, EventKind::ExternalSubscribed { name: n, .. } if n == name),
            )
        },
        timeout_ms,
    )
    .await
}

#[allow(dead_code)]
pub async fn wait_for_history_event<T, F>(
    store: StdArc<dyn Provider>,
    instance: &str,
    selector: F,
    timeout_ms: u64,
) -> Option<T>
where
    T: Clone,
    F: Fn(&Vec<Event>) -> Option<T>,
{
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        let hist = store.read(instance).await.unwrap_or_default();
        if let Some(e) = selector(&hist) {
            return Some(e);
        }
        if Instant::now() > deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[allow(dead_code)]
pub async fn create_postgres_store() -> (StdArc<dyn Provider>, String) {
    let database_url = get_database_url();
    let schema_name = next_schema_name();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create Postgres provider for e2e tests");

    (StdArc::new(provider) as StdArc<dyn Provider>, schema_name)
}

/// Clean up a test schema by dropping it
#[allow(dead_code)]
pub async fn cleanup_schema(schema_name: &str) {
    let database_url = get_database_url();
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect to database for schema cleanup");

    sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
        .execute(&pool)
        .await
        .expect("Failed to drop test schema");
}

/// Test helper to create a new orchestration instance with initial history.
///
/// This replicates what the runtime does in production by using real provider APIs:
/// 1. Enqueues StartOrchestration work item
/// 2. Fetches it to get a lock token
/// 3. Acks with OrchestrationStarted event
///
/// Use this to seed test state without spinning up a full runtime.
#[allow(dead_code)]
pub async fn test_create_execution(
    provider: &dyn Provider,
    instance: &str,
    orchestration: &str,
    version: &str,
    input: &str,
    parent_instance: Option<&str>,
    parent_id: Option<u64>,
) -> Result<u64, String> {
    // Calculate next execution ID (max + 1, or INITIAL if none exist)
    // Use ProviderAdmin trait to list executions
    let admin = provider
        .as_management_capability()
        .ok_or_else(|| "Provider doesn't support management operations".to_string())?;
    let execs = admin
        .list_executions(instance)
        .await
        .map_err(|e| e.message.clone())?;
    let next_execution_id = if execs.is_empty() {
        duroxide::INITIAL_EXECUTION_ID
    } else {
        execs.iter().max().copied().unwrap() + 1
    };

    // Enqueue StartOrchestration work item with calculated execution_id
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: instance.to_string(),
                orchestration: orchestration.to_string(),
                version: Some(version.to_string()),
                input: input.to_string(),
                parent_instance: parent_instance.map(|s| s.to_string()),
                parent_id,
                execution_id: next_execution_id,
            },
            None,
        )
        .await
        .map_err(|e| e.message.clone())?;

    // Fetch to get lock token
    let (_item, lock_token, _attempt_count) = provider
        .fetch_orchestration_item(
            std::time::Duration::from_secs(30),
            std::time::Duration::ZERO,
            None,
        ) // 30 second lock timeout
        .await
        .map_err(|e| e.message.clone())?
        .ok_or_else(|| "Failed to fetch orchestration item".to_string())?;

    // The fetched item should have the execution_id we enqueued
    let execution_id = next_execution_id;

    // Ack with OrchestrationStarted event
    provider
        .ack_orchestration_item(
            &lock_token,
            execution_id,
            vec![Event::with_event_id(
                duroxide::INITIAL_EVENT_ID,
                instance,
                execution_id,
                None,
                EventKind::OrchestrationStarted {
                    name: orchestration.to_string(),
                    version: version.to_string(),
                    input: input.to_string(),
                    parent_instance: parent_instance.map(|s| s.to_string()),
                    parent_id,
                    carry_forward_events: None,
                    initial_custom_status: None,
                },
            )],
            vec![], // no worker items
            vec![], // no orchestrator items
            ExecutionMetadata {
                orchestration_name: Some(orchestration.to_string()),
                orchestration_version: Some(version.to_string()),
                ..Default::default()
            },
            vec![], // no cancelled activities
        )
        .await
        .map_err(|e| e.message.clone())?;

    Ok(execution_id)
}
