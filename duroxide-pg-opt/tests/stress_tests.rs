use duroxide::provider_stress_tests::parallel_orchestrations::run_parallel_orchestrations_test_with_config;
use duroxide::provider_stress_tests::StressTestConfig;
use duroxide_pg_stress::PostgresStressFactory;

#[cfg(feature = "db-metrics")]
use metrics_util::debugging::{DebugValue, DebuggingRecorder, Snapshotter};
#[cfg(feature = "db-metrics")]
use metrics_util::MetricKind;
#[cfg(feature = "db-metrics")]
use std::sync::OnceLock;

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    // Set pool size to 50 to handle high concurrency stress tests
    std::env::set_var("DUROXIDE_PG_POOL_MAX", "50");
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

/// Global metrics recorder - installed once, shared across all tests
#[cfg(feature = "db-metrics")]
static GLOBAL_RECORDER: OnceLock<Snapshotter> = OnceLock::new();

/// Get or install the global metrics recorder
#[cfg(feature = "db-metrics")]
fn get_global_snapshotter() -> &'static Snapshotter {
    GLOBAL_RECORDER.get_or_init(|| {
        let recorder = DebuggingRecorder::new();
        let snapshotter = recorder.snapshotter();
        // install() may fail if another test already installed it, that's OK
        let _ = recorder.install();
        snapshotter
    })
}

/// Metrics summary for comparing stress test runs
#[cfg(feature = "db-metrics")]
#[derive(Debug, Clone)]
struct DbMetricsSummary {
    total_db_calls: u64,
    sp_calls: u64,
    calls_by_operation: Vec<(String, u64)>,
    calls_by_sp_name: Vec<(String, u64)>,
    // Fetch effectiveness metrics
    orch_fetch_attempts: u64,
    orch_fetch_items: u64,
    orch_fetch_loaded: u64,
    orch_fetch_empty: u64,
    work_fetch_attempts: u64,
    work_fetch_items: u64,
    work_fetch_loaded: u64,
    work_fetch_empty: u64,
}

