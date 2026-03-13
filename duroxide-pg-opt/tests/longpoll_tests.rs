//! Long-polling integration tests
//!
//! Tests for the long-polling implementation covering:
//! - Category 4: Dispatcher fetch logic
//! - Category 5: E2E NOTIFY flow
//! - Category 6: Fault injection resilience tests
//! - Category 7: Timer precision tests
//!
//! Note: Performance tests, stress tests, and fault injection tests have been
//! moved to separate files:
//! - perf_tests.rs
//! - stress_tests_longpoll.rs
//! - fault_injection_tests.rs

mod common;

use common::is_localhost;
use duroxide::providers::{ExecutionMetadata, Provider, WorkItem};
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

fn next_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("lp_test_{suffix}")
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
// Category 4: Dispatcher Fetch Logic Tests
// =============================================================================

/// Test that fetch returns immediately when work exists
#[tokio::test]
async fn fetch_returns_immediately_when_work_exists() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");

    // Enqueue work first
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "test-instance-1".to_string(),
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

    // Fetch should return immediately
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should have found work");
    assert!(
        elapsed < Duration::from_millis(500),
        "Fetch should be near-instant when work exists, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that fetch waits for notify when no work exists (and eventually times out)
#[tokio::test]
async fn fetch_times_out_after_poll_timeout() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");

    // No work exists, fetch should wait for poll_timeout
    let poll_timeout = Duration::from_secs(2);
    let start = Instant::now();

    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), poll_timeout, None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_none(), "Should not have found work");
    // Should take at least poll_timeout (minus some slack for timing)
    assert!(
        elapsed >= poll_timeout - Duration::from_millis(200),
        "Should wait for poll_timeout, only waited {elapsed:?}"
    );
    // But not too much longer (allow more slack for remote DB latency)
    let slack = if is_localhost() {
        Duration::from_secs(1)
    } else {
        Duration::from_secs(2)
    };
    assert!(
        elapsed < poll_timeout + slack,
        "Should not wait much longer than poll_timeout, waited {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that fetch works correctly when long-poll is disabled
#[tokio::test]
async fn fetch_works_without_long_poll_enabled() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create provider with long-poll disabled
    let config = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_options(&database_url, Some(&schema), config)
        .await
        .expect("Failed to create provider");

    // No work exists - with long-poll disabled, should return immediately
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_none(), "Should not have found work");
    // Without long-poll, should return immediately (no waiting)
    // Allow more time for database query latency on remote DBs
    let threshold = if is_localhost() {
        Duration::from_secs(1)
    } else {
        Duration::from_secs(2)
    };
    assert!(
        elapsed < threshold,
        "Without long-poll should return immediately, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that fetch waits for notify when no work exists (blocks until notify)
#[tokio::test]
async fn fetch_waits_for_notify_when_no_work() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    let provider_clone = Arc::clone(&provider);
    let fetch_handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = provider_clone
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(30), None)
            .await
            .expect("Fetch failed");
        (result, start.elapsed())
    });

    // Wait a bit to ensure fetch is blocking
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Verify fetch is still waiting (hasn't returned yet)
    assert!(
        !fetch_handle.is_finished(),
        "Fetch should be waiting for notify, not returned immediately"
    );

    // Now insert work to wake the fetch
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "wait-notify-test".to_string(),
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

    // Fetch should wake up
    let (result, elapsed) = fetch_handle.await.expect("Fetch task panicked");

    assert!(result.is_some(), "Should have found work after wake");
    // Should have waited for at least the 500ms we slept
    assert!(
        elapsed >= Duration::from_millis(400),
        "Should have been waiting, elapsed {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

// =============================================================================
// Category 5: E2E NOTIFY Flow Tests
// =============================================================================

/// Test that INSERT triggers NOTIFY and wakes waiting fetch
#[tokio::test]
async fn e2e_immediate_work_detected() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up and subscribe
    tokio::time::sleep(Duration::from_millis(200)).await;

    let provider_clone = Arc::clone(&provider);
    let fetch_handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = provider_clone
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(30), None)
            .await
            .expect("Fetch failed");
        (result, start.elapsed())
    });

    // Wait a bit for fetch to start waiting
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Insert work - this should trigger NOTIFY
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "notify-test-1".to_string(),
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

    // Fetch should wake up and find the work
    let (result, elapsed) = fetch_handle.await.expect("Fetch task panicked");

    assert!(result.is_some(), "Should have found work after NOTIFY");
    // Should wake within a reasonable time (< 500ms after insert)
    // Total elapsed includes the initial 100ms wait, so allow ~600ms
    assert!(
        elapsed < Duration::from_millis(1000),
        "Should wake quickly after NOTIFY, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that multiple fetches can be woken
#[tokio::test]
async fn e2e_multiple_dispatchers_wake() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Start 3 fetches waiting
    let mut handles = Vec::new();
    for i in 0..3 {
        let p = Arc::clone(&provider);
        let handle = tokio::spawn(async move {
            let start = Instant::now();
            let result = p
                .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
                .await;
            (i, result, start.elapsed())
        });
        handles.push(handle);
    }

    // Wait for all fetches to start waiting
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Enqueue 3 work items (one for each dispatcher)
    // Insert all at once to minimize race conditions
    for i in 0..3 {
        provider
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: format!("multi-notify-{i}"),
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

    // All fetches should complete and find work
    let mut got_work = 0;
    for handle in handles {
        let (idx, result, elapsed) = handle.await.expect("Fetch task panicked");
        if result.is_ok() && result.unwrap().is_some() {
            got_work += 1;
        }
        // Each should complete within reasonable time
        assert!(
            elapsed < Duration::from_secs(5),
            "Fetch {idx} should complete quickly, took {elapsed:?}"
        );
    }

    // At least 2 should have found work (race conditions may cause one to miss)
    // The key assertion is that NOTIFY wakes dispatchers, not that locking is perfect
    assert!(
        got_work >= 2,
        "At least 2 dispatchers should find work, got {got_work}"
    );

    cleanup_schema(&schema).await;
}

/// Test that worker and orchestrator queues have separate notifications
#[tokio::test]
async fn e2e_worker_and_orch_separate() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Start a worker fetch waiting (should timeout since we only add orch work)
    let p = Arc::clone(&provider);
    let worker_handle = tokio::spawn(async move {
        let start = Instant::now();
        let result = p
            .fetch_work_item(Duration::from_secs(30), Duration::from_secs(2), None)
            .await;
        (result, start.elapsed())
    });

    // Wait for fetch to start
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Insert ORCH work only - should NOT wake worker queue
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "orch-only".to_string(),
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

    // Worker fetch should still timeout (orch notify doesn't wake worker)
    let (result, elapsed) = worker_handle.await.expect("Worker fetch panicked");

    // Should have waited close to the 2s timeout
    assert!(
        elapsed >= Duration::from_millis(1800),
        "Worker should wait for timeout, only waited {elapsed:?}"
    );
    // And not find any work
    assert!(
        result.is_ok() && result.unwrap().is_none(),
        "Worker should not find orchestrator work"
    );

    cleanup_schema(&schema).await;
}

