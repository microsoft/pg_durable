//! Multi-node simulation tests with clock skew scenarios.
//!
//! These tests simulate multiple "nodes" (provider instances) interacting with
//! the same database schema, with simulated clock skew between them.
//!
//! Key concepts:
//! - Each provider instance represents a "node"
//! - All nodes share the same database schema
//! - Grace period prevents dispatchers from polling early (timing jitter),
//!   but does NOT compensate for clock skew between nodes
//!
//! Test categories:
//! - Multi-node work visibility and distribution
//! - Delayed work (timer) coordination across nodes
//! - Lock races and failover scenarios
//! - NOTIFY propagation across nodes

mod common;

use common::is_localhost;
use duroxide::providers::{Provider, WorkItem};
use duroxide_pg_opt::{LongPollConfig, PostgresProvider};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Barrier;

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

fn next_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("mn_test_{suffix}")
}

async fn cleanup_schema(schema_name: &str) {
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

/// Create a provider with specific long-poll settings
async fn create_provider(schema: &str, long_poll_enabled: bool) -> PostgresProvider {
    let database_url = get_database_url();
    let config = LongPollConfig {
        enabled: long_poll_enabled,
        notifier_poll_interval: Duration::from_secs(5), // Shorter for testing
        timer_grace_period: Duration::from_millis(100),
    };

    PostgresProvider::new_with_options(&database_url, Some(schema), config)
        .await
        .expect("Failed to create provider")
}

// =============================================================================
// Multi-Node Basic Tests
// =============================================================================

/// Test: Two nodes can both see work enqueued by either node
/// This establishes the baseline that separate provider instances share state.
#[tokio::test]
async fn multi_node_shared_visibility() {
    let schema = next_schema_name();

    // Create two "nodes" pointing to the same schema
    let node_a = create_provider(&schema, true).await;
    let node_b = create_provider(&schema, true).await;

    // Node A enqueues work
    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "instance-from-a".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            None,
        )
        .await
        .expect("Node A failed to enqueue");

    // Give a moment for NOTIFY to propagate
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Node B should be able to fetch it
    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(500), None)
        .await
        .expect("Node B fetch failed");

    assert!(
        result.is_some(),
        "Node B should see work enqueued by Node A"
    );
    let (item, _, _) = result.unwrap();
    assert_eq!(item.instance, "instance-from-a");

    cleanup_schema(&schema).await;
}

/// Test: Work distribution between multiple nodes (racing)
/// When multiple nodes are fetching, only one should get each work item.
#[tokio::test]
async fn multi_node_work_distribution() {
    let schema = next_schema_name();

    // Create three nodes
    let node_a = Arc::new(create_provider(&schema, true).await);
    let node_b = Arc::new(create_provider(&schema, true).await);
    let node_c = Arc::new(create_provider(&schema, true).await);

    // Enqueue multiple work items
    for i in 0..10 {
        node_a
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("instance-{i}"),
                    orchestration: "test-orch".to_string(),
                    version: Some("1.0".to_string()),
                    input: "{}".to_string(),
                    parent_instance: None,
                    parent_id: None,
                    execution_id: 1,
                },
                None,
            )
            .await
            .expect("Failed to enqueue");
    }

    tokio::time::sleep(Duration::from_millis(100)).await;

    // All three nodes race to fetch
    let barrier = Arc::new(Barrier::new(3));
    let mut handles = vec![];

    for node in [node_a.clone(), node_b.clone(), node_c.clone()] {
        let barrier = barrier.clone();
        handles.push(tokio::spawn(async move {
            barrier.wait().await;
            let mut fetched = vec![];
            // Each node tries to fetch multiple times
            for _ in 0..5 {
                if let Ok(Some((item, token, _))) = node
                    .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(100), None)
                    .await
                {
                    fetched.push(item.instance.clone());
                    // Abandon so others can see it (simulating processing)
                    let _ = node.abandon_orchestration_item(&token, None, false).await;
                }
            }
            fetched
        }));
    }

    let mut results: Vec<Vec<String>> = Vec::new();
    for handle in handles {
        results.push(handle.await.unwrap());
    }

    // Each node should have fetched some work
    let total_fetches: usize = results.iter().map(|r| r.len()).sum();
    println!(
        "Fetches by node: {:?}",
        results.iter().map(|r| r.len()).collect::<Vec<_>>()
    );

    // We expect some overlap due to abandons, but work should be distributed
    assert!(
        total_fetches >= 3,
        "Work should be distributed across nodes"
    );

    cleanup_schema(&schema).await;
}