#[cfg(feature = "db-metrics")]
impl DbMetricsSummary {
    fn from_snapshotter(snapshotter: &Snapshotter) -> Self {
        let data = snapshotter.snapshot().into_vec();

        let mut total_db_calls = 0u64;
        let mut sp_calls = 0u64;
        let mut calls_by_operation: std::collections::HashMap<String, u64> =
            std::collections::HashMap::new();
        let mut calls_by_sp_name: std::collections::HashMap<String, u64> =
            std::collections::HashMap::new();

        // Fetch effectiveness counters
        let mut orch_fetch_attempts = 0u64;
        let mut orch_fetch_items = 0u64;
        let mut orch_fetch_loaded = 0u64;
        let mut orch_fetch_empty = 0u64;
        let mut work_fetch_attempts = 0u64;
        let mut work_fetch_items = 0u64;
        let mut work_fetch_loaded = 0u64;
        let mut work_fetch_empty = 0u64;

        for (key, _, _, value) in &data {
            if key.kind() != MetricKind::Counter {
                continue;
            }
            let name = key.key().name();

            if name == "duroxide.db.calls" {
                if let DebugValue::Counter(v) = value {
                    total_db_calls += v;
                    // Extract operation label
                    for label in key.key().labels() {
                        if label.key() == "operation" {
                            *calls_by_operation
                                .entry(label.value().to_string())
                                .or_default() += v;
                        }
                    }
                }
            } else if name == "duroxide.db.sp_calls" {
                if let DebugValue::Counter(v) = value {
                    sp_calls += v;
                    // Extract sp_name label
                    for label in key.key().labels() {
                        if label.key() == "sp_name" {
                            *calls_by_sp_name
                                .entry(label.value().to_string())
                                .or_default() += v;
                        }
                    }
                }
            } else if name == "duroxide.fetch.attempts" {
                if let DebugValue::Counter(v) = value {
                    // Extract fetch_type label
                    for label in key.key().labels() {
                        if label.key() == "fetch_type" {
                            match label.value() {
                                "orchestration" => orch_fetch_attempts += v,
                                "work_item" => work_fetch_attempts += v,
                                _ => {}
                            }
                        }
                    }
                }
            } else if name == "duroxide.fetch.items" {
                if let DebugValue::Counter(v) = value {
                    // Extract fetch_type label
                    for label in key.key().labels() {
                        if label.key() == "fetch_type" {
                            match label.value() {
                                "orchestration" => orch_fetch_items += v,
                                "work_item" => work_fetch_items += v,
                                _ => {}
                            }
                        }
                    }
                }
            } else if name == "duroxide.fetch.loaded" {
                if let DebugValue::Counter(v) = value {
                    for label in key.key().labels() {
                        if label.key() == "fetch_type" {
                            match label.value() {
                                "orchestration" => orch_fetch_loaded += v,
                                "work_item" => work_fetch_loaded += v,
                                _ => {}
                            }
                        }
                    }
                }
            } else if name == "duroxide.fetch.empty" {
                if let DebugValue::Counter(v) = value {
                    for label in key.key().labels() {
                        if label.key() == "fetch_type" {
                            match label.value() {
                                "orchestration" => orch_fetch_empty += v,
                                "work_item" => work_fetch_empty += v,
                                _ => {}
                            }
                        }
                    }
                }
            }
        }

        // Sort by count descending for readability
        let mut calls_by_operation: Vec<_> = calls_by_operation.into_iter().collect();
        calls_by_operation.sort_by(|a, b| b.1.cmp(&a.1));

        let mut calls_by_sp_name: Vec<_> = calls_by_sp_name.into_iter().collect();
        calls_by_sp_name.sort_by(|a, b| b.1.cmp(&a.1));

        Self {
            total_db_calls,
            sp_calls,
            calls_by_operation,
            calls_by_sp_name,
            orch_fetch_attempts,
            orch_fetch_items,
            orch_fetch_loaded,
            orch_fetch_empty,
            work_fetch_attempts,
            work_fetch_items,
            work_fetch_loaded,
            work_fetch_empty,
        }
    }

    /// Calculate fetch effectiveness ratio: items fetched / fetch attempts
    /// - Ratio < 1.0: Many empty fetches (polling inefficiency or racing)
    /// - Ratio = 1.0: Perfect 1:1 (every fetch gets exactly one item)
    /// - Ratio > 1.0: Batching is working well (one fetch gets multiple items)
    fn orch_fetch_effectiveness(&self) -> f64 {
        if self.orch_fetch_attempts == 0 {
            0.0
        } else {
            self.orch_fetch_items as f64 / self.orch_fetch_attempts as f64
        }
    }

    fn work_fetch_effectiveness(&self) -> f64 {
        if self.work_fetch_attempts == 0 {
            0.0
        } else {
            self.work_fetch_items as f64 / self.work_fetch_attempts as f64
        }
    }

    fn total_fetch_effectiveness(&self) -> f64 {
        let total_attempts = self.orch_fetch_attempts + self.work_fetch_attempts;
        let total_items = self.orch_fetch_items + self.work_fetch_items;
        if total_attempts == 0 {
            0.0
        } else {
            total_items as f64 / total_attempts as f64
        }
    }

