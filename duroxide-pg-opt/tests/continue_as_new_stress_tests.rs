//! Stress tests for continue-as-new functionality with PostgreSQL provider
//!
//! These tests verify that long-running orchestrations using continue-as-new
//! work correctly with multiple concurrent instances and many iterations.

use duroxide::runtime::registry::ActivityRegistry;
use duroxide::runtime::{self, OrchestrationStatus};
use duroxide::{ActivityContext, Client, EventKind, OrchestrationContext, OrchestrationRegistry};
use serde::{Deserialize, Serialize};
use std::sync::Once;
use std::time::Duration;
use tracing_subscriber::EnvFilter;

mod common;

static INIT_LOGGING: Once = Once::new();

fn init_test_logging() {
    INIT_LOGGING.call_once(|| {
        let env_filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_max_level(tracing::Level::INFO)
            .with_test_writer()
            .try_init();
    });
}

/// Test concurrent continue-as-new chains (stress test)
///
/// This test verifies that multiple orchestrations can run concurrently,
/// each using continue-as-new to chain through 10 executions.
#[tokio::test]
#[ignore]
async fn concurrent_continue_as_new_chains() {
    init_test_logging();
    let (store, schema_name) = common::create_postgres_store().await;

    let counter_orch = |ctx: OrchestrationContext, input: String| async move {
        let count: u64 = input.parse().unwrap_or(0);

        if count < 9 {
            // 10 executions: 0-8 continue, 9 completes
            return ctx.continue_as_new((count + 1).to_string()).await;
        } else {
            Ok(format!("completed at {count}"))
        }
    };

    let orchestrations = OrchestrationRegistry::builder()
        .register("ConcurrentCounter", counter_orch)
        .build();

    let activities = ActivityRegistry::builder().build();

    let rt = runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;

    let client = Client::new(store.clone());

    // Start 5 concurrent chains
    let instances: Vec<String> = (0..5).map(|i| format!("concurrent-chain-{i}")).collect();

    for instance in &instances {
        client
            .start_orchestration(instance, "ConcurrentCounter", "0")
            .await
            .unwrap();
    }

    // Wait for all to complete
    for instance in &instances {
        let status = client
            .wait_for_orchestration(instance, Duration::from_secs(30))
            .await
            .unwrap();

        match status {
            OrchestrationStatus::Completed { output, .. } => {
                assert_eq!(output, "completed at 9");
            }
            OrchestrationStatus::Failed { details, .. } => {
                panic!("Chain {} failed: {}", instance, details.display_message());
            }
            _ => panic!("Unexpected status for {instance}: {status:?}"),
        }
    }

    tracing::info!("✓ All 5 concurrent chains completed successfully");

    // Verify each chain has 10 executions
    let verify_start = std::time::Instant::now();
    for instance in &instances {
        for exec_id in 1..=10 {
            let hist = client
                .read_execution_history(instance, exec_id)
                .await
                .unwrap();

            assert!(
                !hist.is_empty(),
                "Chain {instance} execution {exec_id} has empty history"
            );
        }
    }
    let verify_duration = verify_start.elapsed();

    tracing::info!("✓ All executions verified for all chains");

    eprintln!("\n========== STRESS: CONCURRENT CONTINUE-AS-NEW CHAINS ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Concurrent chains: 5");
    eprintln!("  - Executions per chain: 10");
    eprintln!("Results:");
    eprintln!("  - All chains completed successfully");
    eprintln!("  - Total executions: 50 (5 chains × 10 executions)");
    eprintln!("  - Verification time: {verify_duration:?}");
    eprintln!("Result: PASS");
    eprintln!("===============================================================\n");

    rt.shutdown(None).await;
    common::cleanup_schema(&schema_name).await;
}