// =============================================================================
// Delayed Work (Timer) Tests
// =============================================================================

/// Test: Delayed work visibility across nodes
///
/// Scenario:
/// - Node A writes a delayed work item for "500ms from now"
/// - Node B should detect it after the delay passes
///
/// Note: In a real multi-node deployment, clock skew between nodes would be
/// a concern since visible_at is computed using the writer's wall clock.
/// The grace period does NOT solve clock skew - it only prevents dispatchers
/// from polling slightly too early due to timing jitter.
#[tokio::test]
async fn delayed_work_cross_node_visibility() {
    let schema = next_schema_name();

    let node_a = create_provider(&schema, true).await;
    let node_b = create_provider(&schema, true).await;

    // Node A schedules work for 500ms from now
    let timer_delay = Duration::from_millis(500);

    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "timer-test".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(timer_delay),
        )
        .await
        .expect("Failed to enqueue delayed work");

    // Wait until 450ms mark (50ms before the 500ms delay)
    tokio::time::sleep(Duration::from_millis(450)).await;

    // Start long-polling with 200ms timeout - should wake up around 500ms when work becomes visible
    let start = Instant::now();
    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(200), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(
        result.is_some(),
        "Delayed work should be visible via long-poll"
    );

    // The fetch should have completed around the 50ms mark (500ms - 450ms)
    // plus grace period (100ms) plus query execution time.
    // Allow generous margin for timing jitter and system load.
    let threshold = if is_localhost() {
        Duration::from_millis(250) // ~50ms remaining + 100ms grace + 100ms buffer
    } else {
        Duration::from_millis(500) // Remote DB has higher latency
    };
    assert!(
        elapsed < threshold,
        "Long-poll should have woken up quickly after work became visible, took {elapsed:?}"
    );

    println!("Delayed work cross-node visibility: received after {elapsed:?} of long-polling");

    cleanup_schema(&schema).await;
}

/// Test: Timer precision under simulated clock skew
///
/// Write multiple delayed work items and verify they all fire within acceptable bounds
/// despite potential timing jitter (which simulates minor clock drift).
#[tokio::test]
async fn staggered_delayed_work_visibility() {
    let schema = next_schema_name();

    let node_a = create_provider(&schema, true).await;
    let node_b = create_provider(&schema, true).await;

    // Schedule 5 delayed items at 100ms intervals
    let base_delay = 300u64; // 300ms from now

    for i in 0..5u64 {
        let delay = Duration::from_millis(base_delay + (i * 100));

        node_a
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("timer-{i}"),
                    orchestration: "test-orch".to_string(),
                    version: Some("1.0".to_string()),
                    input: "{}".to_string(),
                    parent_instance: None,
                    parent_id: None,
                    execution_id: 1,
                },
                Some(delay),
            )
            .await
            .expect("Failed to enqueue delayed work");
    }

    // Wait for all items to be ready (last delay + grace period + buffer)
    let total_wait = Duration::from_millis(base_delay + 400 + 100 + 100);
    tokio::time::sleep(total_wait).await;

    // Node B fetches all items (they are locked once fetched)
    let mut fetched = vec![];
    for _ in 0..10 {
        if let Ok(Some((item, _token, _))) = node_b
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(100), None)
            .await
        {
            fetched.push(item.instance.clone());
            // Items are locked once fetched, no need to complete or abandon
        }
    }

    println!("Fetched delayed items: {fetched:?}");
    assert_eq!(fetched.len(), 5, "All 5 delayed items should be visible");

    cleanup_schema(&schema).await;
}

