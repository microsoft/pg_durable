//! PostgreSQL Provider Stress Tests for Duroxide
//!
//! This library provides PostgreSQL-specific stress test implementations for Duroxide,
//! using the provider stress test infrastructure from the main crate.
//!
//! # Quick Start
//!
//! Run the stress test binary:
//!
//! ```bash
//! # Run parallel orchestrations stress test (default)
//! cargo run --release --package duroxide-pg-stress --bin pg-stress
//!
//! # Run large payload stress test
//! cargo run --release --package duroxide-pg-stress --bin pg-stress --test-type large-payload
//!
//! # Run all stress tests
//! cargo run --release --package duroxide-pg-stress --bin pg-stress --test-type all
//! ```

use duroxide::provider_stress_tests::large_payload::{
    run_large_payload_test_with_config, LargePayloadConfig,
};
use duroxide::provider_stress_tests::parallel_orchestrations::{
    run_parallel_orchestrations_test_with_config, ProviderStressFactory,
};
use duroxide::provider_stress_tests::StressTestConfig;
use duroxide::providers::Provider;
use duroxide_pg_opt::{LongPollConfig, PostgresProvider};
use std::sync::Arc;
use std::time::Duration;
use tracing::info;

// Re-export the stress test infrastructure for convenience
pub use duroxide::provider_stress_tests::{StressTestConfig as Config, StressTestResult};
// Re-export LargePayloadConfig for external use
pub use duroxide::provider_stress_tests::large_payload::LargePayloadConfig as LargePayloadConfigExport;

/// Factory for creating PostgreSQL providers for stress testing
pub struct PostgresStressFactory {
    database_url: String,
    use_unique_schemas: bool,
    long_poll_enabled: bool,
}

impl PostgresStressFactory {
    pub fn new(database_url: String) -> Self {
        Self {
            database_url,
            use_unique_schemas: true,
            long_poll_enabled: true,
        }
    }

    #[allow(dead_code)]
    pub fn with_shared_schema(mut self) -> Self {
        self.use_unique_schemas = false;
        self
    }

    /// Disable long-polling for stress testing
    pub fn with_long_poll_disabled(mut self) -> Self {
        self.long_poll_enabled = false;
        self
    }
}

#[async_trait::async_trait]
impl ProviderStressFactory for PostgresStressFactory {
    async fn create_provider(&self) -> Arc<dyn Provider> {
        let schema_name = if self.use_unique_schemas {
            let guid = uuid::Uuid::new_v4().to_string();
            let suffix = &guid[guid.len() - 8..];
            format!("stress_test_{suffix}")
        } else {
            "stress_test_shared".to_string()
        };

        info!(
            "Creating PostgreSQL provider with schema: {}, long_poll: {}",
            schema_name, self.long_poll_enabled
        );

        let config = LongPollConfig {
            enabled: self.long_poll_enabled,
            ..Default::default()
        };

        Arc::new(
            PostgresProvider::new_with_options(&self.database_url, Some(&schema_name), config)
                .await
                .expect("Failed to create PostgreSQL provider for stress test"),
        )
    }
}

/// Extract hostname from PostgreSQL connection URL
fn extract_hostname(url: &str) -> String {
    // Parse URL to extract hostname
    // Format: postgresql://user:pass@hostname:port/db
    if let Some(at_pos) = url.find('@') {
        let after_at = &url[at_pos + 1..];
        if let Some(colon_pos) = after_at.find(':') {
            let hostname = &after_at[..colon_pos];
            // Get first subdomain (e.g., "localhost" or "duroxide-pg" from "duroxide-pg.postgres.database.azure.com")
            if let Some(dot_pos) = hostname.find('.') {
                return hostname[..dot_pos].to_string();
            }
            return hostname.to_string();
        }
    }
    "unknown".to_string()
}