    fn print(&self, test_name: &str, completed_orchs: usize, tasks_per_instance: usize) {
        let total_activities = completed_orchs * tasks_per_instance;
        let db_calls_per_orch = if completed_orchs > 0 {
            self.total_db_calls as f64 / completed_orchs as f64
        } else {
            0.0
        };

        println!("\n============================================================");
        println!("DB METRICS SUMMARY: {test_name}");
        println!("============================================================");
        println!("Completed orchestrations: {completed_orchs}");
        println!("Total activities:         {total_activities}");
        println!("Total DB calls:           {}", self.total_db_calls);
        println!("DB calls per orch:        {db_calls_per_orch:.1}");

        println!("\n--- Long-Poll Effectiveness ---");
        println!(
            "  Orchestration: {:>6} items / {:>6} attempts = {:.3} effectiveness",
            self.orch_fetch_items,
            self.orch_fetch_attempts,
            self.orch_fetch_effectiveness()
        );
        println!(
            "  Work Items:    {:>6} items / {:>6} attempts = {:.3} effectiveness",
            self.work_fetch_items,
            self.work_fetch_attempts,
            self.work_fetch_effectiveness()
        );
        println!(
            "  Combined:      {:>6} items / {:>6} attempts = {:.3} effectiveness",
            self.orch_fetch_items + self.work_fetch_items,
            self.orch_fetch_attempts + self.work_fetch_attempts,
            self.total_fetch_effectiveness()
        );

        println!("\n--- Loaded vs Empty Fetches ---");
        println!(
            "  Orchestration: {:>6} loaded / {:>6} empty ({:.1}% loaded)",
            self.orch_fetch_loaded,
            self.orch_fetch_empty,
            if self.orch_fetch_attempts > 0 {
                self.orch_fetch_loaded as f64 / self.orch_fetch_attempts as f64 * 100.0
            } else {
                0.0
            }
        );
        println!(
            "  Work Items:    {:>6} loaded / {:>6} empty ({:.1}% loaded)",
            self.work_fetch_loaded,
            self.work_fetch_empty,
            if self.work_fetch_attempts > 0 {
                self.work_fetch_loaded as f64 / self.work_fetch_attempts as f64 * 100.0
            } else {
                0.0
            }
        );

        println!("\nCalls by operation:");
        for (op, count) in &self.calls_by_operation {
            println!("  {op:20} {count:>10}");
        }
        println!("\nCalls by stored procedure:");
        for (sp, count) in &self.calls_by_sp_name {
            println!("  {sp:40} {count:>10}");
        }
        println!("============================================================\n");
    }

    /// Compute delta between two summaries (self - baseline)
    /// This allows isolating metrics for a specific test even when using a global recorder
    fn delta(&self, baseline: &DbMetricsSummary) -> DbMetricsSummary {
        // Compute delta for simple counters
        let total_db_calls = self.total_db_calls.saturating_sub(baseline.total_db_calls);
        let sp_calls = self.sp_calls.saturating_sub(baseline.sp_calls);
        let orch_fetch_attempts = self
            .orch_fetch_attempts
            .saturating_sub(baseline.orch_fetch_attempts);
        let orch_fetch_items = self
            .orch_fetch_items
            .saturating_sub(baseline.orch_fetch_items);
        let orch_fetch_loaded = self
            .orch_fetch_loaded
            .saturating_sub(baseline.orch_fetch_loaded);
        let orch_fetch_empty = self
            .orch_fetch_empty
            .saturating_sub(baseline.orch_fetch_empty);
        let work_fetch_attempts = self
            .work_fetch_attempts
            .saturating_sub(baseline.work_fetch_attempts);
        let work_fetch_items = self
            .work_fetch_items
            .saturating_sub(baseline.work_fetch_items);
        let work_fetch_loaded = self
            .work_fetch_loaded
            .saturating_sub(baseline.work_fetch_loaded);
        let work_fetch_empty = self
            .work_fetch_empty
            .saturating_sub(baseline.work_fetch_empty);

        // Compute delta for operation maps
        let baseline_ops: std::collections::HashMap<_, _> =
            baseline.calls_by_operation.iter().cloned().collect();
        let calls_by_operation: Vec<_> = self
            .calls_by_operation
            .iter()
            .map(|(op, count)| {
                let baseline_count = baseline_ops.get(op).copied().unwrap_or(0);
                (op.clone(), count.saturating_sub(baseline_count))
            })
            .filter(|(_, count)| *count > 0)
            .collect();

        let baseline_sps: std::collections::HashMap<_, _> =
            baseline.calls_by_sp_name.iter().cloned().collect();
        let mut calls_by_sp_name: Vec<_> = self
            .calls_by_sp_name
            .iter()
            .map(|(sp, count)| {
                let baseline_count = baseline_sps.get(sp).copied().unwrap_or(0);
                (sp.clone(), count.saturating_sub(baseline_count))
            })
            .filter(|(_, count)| *count > 0)
            .collect();
        calls_by_sp_name.sort_by(|a, b| b.1.cmp(&a.1));

        DbMetricsSummary {
            total_db_calls,
            sp_calls,
            calls_by_operation,
            calls_by_sp_name,
            orch_fetch_attempts,
            orch_fetch_items,
            orch_fetch_loaded,
            orch_fetch_empty,
            work_fetch_attempts,
            work_fetch_items,
            work_fetch_loaded,
            work_fetch_empty,
        }
    }
}