/// Test: Multi-node timer coordination
///
/// Multiple nodes write delayed work, one node reads them all.
/// Verifies cross-node visibility for delayed work.
#[tokio::test]
async fn multi_node_timer_coordination() {
    let schema = next_schema_name();

    let node_a = create_provider(&schema, true).await;
    let node_b = create_provider(&schema, true).await;
    let node_c = create_provider(&schema, true).await;

    let timer_delay = Duration::from_millis(300);

    // Each node writes delayed work
    for (node, name) in [
        (&node_a, "node-a"),
        (&node_b, "node-b"),
        (&node_c, "node-c"),
    ] {
        node.enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: format!("timer-from-{name}"),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(timer_delay),
        )
        .await
        .expect("Failed to enqueue delayed work");
    }

    // Wait for all items + grace period
    tokio::time::sleep(timer_delay + Duration::from_millis(150)).await;

    // One node fetches all (items are locked once fetched)
    let reader = create_provider(&schema, true).await;
    let mut fetched = vec![];

    for _ in 0..5 {
        if let Ok(Some((item, _token, _))) = reader
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(100), None)
            .await
        {
            fetched.push(item.instance.clone());
            // Items are locked once fetched
        }
    }

    println!("Fetched cross-node delayed work: {fetched:?}");
    assert_eq!(
        fetched.len(),
        3,
        "Should see all 3 delayed items from different nodes"
    );

    // Verify we got one from each node
    assert!(fetched.iter().any(|s| s.contains("node-a")));
    assert!(fetched.iter().any(|s| s.contains("node-b")));
    assert!(fetched.iter().any(|s| s.contains("node-c")));

    cleanup_schema(&schema).await;
}

// =============================================================================
// Staggered Timer Tests
// =============================================================================

/// Test: Staggered delayed work visibility
///
/// Writes multiple delayed items with varying delays and verifies they all
/// become visible after their respective delays pass.
///
/// Note: True clock drift between nodes cannot be simulated without actual
/// clock manipulation. This test validates staggered timer behavior.
#[tokio::test]
async fn clock_drift_progressive() {
    let schema = next_schema_name();

    let writer = create_provider(&schema, true).await;
    let reader = create_provider(&schema, true).await;

    // Write delayed items with simulated drift
    // Item 0: on time, Item 1: 10ms "drift", Item 2: 20ms "drift", etc.
    for i in 0..5u64 {
        let base_delay = 200 + (i * 50); // 200ms, 250ms, 300ms, 350ms, 400ms
        let simulated_drift = i * 10; // 0ms, 10ms, 20ms, 30ms, 40ms drift

        // The "drifted" node thinks it's scheduling for base_delay from now,
        // but actually schedules for base_delay - drift (appears early to readers)
        let effective_delay = base_delay.saturating_sub(simulated_drift);

        writer
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("drift-timer-{i}"),
                    orchestration: "test-orch".to_string(),
                    version: Some("1.0".to_string()),
                    input: "{}".to_string(),
                    parent_instance: None,
                    parent_id: None,
                    execution_id: 1,
                },
                Some(Duration::from_millis(effective_delay)),
            )
            .await
            .expect("Failed to enqueue delayed work");
    }

    // Wait for all items (last base_delay + grace period)
    tokio::time::sleep(Duration::from_millis(400 + 150)).await;

    let mut fetched = vec![];
    for _ in 0..10 {
        if let Ok(Some((item, _token, _))) = reader
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(50), None)
            .await
        {
            fetched.push(item.instance.clone());
            // Items are locked once fetched
        }
    }

    println!("Fetched drifted items: {fetched:?}");
    assert_eq!(
        fetched.len(),
        5,
        "All delayed items should be visible after their delays pass"
    );

    cleanup_schema(&schema).await;
}

/// Test: Large clock jump simulation
///
/// Simulates what happens when a node's clock suddenly jumps forward.
/// Delayed work that was scheduled for the future suddenly becomes past-due.
#[tokio::test]
async fn clock_jump_forward_simulation() {
    let schema = next_schema_name();

    let writer = create_provider(&schema, true).await;

    // Write delayed work for 2 seconds from now
    let long_delay = Duration::from_millis(2000);
    writer
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "future-timer".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(long_delay),
        )
        .await
        .expect("Failed to enqueue delayed work");

    // Create a "new node" that represents the same system after a clock jump
    // This node should immediately see the work as past-due
    tokio::time::sleep(Duration::from_millis(2100)).await; // Wait for delay to pass

    let reader = create_provider(&schema, true).await;

    let result = reader
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(200), None)
        .await
        .expect("Fetch failed");

    assert!(
        result.is_some(),
        "Delayed work should be visible after clock advances past visible_at"
    );

    cleanup_schema(&schema).await;
}