/// Run a single stress test with custom configuration
pub async fn run_single_test(
    database_url: String,
    duration_secs: u64,
    orch_conc: usize,
    worker_conc: usize,
    idle_sleep_ms: u64,
) -> Result<StressTestResult, Box<dyn std::error::Error>> {
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 20,
        duration_secs,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: orch_conc,
        worker_concurrency: worker_conc,
        wait_timeout_secs: 60,
    };

    // We need to create our own runtime with custom options
    // since the stress test framework hardcodes dispatcher_idle_sleep
    let provider = factory.create_provider().await;

    use duroxide::runtime::registry::ActivityRegistry;
    use duroxide::runtime::RuntimeOptions;
    use duroxide::OrchestrationRegistry;
    use duroxide::{ActivityContext, OrchestrationContext};

    let activity_registry = ActivityRegistry::builder()
        .register(
            "StressTask",
            |_ctx: ActivityContext, input: String| async move {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                Ok(format!("done: {input}"))
            },
        )
        .build();

    let orchestration = |ctx: OrchestrationContext, input: String| async move {
        let task_count: usize = serde_json::from_str::<serde_json::Value>(&input)
            .ok()
            .and_then(|v| {
                v.get("task_count")
                    .and_then(|tc| tc.as_u64())
                    .map(|n| n as usize)
            })
            .unwrap_or(5);

        let mut handles = Vec::new();
        for i in 0..task_count {
            handles.push(ctx.schedule_activity("StressTask", format!("task-{i}")));
        }
        for handle in handles {
            handle.await?;
        }
        Ok("done".to_string())
    };

    let orchestration_registry = OrchestrationRegistry::builder()
        .register("FanoutWorkflow", orchestration)
        .build();

    // Use custom runtime options with specified poll interval
    let options = RuntimeOptions {
        dispatcher_min_poll_interval: Duration::from_millis(idle_sleep_ms),
        orchestration_concurrency: orch_conc,
        worker_concurrency: worker_conc,
        ..Default::default()
    };

    let rt = duroxide::runtime::Runtime::start_with_options(
        provider.clone(),
        activity_registry,
        orchestration_registry,
        options,
    )
    .await;

    // Run the test
    let client = Arc::new(duroxide::Client::new(provider.clone()));
    let launched = Arc::new(tokio::sync::Mutex::new(0_usize));
    let completed = Arc::new(tokio::sync::Mutex::new(0_usize));
    let start_time = std::time::Instant::now();
    let end_time = start_time + std::time::Duration::from_secs(duration_secs);

    let mut instance_id = 0_usize;

    loop {
        if std::time::Instant::now() >= end_time {
            break;
        }

        let current_launched = *launched.lock().await;
        if current_launched >= config.max_concurrent {
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            continue;
        }

        instance_id += 1;
        let instance = format!("bench-{instance_id}");
        *launched.lock().await += 1;

        let client_clone = Arc::clone(&client);
        let completed_clone = Arc::clone(&completed);

        tokio::spawn(async move {
            let input = serde_json::json!({"task_count": 5}).to_string();
            if client_clone
                .start_orchestration(&instance, "FanoutWorkflow", input)
                .await
                .is_ok()
            {
                if let Ok(duroxide::OrchestrationStatus::Completed { .. }) = client_clone
                    .wait_for_orchestration(&instance, std::time::Duration::from_secs(60))
                    .await
                {
                    *completed_clone.lock().await += 1;
                }
            }
        });

        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    // Wait for stragglers
    tokio::time::sleep(std::time::Duration::from_secs(10)).await;

    let total_launched = *launched.lock().await;
    let total_completed = *completed.lock().await;
    let total_time = start_time.elapsed();

    rt.shutdown(None).await;

    Ok(StressTestResult {
        launched: total_launched,
        completed: total_completed,
        failed: total_launched - total_completed,
        failed_infrastructure: 0,
        failed_configuration: 0,
        failed_application: 0,
        total_time,
        orch_throughput: total_completed as f64 / total_time.as_secs_f64(),
        activity_throughput: (total_completed * config.tasks_per_instance) as f64
            / total_time.as_secs_f64(),
        avg_latency_ms: if total_completed > 0 {
            total_time.as_millis() as f64 / total_completed as f64
        } else {
            0.0
        },
    })
}

