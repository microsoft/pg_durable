use duroxide::providers::{ExecutionMetadata, Provider, WorkItem};
use duroxide::{Event, EventKind, INITIAL_EVENT_ID, INITIAL_EXECUTION_ID};
use duroxide_pg_opt::PostgresProvider;
use tracing_subscriber::EnvFilter;

// Initialize tracing subscriber for tests with DEBUG level
static INIT: std::sync::Once = std::sync::Once::new();

fn init_test_logging() {
    INIT.call_once(|| {
        let env_filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
        // Try to initialize, but ignore if already initialized (e.g., by duroxide runtime)
        let _ = tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_max_level(tracing::Level::DEBUG)
            .with_test_writer()
            .try_init();
    });
}

/// Helper to get a unique test schema name using GUID suffix
fn get_test_schema() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..]; // Last 8 characters
    format!("test_{suffix}")
}

/// Helper to load database URL from environment
fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set in environment or .env file")
}

#[tokio::test]
async fn test_provider_creation() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    // Test provider creation with custom schema
    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Verify schema was created
    let schema_exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
    )
    .bind(&schema_name)
    .fetch_one(provider.pool())
    .await
    .expect("Failed to check schema existence");

    assert!(schema_exists, "Schema should be created");

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_provider_creation_default_schema() {
    init_test_logging();
    let database_url = get_database_url();

    // Test provider creation with default schema (public)
    let provider = PostgresProvider::new(&database_url)
        .await
        .expect("Failed to create provider");

    // Verify tables were created in public schema
    let table_exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'instances')"
    )
    .fetch_one(provider.pool())
    .await
    .expect("Failed to check table existence");

    assert!(table_exists, "Tables should be created in public schema");

    // Verify public schema exists before cleanup
    let public_schema_exists_before: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = 'public')",
    )
    .fetch_one(provider.pool())
    .await
    .expect("Failed to check public schema existence");

    assert!(
        public_schema_exists_before,
        "Public schema should exist before cleanup"
    );

    // Cleanup: drop tables from public schema (but NOT the schema itself)
    provider.cleanup_schema().await.expect("Failed to cleanup");

    // Verify tables were dropped from public schema
    let table_exists_after: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'instances')"
    )
    .fetch_one(provider.pool())
    .await
    .expect("Failed to check table existence after cleanup");

    assert!(
        !table_exists_after,
        "Tables should be dropped from public schema"
    );

    // CRITICAL: Verify public schema still exists after cleanup
    let public_schema_exists_after: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = 'public')",
    )
    .fetch_one(provider.pool())
    .await
    .expect("Failed to check public schema existence");

    assert!(
        public_schema_exists_after,
        "Public schema must NEVER be dropped - it's a PostgreSQL system schema"
    );
}