/// Test modeling a real-world instance actor pattern with multiple activities per iteration
///
/// This test simulates a health check actor that:
/// - Fetches instance connection details
/// - Tests the connection
/// - Records health check results
/// - Updates instance health status
/// - Waits 30 seconds
/// - Continues as new
///
/// The test runs 50 iterations per instance with 3 concurrent instances.
#[tokio::test]
#[ignore]
async fn instance_actor_pattern_stress_test() {
    init_test_logging();
    let (store, schema_name) = common::create_postgres_store().await;

    // Mock activity types (simplified versions of the real ones)
    #[derive(Serialize, Deserialize, Clone)]
    struct GetInstanceConnectionInput {
        k8s_name: String,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct GetInstanceConnectionOutput {
        found: bool,
        connection_string: Option<String>,
        state: Option<String>,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct TestConnectionInput {
        connection_string: String,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct TestConnectionOutput {
        version: String,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct RecordHealthCheckInput {
        k8s_name: String,
        status: String,
        postgres_version: Option<String>,
        response_time_ms: Option<i32>,
        error_message: Option<String>,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct RecordHealthCheckOutput {
        recorded: bool,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct UpdateInstanceHealthInput {
        k8s_name: String,
        health_status: String,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct UpdateInstanceHealthOutput {
        updated: bool,
    }

    #[derive(Serialize, Deserialize, Clone)]
    struct InstanceActorInput {
        k8s_name: String,
        orchestration_id: String,
        iteration: u64, // Track iteration for testing
    }

    // Mock activities
    let get_instance_connection = |_ctx: ActivityContext, input: String| async move {
        let parsed: GetInstanceConnectionInput =
            serde_json::from_str(&input).map_err(|e| format!("Parse error: {e}"))?;

        let output = GetInstanceConnectionOutput {
            found: true,
            connection_string: Some(format!("postgresql://localhost/db_{}", parsed.k8s_name)),
            state: Some("running".to_string()),
        };

        serde_json::to_string(&output).map_err(|e| format!("Serialize error: {e}"))
    };

    let test_connection = |_ctx: ActivityContext, input: String| async move {
        let parsed: TestConnectionInput =
            serde_json::from_str(&input).map_err(|e| format!("Parse error: {e}"))?;

        // Simulate connection test
        assert!(parsed.connection_string.starts_with("postgresql://"));

        let output = TestConnectionOutput {
            version: "PostgreSQL 16.1".to_string(),
        };

        serde_json::to_string(&output).map_err(|e| format!("Serialize error: {e}"))
    };

    let record_health_check = |_ctx: ActivityContext, input: String| async move {
        let _parsed: RecordHealthCheckInput =
            serde_json::from_str(&input).map_err(|e| format!("Parse error: {e}"))?;

        let output = RecordHealthCheckOutput { recorded: true };
        serde_json::to_string(&output).map_err(|e| format!("Serialize error: {e}"))
    };

    let update_instance_health = |_ctx: ActivityContext, input: String| async move {
        let _parsed: UpdateInstanceHealthInput =
            serde_json::from_str(&input).map_err(|e| format!("Parse error: {e}"))?;

        let output = UpdateInstanceHealthOutput { updated: true };
        serde_json::to_string(&output).map_err(|e| format!("Serialize error: {e}"))
    };

    // Instance actor orchestration (50 iterations for stress test)
    let instance_actor = |ctx: OrchestrationContext, input: String| async move {
        let mut input_data: InstanceActorInput =
            serde_json::from_str(&input).map_err(|e| format!("Failed to parse input: {e}"))?;

        ctx.trace_info(format!(
            "Instance actor iteration {} for: {} (orchestration: {})",
            input_data.iteration, input_data.k8s_name, input_data.orchestration_id
        ));

        // Exit after 50 iterations for stress test
        // Executions 1-49 (iteration 0-48) do full cycle, execution 50 (iteration 49) completes
        if input_data.iteration >= 49 {
            return Ok(format!(
                "completed after {} executions",
                input_data.iteration + 1
            ));
        }

        // Step 1: Get instance connection string from CMS
        let conn_info = ctx
            .schedule_activity_typed::<GetInstanceConnectionInput, GetInstanceConnectionOutput>(
                "cms-get-instance-connection",
                &GetInstanceConnectionInput {
                    k8s_name: input_data.k8s_name.clone(),
                },
            )
            .await
            .map_err(|e| format!("Failed to get instance connection: {e}"))?;

        // Step 2: Check if instance still exists
        if !conn_info.found {
            ctx.trace_info("Instance no longer exists in CMS, stopping instance actor");
            return Ok("instance not found".to_string());
        }

        let connection_string = match conn_info.connection_string {
            Some(conn) => conn,
            None => {
                ctx.trace_warn("No connection string available yet, skipping health check");

                // Wait and retry
                ctx.schedule_timer(std::time::Duration::from_millis(1000))
                    .await; // 30 seconds

                input_data.iteration += 1;
                let input_json = serde_json::to_string(&input_data)
                    .map_err(|e| format!("Failed to serialize input: {e}"))?;
                return ctx.continue_as_new(input_json).await;
            }
        };

        // Step 3: Test connection
        let health_result = ctx
            .schedule_activity_typed::<TestConnectionInput, TestConnectionOutput>(
                "test-connection",
                &TestConnectionInput {
                    connection_string: connection_string.clone(),
                },
            )
            .await;

        // Step 4: Determine health status
        let (status, postgres_version, error_message) = match health_result {
            Ok(output) => {
                ctx.trace_info("Health check passed");
                ("healthy", Some(output.version), None)
            }
            Err(e) => {
                ctx.trace_warn(format!("Health check failed: {e}"));
                ("unhealthy", None, Some(e.to_string()))
            }
        };

        // Step 5: Record health check
        let _record = ctx
            .schedule_activity_typed::<RecordHealthCheckInput, RecordHealthCheckOutput>(
                "cms-record-health-check",
                &RecordHealthCheckInput {
                    k8s_name: input_data.k8s_name.clone(),
                    status: status.to_string(),
                    postgres_version,
                    response_time_ms: Some(50),
                    error_message,
                },
            )
            .await
            .map_err(|e| format!("Failed to record health check: {e}"))?;

        // Step 6: Update instance health status
        let _update = ctx
            .schedule_activity_typed::<UpdateInstanceHealthInput, UpdateInstanceHealthOutput>(
                "cms-update-instance-health",
                &UpdateInstanceHealthInput {
                    k8s_name: input_data.k8s_name.clone(),
                    health_status: status.to_string(),
                },
            )
            .await
            .map_err(|e| format!("Failed to update instance health: {e}"))?;

        ctx.trace_info(format!("Health check complete, status: {status}"));

        // Step 7: Wait before next check
        ctx.schedule_timer(std::time::Duration::from_millis(1000))
            .await; // 30 seconds

        ctx.trace_info("Restarting instance actor with continue-as-new");

        // Step 8: Continue as new
        input_data.iteration += 1;
        let input_json = serde_json::to_string(&input_data)
            .map_err(|e| format!("Failed to serialize input: {e}"))?;

        ctx.continue_as_new(input_json).await
    };

    let orchestrations = OrchestrationRegistry::builder()
        .register("InstanceActor", instance_actor)
        .build();

    let activities = ActivityRegistry::builder()
        .register_typed("cms-get-instance-connection", get_instance_connection)
        .register_typed("test-connection", test_connection)
        .register_typed("cms-record-health-check", record_health_check)
        .register_typed("cms-update-instance-health", update_instance_health)
        .build();

    let rt = runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;

    let client = Client::new(store.clone());

    // Start 3 parallel instance actors
    let instances = vec![
        ("instance-actor-test-1", "test-instance-1", "orch-123-1"),
        ("instance-actor-test-2", "test-instance-2", "orch-123-2"),
        ("instance-actor-test-3", "test-instance-3", "orch-123-3"),
    ];

    for (instance_id, k8s_name, orch_id) in &instances {
        let input = InstanceActorInput {
            k8s_name: k8s_name.to_string(),
            orchestration_id: orch_id.to_string(),
            iteration: 0,
        };

        let input_json = serde_json::to_string(&input).unwrap();

        client
            .start_orchestration(*instance_id, "InstanceActor", &input_json)
            .await
            .unwrap();

        tracing::info!("Started instance actor: {}", instance_id);
    }

    // Wait for all 3 to complete (50 executions × 30s timer = 1500s theoretical max, use 30 min timeout)
    for (instance_id, _k8s_name, _orch_id) in &instances {
        let status = client
            .wait_for_orchestration(instance_id, Duration::from_secs(1800))
            .await
            .unwrap();

        match status {
            OrchestrationStatus::Completed { output, .. } => {
                assert!(output.contains("completed after 50 executions"));
                tracing::info!(
                    "✓ Instance actor {} completed after 50 executions",
                    instance_id
                );
            }
            OrchestrationStatus::Failed { details, .. } => {
                eprintln!(
                    "\n❌ Instance actor {} failed: {}\n",
                    instance_id,
                    details.display_message()
                );
                eprintln!("=== DUMPING ALL EXECUTION HISTORIES FOR {instance_id} ===\n");

                // Find how many executions exist
                let mut exec_id = 1;
                loop {
                    match client.read_execution_history(instance_id, exec_id).await {
                        Ok(hist) if !hist.is_empty() => {
                            eprintln!("--- Execution {exec_id} ---");
                            eprintln!("Events: {}", hist.len());
                            for (idx, event) in hist.iter().enumerate() {
                                let event_json = serde_json::to_string_pretty(event)
                                    .unwrap_or_else(|_| format!("{event:?}"));
                                eprintln!("  Event {}: {}", idx + 1, event_json);
                            }
                            eprintln!();
                            exec_id += 1;
                        }
                        _ => break,
                    }

                    // Safety limit
                    if exec_id > 100 {
                        eprintln!("(stopping dump at execution 100)");
                        break;
                    }
                }

                eprintln!("=== END OF HISTORY DUMP ===\n");
                panic!(
                    "Instance actor {} failed: {}",
                    instance_id,
                    details.display_message()
                );
            }
            _ => panic!("Unexpected status for {instance_id}: {status:?}"),
        }
    }

    tracing::info!("✓ All 3 instance actors completed successfully");

    // Verify each execution has the expected activities for all 3 instances
    for (instance_id, _k8s_name, _orch_id) in &instances {
        tracing::info!("Verifying executions for {}", instance_id);

        for exec_id in 1..=50 {
            let hist = client
                .read_execution_history(instance_id, exec_id)
                .await
                .unwrap();

            // Count activities scheduled in this execution
            let activity_count = hist
                .iter()
                .filter(|e| matches!(&e.kind, EventKind::ActivityScheduled { .. }))
                .count();

            // Executions 1-49 have full cycle (4 activities), execution 50 exits immediately (0 activities)
            if exec_id < 50 {
                assert!(
                    activity_count >= 4,
                    "{instance_id} execution {exec_id} should have at least 4 activities, has {activity_count}"
                );
            }

            // Verify OrchestrationStarted has proper version
            let started_event = hist
                .iter()
                .find(|e| matches!(&e.kind, EventKind::OrchestrationStarted { .. }));
            if let Some(event) = started_event {
                if let EventKind::OrchestrationStarted { name, version, .. } = &event.kind {
                    assert_eq!(name, "InstanceActor");
                    assert!(
                        version.starts_with("1."),
                        "{instance_id} execution {exec_id} has unexpected version: {version}"
                    );
                }
            }

            // Verify terminal event
            // Executions 1-49: continue-as-new, Execution 50: completes
            if exec_id < 50 {
                assert!(
                    hist.iter()
                        .any(|e| matches!(&e.kind, EventKind::OrchestrationContinuedAsNew { .. })),
                    "{instance_id} execution {exec_id} should have ContinuedAsNew"
                );
            } else {
                assert!(
                    hist.iter()
                        .any(|e| matches!(&e.kind, EventKind::OrchestrationCompleted { .. })),
                    "{instance_id} execution {exec_id} should have Completed"
                );
            }
        }

        tracing::info!("✓ All 50 executions verified for {}", instance_id);
    }

    tracing::info!("✓ All 3 instance actors completed successfully");
    tracing::info!("✓ Total: 150 executions (3 instances × 50 executions each)");
    tracing::info!("✓ Total: 588 activities (3 instances × 49 full cycles × 4 activities)");
    tracing::info!("✓ Total: 147 timers (3 instances × 49 full cycles)");

    eprintln!("\n========== STRESS: INSTANCE ACTOR PATTERN ==========");
    eprintln!("Test configuration:");
    eprintln!("  - Concurrent instance actors: 3");
    eprintln!("  - Executions per actor: 50");
    eprintln!("  - Activities per full cycle: 4");
    eprintln!("  - Timer per full cycle: 1 (30s simulated)");
    eprintln!("Results:");
    eprintln!("  - Total executions: 150");
    eprintln!("  - Total activities: 588 (49 cycles × 4 activities × 3 actors)");
    eprintln!("  - Total timers: 147 (49 cycles × 3 actors)");
    eprintln!("  - All actors completed successfully");
    eprintln!("Result: PASS");
    eprintln!("====================================================\n");

    rt.shutdown(None).await;
    common::cleanup_schema(&schema_name).await;
}