#[tokio::test]
#[ignore] // Run with: cargo test --test stress_tests -- --ignored
async fn stress_test_parallel_orchestrations_light() {
    // Use global snapshotter and compute delta for this test
    #[cfg(feature = "db-metrics")]
    let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 10,
        duration_secs: 5,
        tasks_per_instance: 3,
        activity_delay_ms: 5,
        orch_concurrency: 2,
        worker_concurrency: 2,
        wait_timeout_secs: 60,
    };
    #[allow(unused_variables)]
    let tasks_per_instance = config.tasks_per_instance;

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    #[cfg(feature = "db-metrics")]
    {
        let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
        let summary = current.delta(&baseline);
        summary.print(
            "stress_test_parallel_orchestrations_light",
            result.completed,
            tasks_per_instance,
        );
    }

    // Assert quality requirements
    assert_eq!(
        result.success_rate(),
        100.0,
        "Expected 100% success rate, got {:.2}%",
        result.success_rate()
    );
    assert_eq!(
        result.failed_infrastructure, 0,
        "Infrastructure failures detected: {}",
        result.failed_infrastructure
    );
    assert!(
        result.orch_throughput > 1.0,
        "Throughput too low: {:.2} orch/sec",
        result.orch_throughput
    );
}

#[tokio::test]
#[ignore]
async fn stress_test_parallel_orchestrations_standard() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 20,
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
        wait_timeout_secs: 60,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    assert_eq!(result.success_rate(), 100.0);
    assert_eq!(result.failed_infrastructure, 0);
}

#[tokio::test]
#[ignore]
async fn stress_test_high_concurrency() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 50,
        duration_secs: 30,
        tasks_per_instance: 10,
        activity_delay_ms: 10,
        orch_concurrency: 4,
        worker_concurrency: 4,
        wait_timeout_secs: 60,
    };
    #[allow(unused_variables)]
    let tasks_per_instance = config.tasks_per_instance;

    // Use global snapshotter and compute delta for this test
    #[cfg(feature = "db-metrics")]
    let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    #[cfg(feature = "db-metrics")]
    {
        let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
        let summary = current.delta(&baseline);
        summary.print(
            "stress_test_high_concurrency (long-poll ENABLED)",
            result.completed,
            tasks_per_instance,
        );
    }

    assert_eq!(result.success_rate(), 100.0);
    assert_eq!(result.failed_infrastructure, 0);

    // Validate throughput meets minimum requirements
    // Lowered from 2.0 to 1.5 to accommodate remote database latency
    assert!(
        result.orch_throughput > 1.5,
        "Throughput below minimum: {:.2} orch/sec",
        result.orch_throughput
    );
}