#[tokio::test]
async fn test_schema_initialization() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Verify all required tables exist
    let tables = vec![
        "instances",
        "executions",
        "history",
        "orchestrator_queue",
        "worker_queue",
        "instance_locks",
    ];

    for table in tables {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)")
        .bind(&schema_name)
        .bind(table)
        .fetch_one(provider.pool())
        .await
        .unwrap_or_else(|_| panic!("Failed to check table existence: {table}"));

        assert!(exists, "Table {table} should exist");
    }

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_read_empty_instance() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Reading non-existent instance should return empty vector
    let events = provider
        .read("non_existent_instance")
        .await
        .expect("read should succeed");
    assert_eq!(
        events.len(),
        0,
        "Reading non-existent instance should return empty"
    );

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_enqueue_for_orchestrator() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    let instance_id = format!(
        "test_instance_{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    let execution_id = 1u64;

    // Enqueue a StartOrchestration work item
    let work_item = WorkItem::StartOrchestration {
        instance: instance_id.to_string(),
        orchestration: "TestOrchestration".to_string(),
        input: "test_input".to_string(),
        version: Some("1.0.0".to_string()),
        parent_instance: None,
        parent_id: None,
        execution_id,
    };

    provider
        .enqueue_for_orchestrator(work_item, None)
        .await
        .expect("Failed to enqueue orchestrator work");

    // Small delay to ensure the item is committed and visible
    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;

    // ⚠️ CRITICAL: Instance is NOT created on enqueue - must fetch and ack with metadata
    // Fetch the work item
    let (_item, lock_token, _attempt_count) = provider
        .fetch_orchestration_item(
            std::time::Duration::from_secs(30),
            std::time::Duration::ZERO,
            None,
        ) // 30 second lock timeout
        .await
        .expect("fetch_orchestration_item should succeed")
        .expect("Should fetch enqueued work item");

    // Ack with OrchestrationStarted event and proper metadata to create instance
    provider
        .ack_orchestration_item(
            &lock_token,
            execution_id,
            vec![Event::with_event_id(
                INITIAL_EVENT_ID,
                &instance_id,
                execution_id,
                None,
                EventKind::OrchestrationStarted {
                    name: "TestOrchestration".to_string(),
                    version: "1.0.0".to_string(),
                    input: "test_input".to_string(),
                    parent_instance: None,
                    parent_id: None,
                    carry_forward_events: None,
                    initial_custom_status: None,
                },
            )],
            vec![], // no worker items
            vec![], // no orchestrator items
            ExecutionMetadata {
                orchestration_name: Some("TestOrchestration".to_string()),
                orchestration_version: Some("1.0.0".to_string()),
                ..Default::default()
            },
            vec![], // no cancelled activities
        )
        .await
        .expect("Failed to ack orchestration item");

    // Verify instance was created
    let mgmt = provider
        .as_management_capability()
        .expect("Management capability should be available");
    let execution_id_opt = mgmt.latest_execution_id(&instance_id).await.ok();
    assert_eq!(
        execution_id_opt,
        Some(execution_id),
        "Instance should have execution_id"
    );

    // Read history (should contain the OrchestrationStarted event we just acked)
    let events = provider
        .read(&instance_id)
        .await
        .expect("read should succeed");
    assert_eq!(
        events.len(),
        1,
        "History should contain OrchestrationStarted event"
    );
    assert!(
        matches!(&events[0].kind, EventKind::OrchestrationStarted { .. }),
        "First event should be OrchestrationStarted"
    );

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_enqueue_and_dequeue_worker() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    let instance_id = "test_instance_worker";
    let execution_id = 1u64;

    // Create a worker work item
    let work_item = WorkItem::ActivityExecute {
        instance: instance_id.to_string(),
        execution_id,
        id: 100u64,
        name: "TestActivity".to_string(),
        input: "activity_input".to_string(),
        session_id: None,
    };

    // Enqueue worker work
    provider
        .enqueue_for_worker(work_item.clone())
        .await
        .expect("Failed to enqueue worker work");

    // Dequeue worker work
    let (dequeued_item, lock_token, _attempt_count) = provider
        .fetch_work_item(
            std::time::Duration::from_secs(30),
            std::time::Duration::ZERO,
            None,
        ) // 30 second lock timeout
        .await
        .expect("Should dequeue worker work")
        .expect("Should have a work item");

    // Verify it's the same item
    match (&work_item, &dequeued_item) {
        (
            WorkItem::ActivityExecute {
                instance: i1,
                name: n1,
                ..
            },
            WorkItem::ActivityExecute {
                instance: i2,
                name: n2,
                ..
            },
        ) => {
            assert_eq!(i1, i2, "Instance should match");
            assert_eq!(n1, n2, "Activity name should match");
        }
        _ => panic!("Work items should match"),
    }

    // Verify lock token is not empty
    assert!(!lock_token.is_empty(), "Lock token should not be empty");

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_fetch_orchestration_item_empty_queue() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Fetch from empty queue should return None
    let item = provider
        .fetch_orchestration_item(
            std::time::Duration::from_secs(30),
            std::time::Duration::ZERO,
            None,
        ) // 30 second lock timeout
        .await
        .expect("fetch should succeed");
    assert!(item.is_none(), "Empty queue should return None");

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_management_capability() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Verify management capability is available
    let mgmt = provider.as_management_capability();
    assert!(mgmt.is_some(), "Management capability should be available");

    // Test list_instances on empty database
    let mgmt = mgmt.unwrap();
    let instances = mgmt
        .list_instances()
        .await
        .expect("Failed to list instances");
    assert_eq!(
        instances.len(),
        0,
        "Should return empty list for new schema"
    );

    // Test system metrics
    let metrics = mgmt
        .get_system_metrics()
        .await
        .expect("Failed to get metrics");
    assert_eq!(metrics.total_instances, 0, "Should have zero instances");
    assert_eq!(metrics.total_executions, 0, "Should have zero executions");

    // Test queue depths
    let queue_depths = mgmt
        .get_queue_depths()
        .await
        .expect("Failed to get queue depths");
    assert_eq!(
        queue_depths.orchestrator_queue, 0,
        "Orchestrator queue should be empty"
    );
    assert_eq!(queue_depths.worker_queue, 0, "Worker queue should be empty");

    provider.cleanup_schema().await.expect("Failed to cleanup");
}

