//! Regression tests for duroxide-pg bugs.
//!
//! Each test in this file reproduces a specific bug that was reported and fixed.
//! These tests ensure the bugs don't regress.

use duroxide::providers::{Provider, PruneOptions};
use duroxide::runtime::registry::ActivityRegistry;
use duroxide::runtime::{self, RuntimeOptions};
use duroxide::{ActivityContext, Client, OrchestrationContext, OrchestrationRegistry};
use duroxide_pg_opt::PostgresProvider;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use std::time::Duration;

mod common;

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

fn unique_schema_name() -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("regression_test_{suffix}")
}

async fn cleanup_schema(schema_name: &str) {
    let database_url = get_database_url();
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect for cleanup");

    sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
        .execute(&pool)
        .await
        .expect("Failed to drop schema");
}

// =============================================================================
// Bug: Deadlock in fetch_orchestration_item during parallel sub-orchestrations
// =============================================================================
//
// Reporter: pg_durable development team
// Date: December 7, 2025
// Reference: /Users/affandar/pg_durable/docs/DUROXIDE_PG_DEADLOCK_ISSUE.md
//
// Summary:
// When multiple sub-orchestrations complete and race to notify their parent,
// a deadlock can occur in fetch_orchestration_item due to INSERT ... ON CONFLICT
// on the instance_locks table. The deadlock happens at the B-tree index level
// when concurrent transactions try to insert/update different rows.
//
// Fix: Two-phase locking with instance-level advisory locks.
//   Phase 1: Peek (no lock) to find a candidate instance
//   Phase 2: Acquire pg_advisory_xact_lock(hashtext(instance_id))
//   Phase 3: Re-verify with FOR UPDATE to confirm availability
//
// This preserves parallelism (different instances process concurrently) while
// preventing deadlocks (same-instance operations are serialized).
//
// Also added retry logic in provider for transient deadlock errors (40P01).
//
// =============================================================================

/// Regression test for pg_durable deadlock issue.
///
/// This test creates a parent orchestration that spawns multiple children.
/// All children complete nearly simultaneously and race to notify the parent.
/// Before the fix, this would cause deadlocks ~50% of the time.
/// After the fix (advisory locks), no deadlocks should occur.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn test_parallel_suborchestrations_no_deadlock() {
    const NUM_PARENTS: usize = 20;
    const NUM_CHILDREN: usize = 5;
    const TIMEOUT_SECS: u64 = 60;

    let schema = unique_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");
    let store: Arc<dyn duroxide::providers::Provider> = Arc::new(provider);

    // Simple activity that returns immediately
    let activity_registry = ActivityRegistry::builder()
        .register(
            "DoWork",
            |_ctx: ActivityContext, input: String| async move { Ok(format!("done:{input}")) },
        )
        .build();

    // Child orchestration - does minimal work and completes
    let child = |ctx: OrchestrationContext, input: String| async move {
        let result = ctx.schedule_activity("DoWork", input).await?;
        Ok(result)
    };

    // Parent orchestration - spawns N children and waits for all
    let parent = |ctx: OrchestrationContext, input: String| async move {
        // Spawn multiple children that will all complete around the same time
        let mut futures = Vec::new();
        for i in 0..NUM_CHILDREN {
            let fut = ctx.schedule_sub_orchestration("Child", format!("{input}:{i}"));
            futures.push(fut);
        }

        // Wait for all children - this is where the deadlock used to occur
        // as all SubOrchCompleted messages arrive nearly simultaneously
        let results = ctx.join(futures).await;

        let outputs: Vec<String> = results.into_iter().filter_map(|out| out.ok()).collect();

        Ok(format!("completed:{}", outputs.len()))
    };

    let orchestration_registry = OrchestrationRegistry::builder()
        .register("Child", child)
        .register("Parent", parent)
        .build();

    // Use fast polling to increase chance of concurrent operations
    let options = RuntimeOptions {
        dispatcher_min_poll_interval: Duration::from_millis(1),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activity_registry,
        orchestration_registry,
        options,
    )
    .await;

    let client = Client::new(store.clone());

    // Start many parent orchestrations simultaneously
    for i in 0..NUM_PARENTS {
        client
            .start_orchestration(&format!("parent-{i}"), "Parent", format!("input-{i}"))
            .await
            .expect("Failed to start orchestration");
    }

    // Wait for all to complete
    let mut completed = 0;
    let mut failed = 0;

    for i in 0..NUM_PARENTS {
        let instance = format!("parent-{i}");
        match client
            .wait_for_orchestration(&instance, Duration::from_secs(TIMEOUT_SECS))
            .await
        {
            Ok(runtime::OrchestrationStatus::Completed { output, .. }) => {
                assert!(
                    output.contains(&format!("completed:{NUM_CHILDREN}")),
                    "Expected all {NUM_CHILDREN} children to complete, got: {output}"
                );
                completed += 1;
            }
            Ok(runtime::OrchestrationStatus::Failed { details, .. }) => {
                eprintln!("Parent {} failed: {}", instance, details.display_message());
                failed += 1;
            }
            Ok(status) => {
                eprintln!("Parent {instance} unexpected status: {status:?}");
                failed += 1;
            }
            Err(e) => {
                eprintln!("Parent {instance} error: {e}");
                failed += 1;
            }
        }
    }

    rt.shutdown(None).await;
    let _ = cleanup_schema(&schema).await;

    // All orchestrations should complete successfully
    assert_eq!(
        failed, 0,
        "Expected 0 failures, got {failed}. Completed: {completed}/{NUM_PARENTS}"
    );
    assert_eq!(
        completed, NUM_PARENTS,
        "Expected {NUM_PARENTS} completions, got {completed}"
    );
}

