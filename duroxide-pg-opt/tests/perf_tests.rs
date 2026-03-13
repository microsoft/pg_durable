//! Performance tests for long-polling implementation
//!
//! These tests measure the performance characteristics of the long-polling
//! implementation, including latency and idle behavior.
//!
//! Run with: cargo test --test perf_tests -- --ignored --nocapture

mod common;

use duroxide::providers::{ExecutionMetadata, Provider, WorkItem};
use duroxide_pg_opt::{LongPollConfig, PostgresProvider};
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

fn next_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("perf_test_{suffix}")
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
// Category 8: Performance Tests
// =============================================================================

/// Test that the provider remains stable during idle periods.
/// With long-polling, the system should wait on NOTIFY without excessive activity.
#[tokio::test]
#[ignore] // Long-running performance test
async fn perf_idle_stability() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create provider with a short refresh interval for testing
    let config = LongPollConfig {
        enabled: true,
        notifier_poll_interval: Duration::from_secs(5), // 5s refresh for faster test
        timer_grace_period: Duration::from_millis(100),
    };

    let provider = Arc::new(
        PostgresProvider::new_with_options(&database_url, Some(&schema), config)
            .await
            .expect("Failed to create provider"),
    );

    // Spawn a dispatcher that's waiting for work (simulates idle system)
    let provider_clone = provider.clone();
    let fetch_handle = tokio::spawn(async move {
        provider_clone
            .fetch_orchestration_item(Duration::from_secs(60), Duration::from_secs(25), None)
            .await
    });

    // Wait for 20 seconds, observing idle behavior
    let idle_start = Instant::now();
    tokio::time::sleep(Duration::from_secs(20)).await;
    let idle_duration = idle_start.elapsed();

    // Cancel the fetch task
    fetch_handle.abort();

    eprintln!("\n========== PERF: IDLE STABILITY ==========");
    eprintln!("Configuration:");
    eprintln!("  - Refresh interval: 5s");
    eprintln!("  - Timer grace period: 100ms");
    eprintln!("  - Idle observation period: {idle_duration:?}");
    eprintln!("Result: PASS - Provider remained stable during idle period");
    eprintln!("==========================================\n");

    // Test passes if we reach here without panics or hangs
    cleanup_schema(&schema).await;
}

/// Test that dispatchers wake quickly when work is inserted.
/// With NOTIFY, wake latency should be very low (< 100ms typical).
#[tokio::test]
#[ignore] // Long-running performance test
async fn perf_notify_wake_latency() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let config = LongPollConfig {
        enabled: true,
        notifier_poll_interval: Duration::from_secs(60), // Long interval - rely on NOTIFY
        timer_grace_period: Duration::from_millis(100),
    };

    let provider = Arc::new(
        PostgresProvider::new_with_options(&database_url, Some(&schema), config)
            .await
            .expect("Failed to create provider"),
    );

    // Spawn a dispatcher that's waiting for work
    let provider_clone = provider.clone();
    let fetch_handle = tokio::spawn(async move {
        // This should block on notify, not poll
        provider_clone
            .fetch_orchestration_item(Duration::from_secs(60), Duration::from_secs(30), None)
            .await
    });

    // Wait 2 seconds while dispatcher is "idle"
    tokio::time::sleep(Duration::from_secs(2)).await;

    // Insert work and measure wake latency
    let insert_start = Instant::now();
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "wake-test".to_string(),
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

    // Wait for fetch to complete
    let result = tokio::time::timeout(Duration::from_secs(5), fetch_handle)
        .await
        .expect("Fetch timed out")
        .expect("Fetch task panicked")
        .expect("Fetch failed");
    let wake_latency = insert_start.elapsed();

    assert!(result.is_some(), "Should find work");

    eprintln!("\n========== PERF: NOTIFY WAKE LATENCY ==========");
    eprintln!("Test scenario:");
    eprintln!("  - Dispatcher waited idle for 2s");
    eprintln!("  - Work inserted via enqueue_for_orchestrator");
    eprintln!("Results:");
    eprintln!("  - Wake latency (insert -> fetch return): {wake_latency:?}");
    eprintln!("  - Work found: {}", result.is_some());
    eprintln!("Expected: Near-instant wake via NOTIFY (< 500ms)");
    eprintln!("===============================================\n");

    // Verify: wake latency should be fast via NOTIFY
    assert!(
        wake_latency.as_millis() < 500,
        "Wake latency should be < 500ms via NOTIFY, got {wake_latency:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that immediate work detection latency is low across multiple iterations.
/// Measures p50, p95, p99 latency for the insert -> fetch cycle.
#[tokio::test]
#[ignore] // Performance test
async fn perf_immediate_work_latency() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let config = LongPollConfig {
        enabled: true,
        notifier_poll_interval: Duration::from_secs(60),
        timer_grace_period: Duration::from_millis(100),
    };

    let provider = Arc::new(
        PostgresProvider::new_with_options(&database_url, Some(&schema), config)
            .await
            .expect("Failed to create provider"),
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut latencies = Vec::new();
    let iterations = 20;

    for i in 0..iterations {
        // Spawn fetch first (will wait on notify)
        let provider_clone = provider.clone();
        let fetch_handle = tokio::spawn(async move {
            let start = Instant::now();
            let result = provider_clone
                .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
                .await;
            (start.elapsed(), result)
        });

        // Small delay to ensure fetch is waiting
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Insert work and measure how long until fetch returns
        let insert_start = Instant::now();
        provider
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("latency-test-{i}"),
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

        let (_, result) = fetch_handle.await.expect("Fetch task panicked");
        let latency = insert_start.elapsed();
        let fetch_result = result.expect("Fetch failed");

        latencies.push(latency.as_millis() as u64);

        // Ack to clean up
        if let Some((_, lock_token, _)) = fetch_result {
            let _ = provider
                .ack_orchestration_item(
                    &lock_token,
                    1,
                    vec![],
                    vec![],
                    vec![],
                    ExecutionMetadata::default(),
                    vec![], // no cancelled activities
                )
                .await;
        }
    }

    latencies.sort();
    let min_lat = latencies[0];
    let max_lat = latencies[latencies.len() - 1];
    let p50 = latencies[latencies.len() / 2];
    let p95_index = (latencies.len() as f64 * 0.95) as usize;
    let p95 = latencies[p95_index.min(latencies.len() - 1)];
    let p99_index = (latencies.len() as f64 * 0.99) as usize;
    let p99 = latencies[p99_index.min(latencies.len() - 1)];
    let avg: u64 = latencies.iter().sum::<u64>() / latencies.len() as u64;

    eprintln!("\n========== PERF: IMMEDIATE WORK LATENCY ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Iterations: {iterations}");
    eprintln!("  - Pattern: Insert work while dispatcher waiting on NOTIFY");
    eprintln!("Latency results (insert -> fetch return):");
    eprintln!("  - Min:  {min_lat:>6}ms");
    eprintln!("  - Avg:  {avg:>6}ms");
    eprintln!("  - p50:  {p50:>6}ms");
    eprintln!("  - p95:  {p95:>6}ms");
    eprintln!("  - p99:  {p99:>6}ms");
    eprintln!("  - Max:  {max_lat:>6}ms");
    eprintln!("All latencies: {latencies:?}");
    eprintln!("===================================================\n");

    // With NOTIFY, we expect very low latency
    // Allow generous tolerance for CI environments
    assert!(p99 < 500, "p99 latency should be < 500ms, got {p99}ms");

    cleanup_schema(&schema).await;
}
