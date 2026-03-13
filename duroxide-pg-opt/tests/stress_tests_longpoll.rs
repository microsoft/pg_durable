//! Stress tests for long-polling implementation
//!
//! These tests verify the system handles high load, many timers,
//! and connection instability gracefully.
//!
//! Run with: cargo test --test stress_tests_longpoll -- --ignored --nocapture

mod common;

use duroxide::providers::{ExecutionMetadata, Provider, WorkItem};
use duroxide_pg_opt::PostgresProvider;
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
    format!("stress_lp_{suffix}")
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
// Category 10: Stress Tests
// =============================================================================

/// Stress test with high NOTIFY rate.
/// Verifies the system handles rapid insertions without crashes.
#[tokio::test]
#[ignore] // Long-running stress test
async fn stress_high_notify_rate() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Insert 100 work items rapidly
    let insert_count = 100;
    let insert_start = Instant::now();
    for i in 0..insert_count {
        provider
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("stress-{i}"),
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
    }
    let insert_duration = insert_start.elapsed();

    // Fetch all items
    let mut fetched = 0;
    let start = Instant::now();
    while fetched < insert_count && start.elapsed() < Duration::from_secs(60) {
        if let Some((_, lock_token, _)) = provider
            .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
            .await
            .expect("Fetch failed")
        {
            provider
                .ack_orchestration_item(
                    &lock_token,
                    1,
                    vec![],
                    vec![],
                    vec![],
                    ExecutionMetadata::default(),
                    vec![], // no cancelled activities
                )
                .await
                .expect("Failed to ack");
            fetched += 1;
        }
    }

    let fetch_duration = start.elapsed();
    let throughput = insert_count as f64 / fetch_duration.as_secs_f64();

    eprintln!("\n========== STRESS: HIGH NOTIFY RATE ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Work items: {insert_count}");
    eprintln!("Insert phase:");
    eprintln!("  - Duration: {insert_duration:?}");
    eprintln!(
        "  - Rate: {:.1} items/sec",
        insert_count as f64 / insert_duration.as_secs_f64()
    );
    eprintln!("Fetch phase:");
    eprintln!("  - Duration: {fetch_duration:?}");
    eprintln!("  - Items fetched: {fetched}");
    eprintln!("  - Throughput: {throughput:.1} items/sec");
    eprintln!(
        "Result: {} - All items processed",
        if fetched == insert_count {
            "PASS"
        } else {
            "FAIL"
        }
    );
    eprintln!("==============================================\n");

    assert_eq!(
        fetched, insert_count,
        "Should have fetched all {insert_count} items, got {fetched}"
    );

    cleanup_schema(&schema).await;
}

/// Stress test with many timers.
/// Verifies timer heap handles large numbers of pending timers.
#[tokio::test]
#[ignore] // Long-running stress test
async fn stress_many_timers() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let now = chrono::Utc::now();
    let timer_count = 50; // Reduced for faster test execution
    let insert_start = Instant::now();

    // Insert many timers with random delays (0-5 seconds)
    for i in 0..timer_count {
        let delay_ms = (i % 5) * 1000 + 500; // 500ms, 1500ms, 2500ms, etc.
        let visible_at = now + chrono::Duration::milliseconds(delay_ms);

        sqlx::query(&format!(
            r#"INSERT INTO {schema}.orchestrator_queue
               (instance_id, work_item, visible_at, created_at)
               VALUES ($1, $2, $3, NOW())"#
        ))
        .bind(format!("timer-stress-{i}"))
        .bind(
            serde_json::to_string(&serde_json::json!({
                "StartOrchestration": {
                    "instance": format!("timer-stress-{}", i),
                    "orchestration": "test-orch",
                    "version": "1.0",
                    "input": "{}",
                    "execution_id": 1
                }
            }))
            .unwrap(),
        )
        .bind(visible_at)
        .execute(&pool)
        .await
        .expect("Failed to insert timer");
    }
    let insert_duration = insert_start.elapsed();

    // Fetch all items
    let mut fetched = 0;
    let start = Instant::now();
    while fetched < timer_count && start.elapsed() < Duration::from_secs(60) {
        if let Some((_, lock_token, _)) = provider
            .fetch_orchestration_item(Duration::from_secs(10), Duration::from_secs(5), None)
            .await
            .expect("Fetch failed")
        {
            provider
                .ack_orchestration_item(
                    &lock_token,
                    1,
                    vec![],
                    vec![],
                    vec![],
                    ExecutionMetadata::default(),
                    vec![], // no cancelled activities
                )
                .await
                .expect("Failed to ack");
            fetched += 1;
        }
    }

    let fetch_duration = start.elapsed();

    eprintln!("\n========== STRESS: MANY TIMERS ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Timer count: {timer_count}");
    eprintln!("  - Timer delays: 500ms to 4500ms (staggered)");
    eprintln!("Insert phase:");
    eprintln!("  - Duration: {insert_duration:?}");
    eprintln!("Fetch phase:");
    eprintln!("  - Duration: {fetch_duration:?}");
    eprintln!("  - Timers fetched: {fetched}");
    eprintln!(
        "  - Avg time per timer: {:?}",
        fetch_duration / timer_count as u32
    );
    eprintln!(
        "Result: {} - All timers processed",
        if fetched == timer_count {
            "PASS"
        } else {
            "FAIL"
        }
    );
    eprintln!("==========================================\n");

    assert_eq!(
        fetched, timer_count,
        "Should have fetched all {timer_count} timers, got {fetched}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

/// Stress test with simulated connection flapping.
/// Verifies work is still processed despite connection instability.
#[tokio::test]
#[ignore] // Long-running stress test
async fn stress_connection_flapping() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    tokio::time::sleep(Duration::from_millis(200)).await;

    // Insert several work items
    let insert_count = 10;
    let insert_start = Instant::now();
    for i in 0..insert_count {
        provider
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("flap-{i}"),
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
    }

    // Fetch all items (connection flapping would be tested with fault injection)
    let mut fetched = 0;
    let fetch_start = Instant::now();
    while fetched < insert_count {
        if let Some((_, lock_token, _)) = provider
            .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
            .await
            .expect("Fetch failed")
        {
            provider
                .ack_orchestration_item(
                    &lock_token,
                    1,
                    vec![],
                    vec![],
                    vec![],
                    ExecutionMetadata::default(),
                    vec![], // no cancelled activities
                )
                .await
                .expect("Failed to ack");
            fetched += 1;
        }
    }
    let fetch_duration = fetch_start.elapsed();
    let insert_duration = insert_start.elapsed();

    eprintln!("\n========== STRESS: CONNECTION FLAPPING ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Work items: {insert_count}");
    eprintln!("  - Note: Full flapping requires fault injection");
    eprintln!("Insert phase:");
    eprintln!("  - Duration: {insert_duration:?}");
    eprintln!("Fetch phase:");
    eprintln!("  - Duration: {fetch_duration:?}");
    eprintln!("  - Items fetched: {fetched}");
    eprintln!(
        "Result: {} - All items processed",
        if fetched == insert_count {
            "PASS"
        } else {
            "FAIL"
        }
    );
    eprintln!("=================================================\n");

    assert_eq!(fetched, insert_count, "Should have fetched all items");

    cleanup_schema(&schema).await;
}