/// Stress test with higher parallelism.
///
/// Runs more orchestrations with more children to stress test the fix.
#[tokio::test(flavor = "multi_thread", worker_threads = 16)]
async fn test_parallel_suborchestrations_stress() {
    const NUM_PARENTS: usize = 30;
    const NUM_CHILDREN: usize = 4;
    const TIMEOUT_SECS: u64 = 90;

    let schema = unique_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");
    let store: Arc<dyn duroxide::providers::Provider> = Arc::new(provider);

    let activity_registry = ActivityRegistry::builder()
        .register("Work", |_ctx: ActivityContext, input: String| async move {
            Ok(input)
        })
        .build();

    let child = |ctx: OrchestrationContext, input: String| async move {
        ctx.schedule_activity("Work", input.clone()).await
    };

    let parent = |ctx: OrchestrationContext, _input: String| async move {
        let futures: Vec<_> = (0..NUM_CHILDREN)
            .map(|i| ctx.schedule_sub_orchestration("StressChild", format!("c{i}")))
            .collect();
        let results = ctx.join(futures).await;
        let count = results.iter().filter(|r| r.is_ok()).count();
        Ok(format!("done:{count}"))
    };

    let orchestration_registry = OrchestrationRegistry::builder()
        .register("StressChild", child)
        .register("StressParent", parent)
        .build();

    let options = RuntimeOptions {
        dispatcher_min_poll_interval: Duration::from_millis(1),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activity_registry,
        orchestration_registry,
        options,
    )
    .await;

    let client = Client::new(store.clone());

    // Start all parents
    for i in 0..NUM_PARENTS {
        client
            .start_orchestration(&format!("stress-{i}"), "StressParent", "go")
            .await
            .expect("Failed to start");
    }

    // Collect results
    let mut success = 0;
    for i in 0..NUM_PARENTS {
        if let Ok(runtime::OrchestrationStatus::Completed { output, .. }) = client
            .wait_for_orchestration(&format!("stress-{i}"), Duration::from_secs(TIMEOUT_SECS))
            .await
        {
            if output == format!("done:{NUM_CHILDREN}") {
                success += 1;
            }
        }
    }

    rt.shutdown(None).await;
    let _ = cleanup_schema(&schema).await;

    assert_eq!(
        success, NUM_PARENTS,
        "Expected all {NUM_PARENTS} to succeed, got {success}"
    );
}

// =============================================================================
// Bug: prune_executions_bulk excluded Running instances
// =============================================================================
//
// Reporter: Internal testing
// Date: January 6, 2026
// Reference: GitHub issue #50 (affandar/duroxide)
//
// Summary:
// When pruning executions in bulk, Running instances were excluded from the
// query filter. This meant that long-running orchestrations using ContinueAsNew
// could accumulate old terminal executions that would never be pruned.
//
// The stored procedure prune_executions already correctly protects Running
// executions (it never deletes current_execution_id or status='Running'),
// so the Rust layer should include Running instances in the bulk query.
//
// Fix: Changed prune_executions_bulk query from:
//   WHERE e.status IN ('Completed', 'Failed', 'ContinuedAsNew')
// To:
//   WHERE 1=1 (no status filter - let stored procedure handle safety)
//
// =============================================================================