/// Same as stress_test_high_concurrency but with long-polling disabled
/// Used to diagnose if long-polling causes issues with remote databases
#[tokio::test]
#[ignore]
async fn stress_test_high_concurrency_no_longpoll() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url).with_long_poll_disabled();

    let config = StressTestConfig {
        max_concurrent: 50,
        duration_secs: 30,
        tasks_per_instance: 10,
        activity_delay_ms: 10,
        orch_concurrency: 4,
        worker_concurrency: 4,
        wait_timeout_secs: 60,
    };
    #[allow(unused_variables)]
    let tasks_per_instance = config.tasks_per_instance;

    // Use global snapshotter and compute delta for this test
    #[cfg(feature = "db-metrics")]
    let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    #[cfg(feature = "db-metrics")]
    {
        let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
        let summary = current.delta(&baseline);
        summary.print(
            "stress_test_high_concurrency_no_longpoll (long-poll DISABLED)",
            result.completed,
            tasks_per_instance,
        );
    }

    assert_eq!(result.success_rate(), 100.0);
    assert_eq!(result.failed_infrastructure, 0);

    // Lowered from 2.0 to 1.5 to accommodate remote database latency
    assert!(
        result.orch_throughput > 1.5,
        "Throughput below minimum: {:.2} orch/sec",
        result.orch_throughput
    );
}

/// Long-poll comparison test: LOW concurrency + HIGH activity delay
///
/// Key insight: Long-poll benefits show when there are IDLE PERIODS where
/// no work is available. In a high-concurrency test, work is always available
/// so long-poll never waits.
///
/// This test uses:
/// - max_concurrent: 3 (low - to allow idle gaps between orchestrations)
/// - activity_delay_ms: 500 (high - activities take time, creating wait periods)
///
/// Expected: Long-poll ENABLED should have FEWER DB calls because it waits
/// for notifications instead of polling repeatedly during idle periods.
#[tokio::test]
#[ignore]
async fn stress_test_longpoll_comparison_enabled() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url); // Long-poll ENABLED

    let config = StressTestConfig {
        max_concurrent: 3, // LOW - creates idle gaps
        duration_secs: 30,
        tasks_per_instance: 5,
        activity_delay_ms: 1000, // 500ms delay - activities take real time
        orch_concurrency: 2,
        worker_concurrency: 2,
        wait_timeout_secs: 60,
    };
    #[allow(unused_variables)]
    let tasks_per_instance = config.tasks_per_instance;

    // Use global snapshotter and compute delta for this test
    #[cfg(feature = "db-metrics")]
    let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    #[cfg(feature = "db-metrics")]
    {
        let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
        let summary = current.delta(&baseline);
        summary.print(
            "stress_test_longpoll_comparison_ENABLED (100ms activity delay)",
            result.completed,
            tasks_per_instance,
        );
    }

    assert_eq!(result.success_rate(), 100.0);
}

/// Long-poll comparison test: LOW concurrency + HIGH activity delay, long-poll DISABLED
///
/// This is the baseline to compare against. Without long-poll, the system will
/// poll repeatedly during idle periods, resulting in MORE DB calls.
#[tokio::test]
#[ignore]
async fn stress_test_longpoll_comparison_disabled() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url).with_long_poll_disabled();

    let config = StressTestConfig {
        max_concurrent: 3, // LOW - creates idle gaps
        duration_secs: 30,
        tasks_per_instance: 5,
        activity_delay_ms: 1000, // 1000ms delay - activities take real time
        orch_concurrency: 2,
        worker_concurrency: 2,
        wait_timeout_secs: 60,
    };
    #[allow(unused_variables)]
    let tasks_per_instance = config.tasks_per_instance;

    // Use global snapshotter and compute delta for this test
    #[cfg(feature = "db-metrics")]
    let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    #[cfg(feature = "db-metrics")]
    {
        let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
        let summary = current.delta(&baseline);
        summary.print(
            "stress_test_longpoll_comparison_DISABLED (100ms activity delay)",
            result.completed,
            tasks_per_instance,
        );
    }

    assert_eq!(result.success_rate(), 100.0);
}

#[tokio::test]
#[ignore]
async fn stress_test_connection_pool_limits() {
    let database_url = get_database_url();

    // Override pool size to small value
    std::env::set_var("DUROXIDE_PG_POOL_MAX", "5");

    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 30, // More than pool size
        duration_secs: 10,
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 4,
        worker_concurrency: 4,
        wait_timeout_secs: 60,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    // Should still succeed despite pool pressure
    assert_eq!(result.success_rate(), 100.0);
}

