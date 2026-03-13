//! Fault injection tests for long-polling implementation
//!
//! These tests verify the system handles various failure modes gracefully,
//! including notifier panics, query errors, and edge cases.
//!
//! Run with: cargo test --test fault_injection_tests --features test-fault-injection -- --ignored --nocapture

mod common;

use duroxide::providers::{Provider, WorkItem};
#[cfg(feature = "test-fault-injection")]
use duroxide_pg_opt::FaultInjector;
use duroxide_pg_opt::{LongPollConfig, PostgresProvider};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

/// Check if we're running against a localhost database.
fn is_localhost() -> bool {
    let url = get_database_url();
    url.contains("localhost") || url.contains("127.0.0.1")
}

fn next_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("fi_test_{suffix}")
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

// =============================================================================
// Category 11: Fault Injection Tests
// =============================================================================

/// Test that a notifier panic causes fallback to poll_timeout.
#[tokio::test]
#[cfg(feature = "test-fault-injection")]
async fn fault_notifier_panic() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let fault_injector = Arc::new(FaultInjector::new());

    let provider = PostgresProvider::new_with_fault_injection(
        &database_url,
        Some(&schema),
        LongPollConfig::default(),
        fault_injector.clone(),
    )
    .await
    .expect("Failed to create provider");

    // Trigger panic in notifier
    fault_injector.set_notifier_should_panic(true);

    // Give time for panic to occur
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Insert work
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "panic-test".to_string(),
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
        .expect("Failed to enqueue work");

    // Fetch should still work (via do_fetch, then poll_timeout fallback)
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(1), None)
        .await
        .expect("Fetch failed");

    assert!(result.is_some(), "Should find work despite notifier panic");

    cleanup_schema(&schema).await;
}

/// Test that refresh query errors are handled gracefully.
#[tokio::test]
#[cfg(feature = "test-fault-injection")]
async fn fault_refresh_query_error() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let fault_injector = Arc::new(FaultInjector::new());

    let provider = PostgresProvider::new_with_fault_injection(
        &database_url,
        Some(&schema),
        LongPollConfig::default(),
        fault_injector.clone(),
    )
    .await
    .expect("Failed to create provider");

    // Make refresh queries fail
    fault_injector.set_refresh_should_error(true);

    // Wait for refresh to fail
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Insert and fetch should still work (NOTIFY still functions)
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "refresh-error-test".to_string(),
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
        .expect("Failed to enqueue work");

    let result = provider
        .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
        .await
        .expect("Fetch failed");

    assert!(
        result.is_some(),
        "Should find work despite refresh query errors"
    );

    cleanup_schema(&schema).await;
}