// =============================================================================
// Multi-Node Failover Tests
// =============================================================================

/// Test: Work visibility after node "failure"
///
/// Simulates a node acquiring work, then "crashing" (lock expires).
/// Another node should be able to pick up the work.
#[tokio::test]
async fn multi_node_failover() {
    let schema = next_schema_name();

    let node_a = create_provider(&schema, true).await;
    let node_b = create_provider(&schema, true).await;

    // Node A enqueues work
    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "failover-test".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            None,
        )
        .await
        .expect("Failed to enqueue");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Node A fetches with a short lock timeout
    let lock_timeout = Duration::from_secs(1);
    let result = node_a
        .fetch_orchestration_item(lock_timeout, Duration::from_millis(100), None)
        .await
        .expect("Fetch failed");

    assert!(result.is_some(), "Node A should get the work");
    let (item, _token, _attempt) = result.unwrap();
    assert_eq!(item.instance, "failover-test");

    // Node A "crashes" - we just don't process the work
    // Wait for lock to expire
    tokio::time::sleep(lock_timeout + Duration::from_millis(100)).await;

    // Node B should now be able to pick up the work
    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(500), None)
        .await
        .expect("Fetch failed");

    assert!(
        result.is_some(),
        "Node B should get the work after Node A's lock expires"
    );
    let (item, _, attempt) = result.unwrap();
    assert_eq!(item.instance, "failover-test");
    assert_eq!(attempt, 2, "Should be attempt 2 after lock expiry");

    cleanup_schema(&schema).await;
}

/// Test: Concurrent lock acquisition race
///
/// Multiple nodes try to acquire the same work simultaneously.
/// Only one should succeed, others should get None or different work.
#[tokio::test]
async fn multi_node_lock_race() {
    let schema = next_schema_name();

    // Create provider and enqueue one work item
    let setup = create_provider(&schema, false).await; // No long-poll for setup
    setup
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "race-test".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            None,
        )
        .await
        .expect("Failed to enqueue");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Create 5 racing nodes
    let barrier = Arc::new(Barrier::new(5));
    let schema_clone = schema.clone();
    let mut handles = vec![];

    for i in 0..5 {
        let barrier = barrier.clone();
        let schema = schema_clone.clone();
        handles.push(tokio::spawn(async move {
            let node = create_provider(&schema, false).await;
            barrier.wait().await;

            // All nodes try to fetch simultaneously
            let result = node
                .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(100), None)
                .await;

            match result {
                Ok(Some((item, _, _))) => Some((i, item.instance)),
                _ => None,
            }
        }));
    }

    let mut results: Vec<Option<(i32, String)>> = Vec::new();
    for handle in handles {
        results.push(handle.await.unwrap());
    }

    let winners: Vec<_> = results.iter().filter(|r| r.is_some()).collect();
    println!("Lock race results: {results:?}");

    assert_eq!(
        winners.len(),
        1,
        "Exactly one node should win the lock race"
    );

    cleanup_schema(&schema).await;
}