/// Run the parallel orchestrations stress test suite for PostgreSQL
pub async fn run_test_suite(
    database_url: String,
    duration_secs: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let hostname = extract_hostname(&database_url);

    info!("=== Duroxide PostgreSQL Stress Test Suite ===");
    info!("Database: {}", mask_password(&database_url));
    info!("Hostname: {}", hostname);
    info!("Duration: {} seconds per test", duration_secs);

    // Use 8:8 configuration as requested
    let concurrency_combos = vec![(8, 8)];

    let mut results = Vec::new();

    let factory = PostgresStressFactory::new(database_url);

    for (orch_conc, worker_conc) in &concurrency_combos {
        let config = StressTestConfig {
            max_concurrent: 20,
            duration_secs,
            tasks_per_instance: 5,
            activity_delay_ms: 10,
            orch_concurrency: *orch_conc,
            worker_concurrency: *worker_conc,
            wait_timeout_secs: 60,
        };

        info!(
            "\n--- Running PostgreSQL stress test (orch={}, worker={}) ---",
            orch_conc, worker_conc
        );

        let result = run_parallel_orchestrations_test_with_config(&factory, config).await?;

        info!(
            "Completed: {}, Failed: {}, Success Rate: {:.2}%",
            result.completed,
            result.failed,
            result.success_rate()
        );
        info!(
            "Throughput: {:.2} orch/sec, {:.2} activities/sec",
            result.orch_throughput, result.activity_throughput
        );
        info!("Average latency: {:.2}ms", result.avg_latency_ms);

        results.push((
            "PostgreSQL".to_string(),
            format!("{orch_conc}:{worker_conc}"),
            result,
        ));
    }

    // Print comparison table
    info!("\n=== Stress Test Results Summary ===\n");
    duroxide::provider_stress_tests::print_comparison_table(&results);

    // Validate all tests passed
    for (provider, config, result) in &results {
        if result.success_rate() < 100.0 {
            return Err(format!(
                "Stress test {} {} had failures: {:.2}% success rate",
                provider,
                config,
                result.success_rate()
            )
            .into());
        }
    }

    info!("\n✅ All stress tests passed!");

    // Return hostname for result tracking
    Ok(())
}

/// Get the results filename based on database hostname
pub fn get_results_filename(database_url: &str) -> String {
    let hostname = extract_hostname(database_url);
    format!("stress-test-results-{hostname}.md")
}

fn mask_password(url: &str) -> String {
    if let Some(at_pos) = url.find('@') {
        if let Some(colon_pos) = url[..at_pos].rfind(':') {
            let mut masked = url.to_string();
            masked.replace_range(colon_pos + 1..at_pos, "***");
            return masked;
        }
    }
    url.to_string()
}

/// Available stress test types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StressTestType {
    /// Parallel orchestrations test (fan-out/fan-in pattern)
    Parallel,
    /// Large payload test (memory and history management)
    LargePayload,
    /// All available stress tests
    All,
}

impl std::str::FromStr for StressTestType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "parallel" => Ok(StressTestType::Parallel),
            "large-payload" | "largepayload" | "large_payload" => Ok(StressTestType::LargePayload),
            "all" => Ok(StressTestType::All),
            _ => Err(format!(
                "Unknown test type '{s}'. Valid options: parallel, large-payload, all"
            )),
        }
    }
}

/// Check if the database URL points to localhost
fn is_localhost_db(database_url: &str) -> bool {
    database_url.contains("localhost") || database_url.contains("127.0.0.1")
}