/// Test that timers with negative delay fire immediately (no crash).
#[tokio::test]
async fn fault_heap_corruption_negative_timer() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Insert work with visible_at in the far past (simulating heap corruption)
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let past = chrono::Utc::now() - chrono::Duration::hours(1);

    sqlx::query(&format!(
        r#"INSERT INTO {schema}.orchestrator_queue
           (instance_id, work_item, visible_at, created_at)
           VALUES ($1, $2, $3, NOW())"#
    ))
    .bind("negative-timer-test")
    .bind(
        serde_json::to_string(&serde_json::json!({
            "StartOrchestration": {
                "instance": "negative-timer-test",
                "orchestration": "test-orch",
                "version": "1.0",
                "input": "{}",
                "execution_id": 1
            }
        }))
        .unwrap(),
    )
    .bind(past)
    .execute(&pool)
    .await
    .expect("Failed to insert work");

    // Should find work immediately (no crash)
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find work with past visible_at");
    assert!(
        elapsed < Duration::from_millis(500),
        "Past timer should be found immediately, took {elapsed:?}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

// =============================================================================
// Clock Skew Fault Injection Tests
// =============================================================================

/// Helper to create a provider with fault injection and clock skew
#[cfg(feature = "test-fault-injection")]
async fn create_provider_with_skew(
    schema: &str,
    long_poll_enabled: bool,
    clock_skew_ms: i64,
) -> (PostgresProvider, Arc<FaultInjector>) {
    let database_url = get_database_url();
    let config = LongPollConfig {
        enabled: long_poll_enabled,
        notifier_poll_interval: Duration::from_secs(5),
        timer_grace_period: Duration::from_millis(100),
    };

    let fault_injector = Arc::new(FaultInjector::new());
    fault_injector.set_clock_skew_signed(clock_skew_ms);

    let provider = PostgresProvider::new_with_fault_injection(
        &database_url,
        Some(schema),
        config,
        fault_injector.clone(),
    )
    .await
    .expect("Failed to create provider with fault injection");

    (provider, fault_injector)
}

/// Test: Clock ahead causes delayed work to appear late
///
/// When one node's clock is ahead, delayed work it schedules will appear
/// to fire LATER from the perspective of a node with correct time.
/// This is because visible_at = skewed_now + delay = (wall + skew) + delay.
#[cfg(feature = "test-fault-injection")]
#[tokio::test]
async fn fault_injection_clock_skew_late_visibility() {
    let schema = next_schema_name();

    // Use larger clock skew for remote DBs to account for network latency
    // For remote DBs, use 4s to give plenty of margin for network latency
    let clock_skew_ms = if is_localhost() { 1000 } else { 4000 };

    let (node_a, fi_a) = create_provider_with_skew(&schema, false, clock_skew_ms).await;
    assert_eq!(
        fi_a.get_clock_skew_ms(),
        clock_skew_ms,
        "Clock skew should be configured correctly"
    );

    // Node B has correct time (no skew)
    let (node_b, fi_b) = create_provider_with_skew(&schema, false, 0).await;
    assert_eq!(
        fi_b.get_clock_skew_ms(),
        0,
        "Node B should have no clock skew"
    );

    // Node A schedules work for 500ms from now (from A's perspective)
    // visible_at = (wall + clock_skew) + 500
    // For remote, use 1500ms delay to provide more margin
    let delay_ms = if is_localhost() { 500 } else { 1500 };
    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "skewed-timer".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(Duration::from_millis(delay_ms)),
        )
        .await
        .expect("Failed to enqueue delayed work");

    // Wait - should be well before visible_at
    // For remote, we have visible_at = now + 4000 + 1500 = now + 5500ms
    // So waiting 2000ms should still be way before visible_at
    let first_wait_ms = if is_localhost() { 800 } else { 2000 };
    tokio::time::sleep(Duration::from_millis(first_wait_ms)).await;

    // Use ZERO poll_timeout to check immediately without waiting
    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::ZERO, None)
        .await
        .expect("Fetch failed");

    // Work should NOT be visible yet
    assert!(
        result.is_none(),
        "Delayed work should NOT be visible yet due to Node A's clock being ahead"
    );

    // Wait until past visible_at
    // For remote: remaining wait should be ~5500 - 2000 = 3500ms, so wait 4000ms to be safe
    let second_wait_ms = if is_localhost() { 900 } else { 4000 };
    tokio::time::sleep(Duration::from_millis(second_wait_ms)).await;

    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(200), None)
        .await
        .expect("Fetch failed");

    assert!(
        result.is_some(),
        "Delayed work should now be visible after full delay"
    );

    cleanup_schema(&schema).await;
}

/// Test: Clock behind causes delayed work to appear early
///
/// When one node's clock is behind, delayed work it schedules will appear
/// to fire EARLIER from the perspective of a node with correct time.
/// This is because visible_at = skewed_now + delay = (wall - skew) + delay.
#[cfg(feature = "test-fault-injection")]
#[tokio::test]
async fn fault_injection_clock_skew_early_visibility() {
    let schema = next_schema_name();

    // Node A has clock 200ms behind - work it schedules will appear EARLY to others
    // visible_at = (wall - 200) + delay = wall + delay - 200
    let (node_a, _fi_a) = create_provider_with_skew(&schema, false, -200).await;

    // Node B has correct time (no skew)
    let (node_b, _fi_b) = create_provider_with_skew(&schema, false, 0).await;

    // Node A schedules work for "500ms from now" (from A's perspective)
    // visible_at = A_now + 500 = (wall - 200) + 500 = wall + 300ms
    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "skewed-timer".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(Duration::from_millis(500)),
        )
        .await
        .expect("Failed to enqueue delayed work");

    // Wait 350ms wall clock - visible_at is at wall 300ms, so it IS visible!
    tokio::time::sleep(Duration::from_millis(350)).await;

    let result = node_b
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_millis(100), None)
        .await
        .expect("Fetch failed");

    // Work should be visible because A's clock was behind when scheduling
    assert!(
        result.is_some(),
        "Delayed work should be visible early due to Node A's clock being behind"
    );

    cleanup_schema(&schema).await;
}