#[tokio::test]
#[ignore]
async fn stress_test_long_duration_stability() {
    let database_url = get_database_url();
    let factory = PostgresStressFactory::new(database_url);

    let config = StressTestConfig {
        max_concurrent: 20,
        duration_secs: 300, // 5 minutes
        tasks_per_instance: 5,
        activity_delay_ms: 10,
        orch_concurrency: 2,
        worker_concurrency: 2,
        wait_timeout_secs: 60,
    };

    let result = run_parallel_orchestrations_test_with_config(&factory, config)
        .await
        .expect("Stress test failed");

    assert_eq!(result.success_rate(), 100.0);

    // Validate sustained throughput
    assert!(
        result.orch_throughput > 1.5,
        "Throughput degraded over time: {:.2} orch/sec",
        result.orch_throughput
    );
}

/// Batch-style test to properly demonstrate long-poll benefits.
///
/// The standard stress tests use continuous pumping where work is ALWAYS available.
/// Long-poll benefits only show when there are idle periods between work availability.
///
/// This test uses a BATCH pattern:
/// 1. Launch N orchestrations  
/// 2. Wait for ALL to complete (orch dispatcher waits for activities)
/// 3. Repeat
///
/// During the wait phase, long-poll should reduce DB calls because it waits for
/// notifications instead of polling every 100ms.
mod batch_tests {
    use super::*;
    use duroxide::runtime::registry::ActivityRegistry;
    use duroxide::runtime::RuntimeOptions;
    use duroxide::{ActivityContext, OrchestrationContext, OrchestrationRegistry};
    use duroxide_pg_opt::{LongPollConfig, PostgresProvider};
    use std::sync::Arc;
    use std::time::Duration;

    async fn create_provider(database_url: &str, long_poll_enabled: bool) -> Arc<PostgresProvider> {
        let schema_name = format!(
            "batch_test_{}",
            uuid::Uuid::new_v4().to_string().replace("-", "_")
        );

        let long_poll_config = LongPollConfig {
            enabled: long_poll_enabled,
            ..Default::default()
        };

        let provider =
            PostgresProvider::new_with_options(database_url, Some(&schema_name), long_poll_config)
                .await
                .expect("Failed to create provider");

        Arc::new(provider)
    }

    async fn run_batch_test(
        database_url: &str,
        long_poll_enabled: bool,
        batch_size: usize,
        num_batches: usize,
        activity_delay_ms: u64,
    ) -> (usize, usize) {
        let provider = create_provider(database_url, long_poll_enabled).await;

        // Create activities with configurable delay
        let delay = activity_delay_ms;
        let activity_registry = ActivityRegistry::builder()
            .register(
                "SlowTask",
                move |_ctx: ActivityContext, input: String| async move {
                    tokio::time::sleep(Duration::from_millis(delay)).await;
                    Ok(format!("processed: {input}"))
                },
            )
            .build();

        // Simple orchestration that does one activity
        let orchestration_registry = OrchestrationRegistry::builder()
            .register(
                "BatchOrch",
                |ctx: OrchestrationContext, input: String| async move {
                    ctx.schedule_activity("SlowTask", input).await?;
                    Ok("done".to_string())
                },
            )
            .build();

        // Runtime with standard settings
        let options = RuntimeOptions {
            dispatcher_min_poll_interval: Duration::from_millis(100),
            orchestration_concurrency: 2,
            worker_concurrency: 2,
            ..Default::default()
        };

        let rt = duroxide::runtime::Runtime::start_with_options(
            provider.clone(),
            activity_registry,
            orchestration_registry,
            options,
        )
        .await;

        let client = duroxide::Client::new(provider.clone());

        let mut total_completed = 0;

        for batch in 0..num_batches {
            // Launch batch
            let mut instance_ids = Vec::new();
            for i in 0..batch_size {
                let instance_id = format!("batch-{batch}-orch-{i}");
                client
                    .start_orchestration(&instance_id, "BatchOrch", format!("input-{i}"))
                    .await
                    .expect("Failed to start orchestration");
                instance_ids.push(instance_id);
            }

            // Wait for all in batch to complete
            for instance_id in instance_ids {
                match client
                    .wait_for_orchestration(&instance_id, Duration::from_secs(60))
                    .await
                {
                    Ok(duroxide::OrchestrationStatus::Completed { .. }) => {
                        total_completed += 1;
                    }
                    other => {
                        println!("Orchestration {instance_id} did not complete: {other:?}");
                    }
                }
            }
        }

        rt.shutdown(None).await;

        (total_completed, num_batches * batch_size)
    }