/// Run the large payload stress test suite for PostgreSQL
///
/// # Remote Database Limitations
///
/// For remote databases, this test uses reduced intensity settings due to
/// higher latency (200-300ms per query). The full test configuration can
/// exceed the wait timeout with slow connections, so we use smaller payloads
/// and fewer activities/sub-orchestrations for remote databases.
///
/// Note: duroxide v0.1.7+ supports `wait_timeout_secs` in StressTestConfig,
/// which we set to 120 seconds to accommodate remote database latency.
pub async fn run_large_payload_suite(
    database_url: String,
    duration_secs: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let hostname = extract_hostname(&database_url);
    let is_local = is_localhost_db(&database_url);

    info!("=== Duroxide PostgreSQL Large Payload Stress Test ===");
    info!("Database: {}", mask_password(&database_url));
    info!("Hostname: {}", hostname);
    info!("Duration: {} seconds", duration_secs);
    info!(
        "Mode: {}",
        if is_local {
            "Local (full intensity)"
        } else {
            "Remote (reduced intensity)"
        }
    );

    let factory = PostgresStressFactory::new(database_url);

    // Configure large payload test with custom duration
    // Remote databases have higher latency, so reduce test intensity to avoid 60s timeout
    // The duroxide stress test framework has a hardcoded 60s wait_for_orchestration timeout.
    // With remote DBs (200-300ms latency), each fetch_history call takes 1-2s.
    // 20 activities + 5 sub-orchs = ~80 events × large payloads = easily exceeds 60s.
    let config = if is_local {
        // Full intensity for local databases
        LargePayloadConfig {
            base: StressTestConfig {
                max_concurrent: 5,
                duration_secs,
                tasks_per_instance: 1,
                activity_delay_ms: 5,
                orch_concurrency: 2,
                worker_concurrency: 2,
                wait_timeout_secs: 120,
            },
            small_payload_kb: 10,
            medium_payload_kb: 50,
            large_payload_kb: 100,
            activity_count: 20,
            sub_orch_count: 5,
        }
    } else {
        // Reduced intensity for remote databases to complete within timeout
        // - Smaller payloads (5/20/50 KB instead of 10/50/100 KB)
        // - Fewer activities (8 instead of 20)
        // - Fewer sub-orchestrations (2 instead of 5)
        // This keeps total history size manageable for high-latency connections
        LargePayloadConfig {
            base: StressTestConfig {
                max_concurrent: 3,
                duration_secs,
                tasks_per_instance: 1,
                activity_delay_ms: 5,
                orch_concurrency: 2,
                worker_concurrency: 2,
                wait_timeout_secs: 120,
            },
            small_payload_kb: 5,
            medium_payload_kb: 20,
            large_payload_kb: 50,
            activity_count: 8,
            sub_orch_count: 2,
        }
    };

    info!(
        "\n--- Running Large Payload stress test (payloads: {}KB/{}KB/{}KB, activities: {}, sub-orchs: {}) ---",
        config.small_payload_kb,
        config.medium_payload_kb,
        config.large_payload_kb,
        config.activity_count,
        config.sub_orch_count
    );

    let result = run_large_payload_test_with_config(&factory, config).await?;

    info!(
        "Completed: {}, Failed: {}, Success Rate: {:.2}%",
        result.completed,
        result.failed,
        result.success_rate()
    );
    info!(
        "Throughput: {:.2} orch/sec, {:.2} activities/sec",
        result.orch_throughput, result.activity_throughput
    );
    info!("Average latency: {:.2}ms", result.avg_latency_ms);

    // Print summary
    info!("\n=== Large Payload Stress Test Results Summary ===\n");
    let results = vec![(
        "PostgreSQL-LargePayload".to_string(),
        "2:2".to_string(),
        result.clone(),
    )];
    duroxide::provider_stress_tests::print_comparison_table(&results);

    // Validate test passed
    if result.success_rate() < 99.0 {
        return Err(format!(
            "Large payload stress test had failures: {:.2}% success rate",
            result.success_rate()
        )
        .into());
    }

    info!("\n✅ Large payload stress test passed!");
    Ok(())
}

/// Run all stress tests (parallel orchestrations and large payload)
pub async fn run_all_stress_tests(
    database_url: String,
    duration_secs: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    info!("=== Running ALL Stress Tests ===\n");

    // Run parallel orchestrations test
    run_test_suite(database_url.clone(), duration_secs).await?;

    info!("\n");

    // Run large payload test
    run_large_payload_suite(database_url, duration_secs).await?;

    info!("\n✅ All stress tests completed successfully!");
    Ok(())
}