/// Test: Symmetric clock skew between two nodes
///
/// Demonstrates the compounding effect of clock skew:
/// - Node A (clock +100ms ahead) schedules work with 500ms delay
///   - visible_at = (wall + 100) + 500 = wall + 600ms (stored in DB)
/// - Node B (clock -100ms behind) fetches work
///   - B sees work when B_now >= visible_at
///   - (wall - 100) >= (wall_at_schedule + 600)
///   - wall >= wall_at_schedule + 700ms
///
/// Result: 500ms delay appears as 700ms delay from B's perspective (200ms total skew)
#[cfg(feature = "test-fault-injection")]
#[tokio::test]
async fn fault_injection_symmetric_clock_skew() {
    let schema = next_schema_name();

    // Node A: clock 100ms ahead
    let (node_a, _fi_a) = create_provider_with_skew(&schema, false, 100).await;

    // Node B: clock 100ms behind, with long-poll enabled
    let (node_b, _fi_b) = create_provider_with_skew(&schema, true, -100).await;

    let node_b = Arc::new(node_b);
    let node_b_clone = node_b.clone();

    // Start Node B long-polling BEFORE work is enqueued
    let fetch_handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = node_b_clone
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(3), None)
            .await
            .expect("Fetch failed");
        let elapsed = start.elapsed();
        (result, elapsed)
    });

    // Small delay to ensure B is listening
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Node A schedules work with 500ms delay (from A's perspective)
    // Since A is +100ms ahead: visible_at = (wall + 100) + 500 = wall + 600ms
    let enqueue_time = Instant::now();
    node_a
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "symmetric-timer".to_string(),
                orchestration: "test-orch".to_string(),
                version: Some("1.0".to_string()),
                input: "{}".to_string(),
                parent_instance: None,
                parent_id: None,
                execution_id: 1,
            },
            Some(Duration::from_millis(500)),
        )
        .await
        .expect("Failed to enqueue delayed work");

    // Wait for Node B to receive the work
    let (result, total_elapsed) = fetch_handle.await.unwrap();
    let time_since_enqueue = enqueue_time.elapsed();

    assert!(result.is_some(), "Node B should receive the work");

    // Node B should receive work around 700ms after enqueue (500ms delay + 200ms total skew)
    // Allow generous margin for timing jitter, network latency, and concurrent test load
    println!(
        "Symmetric clock skew test:\n\
         - Node A skew: +100ms (ahead)\n\
         - Node B skew: -100ms (behind)\n\
         - Scheduled delay: 500ms\n\
         - Expected effective delay: ~700ms (500 + 200 skew)\n\
         - Actual time since enqueue: {time_since_enqueue:?}\n\
         - Total fetch time (including pre-enqueue wait): {total_elapsed:?}"
    );

    assert!(
        time_since_enqueue >= Duration::from_millis(600),
        "Work should NOT appear before ~700ms due to clock skew, but appeared at {time_since_enqueue:?}"
    );

    // Use tighter threshold for localhost, more generous for remote
    let upper_bound_ms = if is_localhost() { 900 } else { 1500 };
    assert!(
        time_since_enqueue < Duration::from_millis(upper_bound_ms),
        "Work should appear around 700ms, not {time_since_enqueue:?}"
    );

    cleanup_schema(&schema).await;
}