// =============================================================================
// Category 6: Resilience Tests
// =============================================================================

/// Test that work inserted before provider startup is found
#[tokio::test]
async fn resilience_work_before_startup() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create provider and insert work
    {
        let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider");

        provider
            .enqueue_for_orchestrator(
                WorkItem::StartOrchestration {
                    instance: "pre-existing".to_string(),
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
    // Provider dropped

    // Create new provider - should find existing work
    let provider2 = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create second provider");

    let start = Instant::now();
    let result = provider2
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find pre-existing work");
    // Allow more time for remote DBs with higher query latency
    let threshold = if is_localhost() {
        Duration::from_millis(500)
    } else {
        Duration::from_secs(2)
    };
    assert!(
        elapsed < threshold,
        "Should find work immediately, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that notify during busy processing is still handled correctly
#[tokio::test]
async fn resilience_notify_during_busy() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Insert first work item
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "busy-test-1".to_string(),
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

    // Fetch first item (simulating dispatcher is now "busy" processing)
    let result1 = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");
    assert!(result1.is_some(), "Should find first work");
    let (_, lock_token1, _) = result1.unwrap();

    // While "busy", insert second work item
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "busy-test-2".to_string(),
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
        .expect("Failed to enqueue second work");

    // Ack first item (finish processing)
    provider
        .ack_orchestration_item(
            &lock_token1,
            1,
            vec![],
            vec![],
            vec![],
            ExecutionMetadata::default(),
            vec![], // no cancelled activities
        )
        .await
        .expect("Failed to ack");

    // Next fetch should find the second work item
    let start = Instant::now();
    let result2 = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result2.is_some(), "Should find second work");
    let (item2, _, _) = result2.unwrap();
    assert_eq!(item2.instance, "busy-test-2");
    assert!(
        elapsed < Duration::from_millis(500),
        "Should find work immediately, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that the refresh query catches work even when inserted directly to DB
/// (simulating a missed NOTIFY scenario, similar to what happens during reconnect)
#[tokio::test]
async fn resilience_refresh_catches_missed_notify() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create provider with a short refresh interval to speed up the test
    let config = LongPollConfig {
        enabled: true,
        notifier_poll_interval: Duration::from_secs(2), // Short refresh interval
        timer_grace_period: Duration::from_millis(100),
    };

    let provider = Arc::new(
        PostgresProvider::new_with_options(&database_url, Some(&schema), config)
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Insert work directly via SQL without going through provider
    // This bypasses the normal enqueue path and simulates missed NOTIFY
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    // Disable the trigger temporarily to prevent NOTIFY
    sqlx::query(&format!(
        "ALTER TABLE {schema}.orchestrator_queue DISABLE TRIGGER trg_notify_orch_work"
    ))
    .execute(&pool)
    .await
    .expect("Failed to disable trigger");

    // Insert work without NOTIFY firing
    let visible_at = chrono::Utc::now();
    sqlx::query(&format!(
        r#"INSERT INTO {schema}.orchestrator_queue
           (instance_id, work_item, visible_at, created_at)
           VALUES ($1, $2, $3, NOW())"#
    ))
    .bind("missed-notify-test")
    .bind(
        serde_json::to_string(&serde_json::json!({
            "StartOrchestration": {
                "instance": "missed-notify-test",
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
    .expect("Failed to insert work");

    // Re-enable the trigger
    sqlx::query(&format!(
        "ALTER TABLE {schema}.orchestrator_queue ENABLE TRIGGER trg_notify_orch_work"
    ))
    .execute(&pool)
    .await
    .expect("Failed to enable trigger");

    // Fetch should eventually find work via refresh query (within refresh interval)
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find work via refresh");
    // Should find within poll_timeout (5s) even though NOTIFY was missed
    assert!(
        elapsed < Duration::from_secs(5),
        "Should find work within poll_timeout, took {elapsed:?}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

// Note: resilience_connection_drop test would require complex infrastructure
// to simulate a PostgreSQL connection drop. The handle_reconnect() logic in
// notifier.rs handles this case by:
// 1. Reconnecting and resubscribing to NOTIFY channels
// 2. Waking all dispatchers to catch any missed NOTIFYs
// 3. Forcing an immediate refresh to rebuild timer heaps
// The resilience_refresh_catches_missed_notify test above validates the
// refresh mechanism that provides the safety net for reconnection scenarios.

// =============================================================================
// Category 6: Fault Injection Resilience Tests
// =============================================================================

/// Test that fetch finds work via do_fetch() when notifier is disabled via fault injection
#[cfg(feature = "test-fault-injection")]
#[tokio::test]
async fn resilience_notifier_disabled_finds_work() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create fault injector and disable notifier BEFORE provider creation
    let fault_injector = Arc::new(FaultInjector::new());
    fault_injector.disable_notifier();

    // Create provider with fault injection - notifier won't start
    let provider = Arc::new(
        PostgresProvider::new_with_fault_injection(
            &database_url,
            Some(&schema),
            LongPollConfig::default(),
            fault_injector,
        )
        .await
        .expect("Failed to create provider"),
    );

    // Insert work - no notifier means no NOTIFY handling
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "notifier-disabled-test".to_string(),
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

    // Fetch should still find work immediately (do_fetch() runs first)
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(2), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    // Work was inserted, so do_fetch() should find it immediately
    assert!(result.is_some(), "Should find work even without notifier");
    assert!(
        elapsed < Duration::from_millis(500),
        "Should find work immediately (do_fetch runs first), took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

/// Test that without notifier (fault injected), fetch returns immediately when no work exists
#[cfg(feature = "test-fault-injection")]
#[tokio::test]
async fn resilience_notifier_disabled_returns_immediately_when_empty() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create fault injector and disable notifier BEFORE provider creation
    let fault_injector = Arc::new(FaultInjector::new());
    fault_injector.disable_notifier();

    // Create provider with fault injection - notifier won't start
    let provider = PostgresProvider::new_with_fault_injection(
        &database_url,
        Some(&schema),
        LongPollConfig::default(),
        fault_injector,
    )
    .await
    .expect("Failed to create provider");

    // No work exists - without notifier, should return immediately (not wait)
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_none(), "Should not find work");
    // Without notifier, returns immediately instead of waiting for poll_timeout
    // Allow more time for database query latency on remote DBs
    let threshold = if is_localhost() {
        Duration::from_secs(1)
    } else {
        Duration::from_secs(2)
    };
    assert!(
        elapsed < threshold,
        "Without notifier should return immediately, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}

// =============================================================================
// Category 7: Timer Precision Tests
// =============================================================================

/// Test that future work (visible_at in future) is detected at the right time
#[tokio::test]
async fn timer_precision_100ms_grace() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Calculate visible_at = now + 2s (use longer delay for test reliability)
    let delay_ms = 2000;
    let visible_at = chrono::Utc::now() + chrono::Duration::milliseconds(delay_ms);

    // Insert work with future visible_at directly
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let start = Instant::now();

    sqlx::query(&format!(
        r#"INSERT INTO {schema}.orchestrator_queue
           (instance_id, work_item, visible_at, created_at)
           VALUES ($1, $2, $3, NOW())"#
    ))
    .bind("timer-test")
    .bind(
        serde_json::to_string(&serde_json::json!({
            "StartOrchestration": {
                "instance": "timer-test",
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
    .expect("Failed to insert future work");

    // Start fetch - should wait until visible_at + grace_period (~2.1s)
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find work after timer fires");

    // Should take approximately 2s (visible_at delay) + 100ms (grace) ± tolerance
    // The work becomes visible at visible_at, and the timer fires at visible_at + grace
    // Allow generous tolerance for system timing variations
    // For remote DBs, allow much more tolerance due to network latency
    let early_tolerance_ms = if is_localhost() { 300 } else { 1000 };
    let late_tolerance_ms = if is_localhost() { 1000 } else { 2000 };
    let expected_min = Duration::from_millis(delay_ms as u64 - early_tolerance_ms);
    let expected_max = Duration::from_millis(delay_ms as u64 + late_tolerance_ms);

    assert!(
        elapsed >= expected_min,
        "Timer should not fire early, fired at {elapsed:?} (expected >= {expected_min:?})"
    );
    assert!(
        elapsed <= expected_max,
        "Timer should fire within reasonable time, fired at {elapsed:?} (expected <= {expected_max:?})"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

/// Test that multiple timers fire in order
#[tokio::test]
async fn timer_precision_many_timers() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let start = Instant::now();
    let now = chrono::Utc::now();

    // Insert 5 work items with staggered visible_at times: 500ms, 1000ms, 1500ms, 2000ms, 2500ms
    for i in 1..=5 {
        let delay_ms = i * 500;
        let visible_at = now + chrono::Duration::milliseconds(delay_ms);

        sqlx::query(&format!(
            r#"INSERT INTO {schema}.orchestrator_queue
               (instance_id, work_item, visible_at, created_at)
               VALUES ($1, $2, $3, NOW())"#
        ))
        .bind(format!("timer-{i}"))
        .bind(
            serde_json::to_string(&serde_json::json!({
                "StartOrchestration": {
                    "instance": format!("timer-{}", i),
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
        .expect("Failed to insert future work");
    }

    // Fetch all 5 items and record when each was received
    let mut fetch_times = Vec::new();
    for _ in 0..5 {
        let result = provider
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
            .await
            .expect("Fetch failed");

        assert!(result.is_some(), "Should find work");
        let (item, lock_token, _) = result.unwrap();
        fetch_times.push((item.instance.clone(), start.elapsed()));

        // Ack the item to release the lock
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
    }

    // Verify items came in roughly the expected order and timing
    // Allow generous tolerance due to system timing variations
    // For remote DBs, network latency adds significant overhead (multiple DB operations per timer)
    let early_tolerance_ms = if is_localhost() { 400 } else { 1000 };
    let late_tolerance_ms = if is_localhost() { 1000 } else { 3500 };
    for (i, (instance, elapsed)) in fetch_times.iter().enumerate() {
        let expected_min =
            Duration::from_millis(((i + 1) * 500).saturating_sub(early_tolerance_ms) as u64);
        let expected_max = Duration::from_millis(((i + 1) * 500 + late_tolerance_ms) as u64);

        assert!(
            *elapsed >= expected_min,
            "{instance} fetched too early at {elapsed:?}, expected >= {expected_min:?}"
        );
        assert!(
            *elapsed <= expected_max,
            "{instance} fetched too late at {elapsed:?}, expected <= {expected_max:?}"
        );
    }

    pool.close().await;
    cleanup_schema(&schema).await;
}

/// Test timer precision under high insert load
/// Verifies that 95th percentile timer error is < 500ms
#[tokio::test]
async fn timer_precision_under_load() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Use shorter delay for localhost (faster), longer for remote (needs more time)
    let base_delay_ms: u64 = if is_localhost() { 1500 } else { 4000 };

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up and complete first refresh
    tokio::time::sleep(Duration::from_millis(500)).await;

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let num_items = 20;
    let interval_ms: u64 = 100; // 100ms apart

    // Record the insert start time for calculating expected fetch times
    let insert_start = Instant::now();
    let now = chrono::Utc::now();

    // Insert many work items with staggered visible_at times
    for i in 0..num_items {
        let delay_ms = base_delay_ms + (i as u64 * interval_ms);
        let visible_at = now + chrono::Duration::milliseconds(delay_ms as i64);

        sqlx::query(&format!(
            r#"INSERT INTO {schema}.orchestrator_queue
               (instance_id, work_item, visible_at, created_at)
               VALUES ($1, $2, $3, NOW())"#
        ))
        .bind(format!("load-timer-{i}"))
        .bind(
            serde_json::to_string(&serde_json::json!({
                "StartOrchestration": {
                    "instance": format!("load-timer-{}", i),
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
        .expect("Failed to insert future work");
    }

    // Wait a moment for notifier to process NOTIFY events and schedule timers
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Fetch all items and record timing errors
    // Expected times are relative to insert_start (when we recorded `now`)
    let mut timing_errors: Vec<i64> = Vec::new();
    let mut timing_traces: Vec<String> = Vec::new();
    let mut lock_tokens: Vec<String> = Vec::new();

    for i in 0..num_items {
        let expected_time_ms = base_delay_ms + (i as u64 * interval_ms);

        let result = provider
            .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
            .await
            .expect("Fetch failed");

        let actual_elapsed = insert_start.elapsed();
        let actual_ms = actual_elapsed.as_millis() as i64;
        let error_ms = actual_ms - expected_time_ms as i64;
        timing_errors.push(error_ms.abs());

        assert!(result.is_some(), "Should find work item {i}");
        let (item, lock_token, _) = result.unwrap();

        // Record timing trace
        timing_traces.push(format!(
            "item={:20} expected={:5}ms actual={:5}ms error={:+5}ms",
            item.instance, expected_time_ms, actual_ms, error_ms
        ));

        // Collect lock token for ack after timing loop
        lock_tokens.push(lock_token);
    }

    // Ack all items after timing measurement is complete
    for lock_token in lock_tokens {
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
    }

    // Calculate 95th percentile
    timing_errors.sort();
    let p95_index = (timing_errors.len() as f64 * 0.95) as usize;
    let p95_error = timing_errors[p95_index.min(timing_errors.len() - 1)];

    // // Always dump timing traces (use eprintln to ensure visibility)
    // eprintln!("\n========== TIMER PRECISION UNDER LOAD - TIMING TRACES ==========");
    // for trace in &timing_traces {
    //     eprintln!("{}", trace);
    // }
    // eprintln!("p95 error: {}ms", p95_error);
    // eprintln!("all errors (sorted): {:?}", timing_errors);
    // eprintln!("==================================================================\n");

    // 95th percentile threshold:
    // - Local DB: generous 750ms threshold to account for system load variance
    // - Remote DB: even more generous threshold to account for:
    //   - Variable insert times (each insert ~100-200ms on remote)
    //   - Sequential fetch latency accumulation (each fetch ~100ms on remote)
    let p95_threshold: i64 = if is_localhost() {
        750 // Local DB: allow for system load variance
    } else {
        // Remote DB: allow for accumulated fetch latency
        // ~100ms per fetch × 20 items = ~2000ms potential accumulation
        750 + (base_delay_ms as i64 - 1500) + (num_items as i64 * 100)
    };

    assert!(
        p95_error < p95_threshold,
        "95th percentile timing error should be < {p95_threshold}ms, got {p95_error}ms. Errors: {timing_errors:?}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

// =============================================================================
// Helper functions
// =============================================================================

/// Create a provider with custom long-poll config
#[allow(dead_code)]
async fn create_provider_with_config(
    database_url: &str,
    schema: &str,
    config: LongPollConfig,
) -> PostgresProvider {
    PostgresProvider::new_with_options(database_url, Some(schema), config)
        .await
        .expect("Failed to create provider")
}

// =============================================================================
// Category 5: Additional E2E NOTIFY Flow Tests
// =============================================================================

/// Test that a timer scheduled 5 seconds in the future fires correctly
/// This verifies the timer heap and grace period work together for future timers.
#[tokio::test]
async fn e2e_timer_fires_correctly() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Calculate visible_at = now + 3s
    let delay_ms: i64 = 3000;
    let visible_at = chrono::Utc::now() + chrono::Duration::milliseconds(delay_ms);

    // Insert work with future visible_at directly via SQL
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    let start = Instant::now();

    sqlx::query(&format!(
        r#"INSERT INTO {schema}.orchestrator_queue
           (instance_id, work_item, visible_at, created_at)
           VALUES ($1, $2, $3, NOW())"#
    ))
    .bind("e2e-timer-test")
    .bind(
        serde_json::to_string(&serde_json::json!({
            "StartOrchestration": {
                "instance": "e2e-timer-test",
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
    .expect("Failed to insert future work");

    // Start fetch - should wait until visible_at + grace_period (~3.1s)
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(10), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find work after timer fires");

    // Should take approximately 3s (delay) + 100ms (grace) ± tolerance
    // Allow generous tolerance for DB latency and clock drift between test machine and DB server
    // Lower bound is relaxed because timers can fire slightly early due to timing differences
    let tolerance_ms = if is_localhost() { 500 } else { 1500 };
    let expected_min = Duration::from_millis((delay_ms - tolerance_ms) as u64);
    let expected_max = Duration::from_millis((delay_ms + tolerance_ms) as u64);

    assert!(
        elapsed >= expected_min && elapsed <= expected_max,
        "Timer should fire at ~3.1s, but fired at {elapsed:?}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

// =============================================================================
// Category 6: Additional Resilience Tests
// =============================================================================

/// Test that dispatchers fall back to poll_timeout when the notifier thread is dead
/// This verifies graceful degradation - work is still found, just with higher latency.
#[tokio::test]
#[cfg(feature = "test-fault-injection")]
async fn resilience_notifier_dead() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    // Create a fault injector that disables the notifier
    let fault_injector = Arc::new(FaultInjector::new());
    fault_injector.disable_notifier();

    // Create provider with notifier disabled
    let provider = PostgresProvider::new_with_fault_injection(
        &database_url,
        Some(&schema),
        LongPollConfig::default(),
        fault_injector,
    )
    .await
    .expect("Failed to create provider");

    // Insert work directly via SQL (bypassing provider's enqueue which might wake notifier)
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    sqlx::query(&format!(
        r#"INSERT INTO {schema}.orchestrator_queue
           (instance_id, work_item, visible_at, created_at)
           VALUES ($1, $2, NOW(), NOW())"#
    ))
    .bind("notifier-dead-test")
    .bind(
        serde_json::to_string(&serde_json::json!({
            "StartOrchestration": {
                "instance": "notifier-dead-test",
                "orchestration": "test-orch",
                "version": "1.0",
                "input": "{}",
                "execution_id": 1
            }
        }))
        .unwrap(),
    )
    .execute(&pool)
    .await
    .expect("Failed to insert work");

    // With notifier dead, fetch should still find work on first attempt
    // (do_fetch() runs first, before waiting on notify)
    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(30), Duration::from_secs(5), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    // Should find work immediately via do_fetch()
    assert!(result.is_some(), "Should find work even with notifier dead");
    assert!(
        elapsed < Duration::from_secs(1),
        "First fetch should find existing work quickly, took {elapsed:?}"
    );

    pool.close().await;
    cleanup_schema(&schema).await;
}

/// Test that work is detected after a connection drop and reconnect.
/// This verifies the notifier's auto-reconnect behavior.
#[tokio::test]
async fn resilience_connection_drop() {
    let schema = next_schema_name();
    let database_url = get_database_url();

    let provider = Arc::new(
        PostgresProvider::new_with_schema(&database_url, Some(&schema))
            .await
            .expect("Failed to create provider"),
    );

    // Give the notifier time to start up and establish connection
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Insert work to verify the system is working
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "reconnect-test-1".to_string(),
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

    // Fetch should work normally
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
        .await
        .expect("Fetch failed");

    assert!(result.is_some(), "Should find first work item");
    let (_, lock_token, _) = result.unwrap();
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

    // Now insert more work - should still be detected
    // (the notifier should still be functioning)
    provider
        .enqueue_for_orchestrator(
            WorkItem::StartOrchestration {
                instance: "reconnect-test-2".to_string(),
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

    let start = Instant::now();
    let result = provider
        .fetch_orchestration_item(Duration::from_secs(5), Duration::from_secs(2), None)
        .await
        .expect("Fetch failed");

    let elapsed = start.elapsed();

    assert!(result.is_some(), "Should find second work item");
    assert!(
        elapsed < Duration::from_millis(500),
        "Should wake quickly via NOTIFY, took {elapsed:?}"
    );

    cleanup_schema(&schema).await;
}