#[tokio::test]
async fn test_list_instances_and_executions() {
    init_test_logging();
    let database_url = get_database_url();
    let schema_name = get_test_schema();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema_name))
        .await
        .expect("Failed to create provider");

    // Create a couple of instances
    let instance1 = "test_instance_1";
    let instance2 = "test_instance_2";

    let work_item1 = WorkItem::StartOrchestration {
        instance: instance1.to_string(),
        orchestration: "Orch1".to_string(),
        input: "input1".to_string(),
        version: Some("1.0.0".to_string()),
        parent_instance: None,
        parent_id: None,
        execution_id: 1u64,
    };

    let work_item2 = WorkItem::StartOrchestration {
        instance: instance2.to_string(),
        orchestration: "Orch2".to_string(),
        input: "input2".to_string(),
        version: Some("1.0.0".to_string()),
        parent_instance: None,
        parent_id: None,
        execution_id: 1u64,
    };

    provider
        .enqueue_for_orchestrator(work_item1, None)
        .await
        .expect("Failed to enqueue");
    provider
        .enqueue_for_orchestrator(work_item2, None)
        .await
        .expect("Failed to enqueue");

    // ⚠️ CRITICAL: Instances are NOT created on enqueue - must fetch and ack with metadata
    // Fetch and ack both work items to create instances
    for (orchestration, instance) in [("Orch1", instance1), ("Orch2", instance2)] {
        let (_item, lock_token, _attempt_count) = provider
            .fetch_orchestration_item(
                std::time::Duration::from_secs(30),
                std::time::Duration::ZERO,
                None,
            ) // 30 second lock timeout
            .await
            .expect("fetch_orchestration_item should succeed")
            .expect("Should fetch enqueued work item");

        provider
            .ack_orchestration_item(
                &lock_token,
                INITIAL_EXECUTION_ID,
                vec![Event::with_event_id(
                    INITIAL_EVENT_ID,
                    instance,
                    INITIAL_EXECUTION_ID,
                    None,
                    EventKind::OrchestrationStarted {
                        name: orchestration.to_string(),
                        version: "1.0.0".to_string(),
                        input: "input".to_string(),
                        parent_instance: None,
                        parent_id: None,
                        carry_forward_events: None,
                        initial_custom_status: None,
                    },
                )],
                vec![],
                vec![],
                ExecutionMetadata {
                    orchestration_name: Some(orchestration.to_string()),
                    orchestration_version: Some("1.0.0".to_string()),
                    ..Default::default()
                },
                vec![], // no cancelled activities
            )
            .await
            .expect("Failed to ack orchestration item");
    }

    // Test list_instances
    let mgmt = provider.as_management_capability().unwrap();
    let instances = mgmt
        .list_instances()
        .await
        .expect("Failed to list instances");
    assert_eq!(instances.len(), 2, "Should have 2 instances");
    assert!(
        instances.contains(&instance1.to_string()),
        "Should contain instance1"
    );
    assert!(
        instances.contains(&instance2.to_string()),
        "Should contain instance2"
    );

    // Test list_executions
    let executions = mgmt
        .list_executions(instance1)
        .await
        .expect("Failed to list executions");
    assert_eq!(executions.len(), 1, "Should have 1 execution");
    assert_eq!(executions[0], 1u64, "Execution ID should be 1");

    provider.cleanup_schema().await.expect("Failed to cleanup");
}