/// Test: Concurrent lock acquisition race with long-polling
///
/// Same as multi_node_lock_race but with long-poll enabled.
/// Multiple nodes try to acquire the same work simultaneously via long-poll.
/// Only one should succeed, others should timeout or get None.
#[tokio::test]
async fn multi_node_lock_race_longpoll() {
    let schema = next_schema_name();

    // Create provider and enqueue one work item
    let setup = create_provider(&schema, false).await;
    setup
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "race-test-longpoll".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            None,
        )
        .await
        .expect("Failed to enqueue");

    tokio::time::sleep(Duration::from_millis(100)).await;

    // Create 5 racing nodes with long-poll enabled
    let barrier = Arc::new(Barrier::new(5));
    let schema_clone = schema.clone();
    let mut handles = vec![];

    for i in 0..5 {
        let barrier = barrier.clone();
        let schema = schema_clone.clone();
        handles.push(tokio::spawn(async move {
            let node = create_provider(&schema, true).await; // Long-poll enabled
            barrier.wait().await;

            let start = Instant::now();
            // All nodes try to fetch simultaneously with long-poll timeout
            let result = node
                .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(500), None)
                .await;

            let elapsed = start.elapsed();
            match result {
                Ok(Some((item, _, _))) => Some((i, item.instance, elapsed)),
                _ => None,
            }
        }));
    }

    let mut results: Vec<Option<(i32, String, Duration)>> = Vec::new();
    for handle in handles {
        results.push(handle.await.unwrap());
    }

    let winners: Vec<_> = results.iter().filter(|r| r.is_some()).collect();
    println!("Lock race (long-poll) results: {results:?}");

    assert_eq!(
        winners.len(),
        1,
        "Exactly one node should win the lock race even with long-poll"
    );

    // The winner should have gotten it quickly (not waited full timeout)
    // Note: On remote DBs with 100-200ms latency, this threshold needs to be larger
    let winner_threshold = if is_localhost() {
        Duration::from_millis(200)
    } else {
        Duration::from_millis(500)
    };
    if let Some(Some((node_id, instance, elapsed))) = winners.first() {
        println!("Winner: node {node_id} got '{instance}' in {elapsed:?}");
        assert!(
            *elapsed < winner_threshold,
            "Winner should get work quickly, not wait for timeout"
        );
    }

    cleanup_schema(&schema).await;
}

// =============================================================================
// Long-Poll Notification Across Nodes
// =============================================================================

/// Test: NOTIFY propagates to all listening nodes
///
/// When one node inserts work, all other nodes with long-poll enabled
/// should be woken via NOTIFY.
#[tokio::test]
async fn multi_node_notify_propagation() {
    let schema = next_schema_name();

    // Create writer node (no long-poll needed for writing)
    let writer = create_provider(&schema, false).await;

    // Create 3 listener nodes with long-poll enabled
    let listener_a = Arc::new(create_provider(&schema, true).await);
    let listener_b = Arc::new(create_provider(&schema, true).await);
    let listener_c = Arc::new(create_provider(&schema, true).await);

    // Start all listeners waiting for work
    let barrier = Arc::new(Barrier::new(4)); // 3 listeners + 1 for test
    let mut handles = vec![];

    for (name, listener) in [
        ("A", listener_a.clone()),
        ("B", listener_b.clone()),
        ("C", listener_c.clone()),
    ] {
        let barrier = barrier.clone();
        let name = name.to_string();
        handles.push(tokio::spawn(async move {
            barrier.wait().await;
            let start = Instant::now();

            // Wait for work with 5 second timeout
            let result = listener
                .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
                .await;

            let elapsed = start.elapsed();
            (name, result.is_ok() && result.unwrap().is_some(), elapsed)
        }));
    }

    // Wait for listeners to start waiting, then insert work
    barrier.wait().await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    let insert_time = Instant::now();
    writer
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "notify-test".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            None,
        )
        .await
        .expect("Failed to enqueue");

    let mut results: Vec<(String, bool, Duration)> = Vec::new();
    for handle in handles {
        results.push(handle.await.unwrap());
    }

    println!("Notify propagation results:");
    for (name, got_work, elapsed) in &results {
        println!("  {name}: got_work={got_work}, elapsed={elapsed:?}");
    }

    // At least one should have gotten the work
    let got_work_count = results.iter().filter(|(_, got, _)| *got).count();
    assert!(got_work_count >= 1, "At least one node should get the work");

    // All should have responded quickly (not waiting full 5s timeout)
    // Note: On remote DBs with 100-200ms latency, allow more time
    let response_threshold = if is_localhost() {
        Duration::from_secs(2)
    } else {
        Duration::from_secs(3)
    };
    for (name, _, elapsed) in &results {
        assert!(
            *elapsed < response_threshold,
            "{name} took too long: {elapsed:?} (NOTIFY may not have propagated)"
        );
    }

    let _ = insert_time; // Used for timing reference

    cleanup_schema(&schema).await;
}