/// Regression test: prune_executions on a Running instance should prune terminal executions.
///
/// This validates that:
/// 1. An instance with current_execution Running is included in prune_executions_bulk
/// 2. Old terminal executions (Completed/ContinuedAsNew) are correctly pruned
/// 3. The current Running execution is NOT pruned (safety guarantee)
#[tokio::test]
async fn test_prune_running_instance_prunes_terminal_executions() {
    let schema = unique_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");
    let store: Arc<dyn Provider> = Arc::new(provider);
    let admin = store.as_management_capability().unwrap();

    // Create an orchestration that uses ContinueAsNew to cycle through executions
    // After 3 iterations it stays running (simulating a long-running orchestration)
    let activity_registry = ActivityRegistry::builder()
        .register("Work", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("done:{input}"))
        })
        .build();

    let counter_orch = |ctx: OrchestrationContext, input: String| async move {
        let count: i32 = input.parse().unwrap_or(0);

        // Do some work
        ctx.schedule_activity("Work", format!("iteration-{count}"))
            .await?;

        if count < 3 {
            // Continue as new with incremented counter (creates new execution)
            return ctx.continue_as_new(format!("{}", count + 1)).await;
        } else {
            // Stay running - schedule a very long timer that will never fire during the test
            // This simulates a long-running orchestration
            ctx.schedule_timer(Duration::from_secs(3600)).await;
        }

        Ok(format!("completed-{count}"))
    };

    let orchestration_registry = OrchestrationRegistry::builder()
        .register("CounterOrch", counter_orch)
        .build();

    let options = RuntimeOptions {
        dispatcher_min_poll_interval: Duration::from_millis(10),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activity_registry,
        orchestration_registry,
        options,
    )
    .await;

    let client = Client::new(store.clone());
    let instance_id = "prune-running-test";

    // Start the orchestration
    client
        .start_orchestration(instance_id, "CounterOrch", "0")
        .await
        .expect("Failed to start orchestration");

    // Wait for it to reach the Running state at execution 4 (after 3 ContinueAsNew)
    // The orchestration cycles: exec1(ContinuedAsNew) -> exec2(ContinuedAsNew) -> exec3(ContinuedAsNew) -> exec4(Running)
    let timeout = Duration::from_secs(30);
    let deadline = std::time::Instant::now() + timeout;

    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;

        // Check instance info
        if let Ok(info) = admin.get_instance_info(instance_id).await {
            // Execution 4 means we've done 3 ContinueAsNew cycles
            if info.current_execution_id >= 4 && info.status == "Running" {
                break;
            }
        }

        if std::time::Instant::now() > deadline {
            panic!("Timed out waiting for orchestration to reach execution 4 in Running state");
        }
    }

    // Verify we have multiple executions (should have 4: three ContinuedAsNew + one Running)
    let executions = admin.list_executions(instance_id).await.unwrap();
    assert!(
        executions.len() >= 4,
        "Expected at least 4 executions, got {}",
        executions.len()
    );

    // Get info for each execution
    let mut terminal_count = 0;
    let mut running_count = 0;
    for exec_id in &executions {
        let exec_info = admin
            .get_execution_info(instance_id, *exec_id)
            .await
            .unwrap();
        if exec_info.status == "Running" {
            running_count += 1;
        } else {
            terminal_count += 1;
        }
    }

    assert!(
        terminal_count >= 3,
        "Expected at least 3 terminal executions (ContinuedAsNew), got {terminal_count}"
    );
    assert_eq!(
        running_count, 1,
        "Expected exactly 1 Running execution, got {running_count}"
    );

    // Get current execution ID before prune
    let info_before = admin.get_instance_info(instance_id).await.unwrap();
    let current_exec_before = info_before.current_execution_id;
    assert_eq!(info_before.status, "Running", "Instance should be Running");

    // Now prune, keeping only 1 execution (the current one)
    let prune_result = admin
        .prune_executions(
            instance_id,
            PruneOptions {
                keep_last: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();

    // Should have pruned the terminal executions (at least 3)
    assert!(
        prune_result.executions_deleted >= 3,
        "Expected at least 3 executions deleted, got {}",
        prune_result.executions_deleted
    );
    assert!(
        prune_result.events_deleted > 0,
        "Expected some events deleted, got 0"
    );

    // Verify the instance is still Running and current execution unchanged
    let info_after = admin.get_instance_info(instance_id).await.unwrap();
    assert_eq!(
        info_after.status, "Running",
        "Instance should still be Running after prune"
    );
    assert_eq!(
        info_after.current_execution_id, current_exec_before,
        "Current execution ID should not change after prune"
    );

    // Verify only 1 execution remains
    let executions_after = admin.list_executions(instance_id).await.unwrap();
    assert_eq!(
        executions_after.len(),
        1,
        "Expected 1 execution after prune (keep_last=1), got {}",
        executions_after.len()
    );

    // The remaining execution should be the current (Running) one
    assert_eq!(
        executions_after[0], current_exec_before,
        "Remaining execution should be the current one"
    );

    // Clean up
    rt.shutdown(None).await;
    let _ = cleanup_schema(&schema).await;
}

/// Regression test: prune_executions_bulk includes Running instances.
///
/// Tests that bulk pruning correctly processes Running instances and prunes
/// their terminal executions.
#[tokio::test]
async fn test_prune_executions_bulk_includes_running_instances() {
    use duroxide::providers::InstanceFilter;

    let schema = unique_schema_name();
    let database_url = get_database_url();

    let provider = PostgresProvider::new_with_schema(&database_url, Some(&schema))
        .await
        .expect("Failed to create provider");
    let store: Arc<dyn Provider> = Arc::new(provider);
    let admin = store.as_management_capability().unwrap();

    // Same setup as above - creates an orchestration with multiple executions
    let activity_registry = ActivityRegistry::builder()
        .register("Work", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("done:{input}"))
        })
        .build();

    let counter_orch = |ctx: OrchestrationContext, input: String| async move {
        let count: i32 = input.parse().unwrap_or(0);

        ctx.schedule_activity("Work", format!("iteration-{count}"))
            .await?;

        if count < 2 {
            return ctx.continue_as_new(format!("{}", count + 1)).await;
        } else {
            // Stay running - wait for an event that will never be raised
            let _: String = ctx.schedule_wait("never_fired").await;
        }

        Ok(format!("completed-{count}"))
    };

    let orchestration_registry = OrchestrationRegistry::builder()
        .register("BulkCounterOrch", counter_orch)
        .build();

    let options = RuntimeOptions {
        dispatcher_min_poll_interval: Duration::from_millis(10),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activity_registry,
        orchestration_registry,
        options,
    )
    .await;

    let client = Client::new(store.clone());
    let instance_id = "bulk-prune-running-test";

    client
        .start_orchestration(instance_id, "BulkCounterOrch", "0")
        .await
        .expect("Failed to start orchestration");

    // Wait for Running state at execution 3
    let timeout = Duration::from_secs(30);
    let deadline = std::time::Instant::now() + timeout;

    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;

        if let Ok(info) = admin.get_instance_info(instance_id).await {
            if info.current_execution_id >= 3 && info.status == "Running" {
                break;
            }
        }

        if std::time::Instant::now() > deadline {
            panic!("Timed out waiting for orchestration to reach execution 3");
        }
    }

    // Verify preconditions
    let executions_before = admin.list_executions(instance_id).await.unwrap();
    assert!(
        executions_before.len() >= 3,
        "Expected at least 3 executions before bulk prune"
    );

    let info_before = admin.get_instance_info(instance_id).await.unwrap();
    assert_eq!(info_before.status, "Running");

    // Bulk prune with instance filter
    let prune_result = admin
        .prune_executions_bulk(
            InstanceFilter {
                instance_ids: Some(vec![instance_id.to_string()]),
                ..Default::default()
            },
            PruneOptions {
                keep_last: Some(1),
                ..Default::default()
            },
        )
        .await
        .unwrap();

    // Key assertion: bulk prune should have processed this Running instance
    assert_eq!(
        prune_result.instances_processed, 1,
        "Bulk prune should process the Running instance"
    );
    assert!(
        prune_result.executions_deleted >= 2,
        "Expected at least 2 executions deleted via bulk prune"
    );

    // Verify instance still Running with correct execution
    let info_after = admin.get_instance_info(instance_id).await.unwrap();
    assert_eq!(info_after.status, "Running");
    assert_eq!(
        info_after.current_execution_id,
        info_before.current_execution_id
    );

    let executions_after = admin.list_executions(instance_id).await.unwrap();
    assert_eq!(executions_after.len(), 1);

    rt.shutdown(None).await;
    let _ = cleanup_schema(&schema).await;
}