    #[tokio::test]
    #[ignore]
    async fn batch_longpoll_enabled() {
        // Use global snapshotter and compute delta for this test
        #[cfg(feature = "db-metrics")]
        let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

        let database_url = get_database_url();
        let (completed, expected) = run_batch_test(
            &database_url,
            true,  // long-poll ENABLED
            5,     // batch_size
            10,    // num_batches
            30000, // activity_delay_ms - 30s per activity
        )
        .await;

        #[cfg(feature = "db-metrics")]
        {
            let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
            let summary = current.delta(&baseline);
            summary.print("batch_longpoll_ENABLED (batch=5, delay=30s)", completed, 1);
        }

        assert_eq!(completed, expected, "All orchestrations should complete");
    }

    #[tokio::test]
    #[ignore]
    async fn batch_longpoll_disabled() {
        // Use global snapshotter and compute delta for this test
        #[cfg(feature = "db-metrics")]
        let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

        let database_url = get_database_url();
        let (completed, expected) = run_batch_test(
            &database_url,
            false, // long-poll DISABLED
            5,     // batch_size
            10,    // num_batches
            30000, // activity_delay_ms - 30s per activity
        )
        .await;

        #[cfg(feature = "db-metrics")]
        {
            let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
            let summary = current.delta(&baseline);
            summary.print("batch_longpoll_DISABLED (batch=5, delay=30s)", completed, 1);
        }

        assert_eq!(completed, expected, "All orchestrations should complete");
    }

    /// Test with longer activity delay (5s) to exaggerate long-poll benefits
    #[tokio::test]
    #[ignore]
    async fn batch_longpoll_enabled_500ms() {
        #[cfg(feature = "db-metrics")]
        let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

        let database_url = get_database_url();
        let (completed, expected) = run_batch_test(
            &database_url,
            true, // long-poll ENABLED
            5,    // batch_size
            10,   // num_batches
            5000, // activity_delay_ms - 5s per activity
        )
        .await;

        #[cfg(feature = "db-metrics")]
        {
            let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
            let summary = current.delta(&baseline);
            summary.print(
                "batch_longpoll_ENABLED_v2 (batch=5, delay=5s)",
                completed,
                1,
            );
        }

        assert_eq!(completed, expected, "All orchestrations should complete");
    }

    #[tokio::test]
    #[ignore]
    async fn batch_longpoll_disabled_500ms() {
        #[cfg(feature = "db-metrics")]
        let baseline = DbMetricsSummary::from_snapshotter(get_global_snapshotter());

        let database_url = get_database_url();
        let (completed, expected) = run_batch_test(
            &database_url,
            false, // long-poll DISABLED
            5,     // batch_size
            10,    // num_batches
            5000,  // activity_delay_ms - 5s per activity
        )
        .await;

        #[cfg(feature = "db-metrics")]
        {
            let current = DbMetricsSummary::from_snapshotter(get_global_snapshotter());
            let summary = current.delta(&baseline);
            summary.print(
                "batch_longpoll_DISABLED_v2 (batch=5, delay=5s)",
                completed,
                1,
            );
        }

        assert_eq!(completed, expected, "All orchestrations should complete");
    }
}
