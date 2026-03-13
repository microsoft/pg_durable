//! Tests for database metrics instrumentation.
//!
//! These tests verify that database operations are properly instrumented
//! when the `db-metrics` feature is enabled.

use duroxide_pg_opt::db_metrics::{record_db_call, DbCallTimer, DbOperation};

#[test]
fn test_operation_types() {
    // Verify all operation types have correct string representations
    assert_eq!(DbOperation::StoredProcedure.as_str(), "sp_call");
    assert_eq!(DbOperation::Select.as_str(), "select");
    assert_eq!(DbOperation::Insert.as_str(), "insert");
    assert_eq!(DbOperation::Update.as_str(), "update");
    assert_eq!(DbOperation::Delete.as_str(), "delete");
    assert_eq!(DbOperation::Ddl.as_str(), "ddl");
}

#[test]
fn test_record_db_call_compiles() {
    // These should compile and run without errors
    // When db-metrics is disabled, they should be no-ops
    record_db_call(DbOperation::StoredProcedure, Some("test_sp"));
    record_db_call(DbOperation::StoredProcedure, Some("fetch_work_item"));
    record_db_call(DbOperation::Select, None);
    record_db_call(DbOperation::Insert, None);
    record_db_call(DbOperation::Update, None);
    record_db_call(DbOperation::Delete, None);
    record_db_call(DbOperation::Ddl, None);
}

#[test]
fn test_db_call_timer_compiles() {
    // Timer should work whether db-metrics is enabled or not
    let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("test_sp"));
    let _timer2 = DbCallTimer::new(DbOperation::Select, None);
    // Timer drops here, recording duration if db-metrics enabled
}

#[test]
fn test_timer_drop_order() {
    // Verify timer can be created and dropped in correct order
    let timer1 = DbCallTimer::new(DbOperation::StoredProcedure, Some("outer"));
    {
        let _timer2 = DbCallTimer::new(DbOperation::StoredProcedure, Some("inner"));
        // inner timer drops first
    }
    drop(timer1);
    // outer timer drops last
}

/// Test that metrics can be verified when db-metrics feature is enabled.
/// This test requires the db-metrics feature to actually verify metric values.
#[cfg(feature = "db-metrics")]
mod with_metrics {
    use super::*;
    use duroxide_pg_opt::db_metrics::{record_fetch_attempt, record_fetch_success, FetchType};
    use metrics_util::debugging::{DebugValue, DebuggingRecorder};
    use metrics_util::MetricKind;

    /// Metrics snapshot helper that provides various query methods
    struct MetricsSnapshot {
        data: Vec<(
            metrics_util::CompositeKey,
            Option<metrics::Unit>,
            Option<metrics::SharedString>,
            DebugValue,
        )>,
    }

    impl MetricsSnapshot {
        fn from_recorder(recorder: &DebuggingRecorder) -> Self {
            let snapshotter = recorder.snapshotter();
            Self {
                data: snapshotter.snapshot().into_vec(),
            }
        }

        /// Sum all counter values by metric name (across all label combinations)
        fn sum_counters(&self, name: &str) -> u64 {
            let mut total = 0u64;
            for (key, _, _, value) in &self.data {
                if key.kind() == MetricKind::Counter && key.key().name() == name {
                    if let DebugValue::Counter(v) = value {
                        total += v;
                    }
                }
            }
            total
        }

        /// Find counter with specific labels
        fn find_counter_with_labels(&self, name: &str, labels: &[(&str, &str)]) -> Option<u64> {
            for (key, _, _, value) in &self.data {
                if key.kind() == MetricKind::Counter && key.key().name() == name {
                    let key_labels: Vec<_> = key
                        .key()
                        .labels()
                        .map(|l| (l.key().to_string(), l.value().to_string()))
                        .collect();
                    let matches = labels.iter().all(|(expected_key, expected_value)| {
                        key_labels
                            .iter()
                            .any(|(k, v)| k == *expected_key && v == *expected_value)
                    });
                    if matches {
                        if let DebugValue::Counter(v) = value {
                            return Some(*v);
                        }
                    }
                }
            }
            None
        }

        /// Get histogram values for a given metric with specific labels
        fn get_histogram_values(&self, name: &str, labels: &[(&str, &str)]) -> Vec<f64> {
            for (key, _, _, value) in &self.data {
                if key.kind() == MetricKind::Histogram && key.key().name() == name {
                    let key_labels: Vec<_> = key
                        .key()
                        .labels()
                        .map(|l| (l.key().to_string(), l.value().to_string()))
                        .collect();
                    let matches = labels.iter().all(|(expected_key, expected_value)| {
                        key_labels
                            .iter()
                            .any(|(k, v)| k == *expected_key && v == *expected_value)
                    });
                    if matches {
                        if let DebugValue::Histogram(samples) = value {
                            return samples.iter().map(|f| f.into_inner()).collect();
                        }
                    }
                }
            }
            vec![]
        }

        /// Debug: print all metrics
        #[allow(dead_code)]
        fn debug_print(&self) {
            for (key, _, _, value) in &self.data {
                let labels: Vec<_> = key
                    .key()
                    .labels()
                    .map(|l| format!("{}={}", l.key(), l.value()))
                    .collect();
                let kind = match key.kind() {
                    MetricKind::Counter => "Counter",
                    MetricKind::Gauge => "Gauge",
                    MetricKind::Histogram => "Histogram",
                };
                eprintln!(
                    "{} {} [{}] = {:?}",
                    kind,
                    key.key().name(),
                    labels.join(", "),
                    value
                );
            }
        }
    }

    #[test]
    fn test_metrics_recorded_with_debugging_recorder() {
        // Install a per-thread debugging recorder (doesn't affect global state)
        let recorder = DebuggingRecorder::new();

        // Install recorder temporarily for this test
        metrics::with_local_recorder(&recorder, || {
            // Record some database calls
            record_db_call(DbOperation::StoredProcedure, Some("fetch_work_item"));
            record_db_call(DbOperation::StoredProcedure, Some("fetch_work_item"));
            record_db_call(DbOperation::StoredProcedure, Some("append_history"));
            record_db_call(DbOperation::Select, None);
            record_db_call(DbOperation::Insert, None);
        });

        // Take a single snapshot and query it
        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // Verify counters were recorded
        assert_eq!(
            snapshot.sum_counters("duroxide.db.calls"),
            5,
            "Expected 5 total db calls"
        );

        // Verify SP-specific counter
        assert_eq!(
            snapshot.sum_counters("duroxide.db.sp_calls"),
            3,
            "Expected 3 SP calls"
        );

        // Verify operation-specific counts using labels
        assert_eq!(
            snapshot.find_counter_with_labels("duroxide.db.calls", &[("operation", "sp_call")]),
            Some(3),
            "Expected 3 sp_call operations"
        );

        assert_eq!(
            snapshot.find_counter_with_labels("duroxide.db.calls", &[("operation", "select")]),
            Some(1),
            "Expected 1 select operation"
        );

        assert_eq!(
            snapshot.find_counter_with_labels("duroxide.db.calls", &[("operation", "insert")]),
            Some(1),
            "Expected 1 insert operation"
        );
    }

    #[test]
    fn test_timer_records_duration_and_counter() {
        let recorder = DebuggingRecorder::new();

        metrics::with_local_recorder(&recorder, || {
            {
                let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("test_sp"));
                // Simulate some work (5ms)
                std::thread::sleep(std::time::Duration::from_millis(5));
            } // Timer drops here, recording duration AND counter
        });

        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // Verify the duration is approximately 5ms (allowing for timing jitter)
        let durations = snapshot.get_histogram_values(
            "duroxide.db.call_duration_ms",
            &[("operation", "sp_call"), ("sp_name", "test_sp")],
        );
        assert_eq!(durations.len(), 1, "Expected 1 duration sample");
        let duration_ms = durations[0];
        assert!(
            (5.0..100.0).contains(&duration_ms),
            "Expected duration ~5ms, got {duration_ms}ms"
        );

        // Verify counter was ALSO recorded by DbCallTimer (not just histogram)
        assert_eq!(
            snapshot.sum_counters("duroxide.db.sp_calls"),
            1,
            "Expected 1 SP call counter"
        );
        assert_eq!(
            snapshot.sum_counters("duroxide.db.calls"),
            1,
            "Expected 1 db call counter"
        );
    }

    #[test]
    fn test_timer_records_duration_for_multiple_calls() {
        let recorder = DebuggingRecorder::new();

        metrics::with_local_recorder(&recorder, || {
            // Call 1: fast operation
            {
                let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("fast_sp"));
                std::thread::sleep(std::time::Duration::from_millis(1));
            }

            // Call 2: slower operation
            {
                let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("slow_sp"));
                std::thread::sleep(std::time::Duration::from_millis(10));
            }

            // Call 3: another fast operation (same SP as call 1)
            {
                let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("fast_sp"));
                std::thread::sleep(std::time::Duration::from_millis(2));
            }

            // Call 4: non-SP operation
            {
                let _timer = DbCallTimer::new(DbOperation::Select, None);
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        });

        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // Verify fast_sp has 2 samples
        let fast_durations = snapshot.get_histogram_values(
            "duroxide.db.call_duration_ms",
            &[("operation", "sp_call"), ("sp_name", "fast_sp")],
        );
        assert_eq!(
            fast_durations.len(),
            2,
            "Expected 2 fast_sp duration samples"
        );

        // Verify slow_sp has 1 sample with longer duration
        let slow_durations = snapshot.get_histogram_values(
            "duroxide.db.call_duration_ms",
            &[("operation", "sp_call"), ("sp_name", "slow_sp")],
        );
        assert_eq!(
            slow_durations.len(),
            1,
            "Expected 1 slow_sp duration sample"
        );
        assert!(
            slow_durations[0] >= 10.0,
            "Expected slow_sp duration >= 10ms, got {}ms",
            slow_durations[0]
        );

        // Verify select has duration recorded
        let select_durations = snapshot
            .get_histogram_values("duroxide.db.call_duration_ms", &[("operation", "select")]);
        assert_eq!(
            select_durations.len(),
            1,
            "Expected 1 select duration sample"
        );

        // Verify counters
        assert_eq!(
            snapshot.sum_counters("duroxide.db.calls"),
            4,
            "Expected 4 total db calls"
        );
        assert_eq!(
            snapshot.sum_counters("duroxide.db.sp_calls"),
            3,
            "Expected 3 SP calls"
        );
    }

    #[test]
    fn test_per_sp_metrics() {
        let recorder = DebuggingRecorder::new();

        metrics::with_local_recorder(&recorder, || {
            record_db_call(DbOperation::StoredProcedure, Some("fetch_work_item"));
            record_db_call(DbOperation::StoredProcedure, Some("fetch_work_item"));
            record_db_call(DbOperation::StoredProcedure, Some("append_history"));
            record_db_call(DbOperation::StoredProcedure, Some("ack_worker"));
        });

        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // Verify we can find SP calls by sp_name label
        assert_eq!(
            snapshot.find_counter_with_labels(
                "duroxide.db.sp_calls",
                &[("sp_name", "fetch_work_item")]
            ),
            Some(2),
            "Expected 2 fetch_work_item calls"
        );

        assert_eq!(
            snapshot
                .find_counter_with_labels("duroxide.db.sp_calls", &[("sp_name", "append_history")]),
            Some(1),
            "Expected 1 append_history call"
        );

        assert_eq!(
            snapshot.find_counter_with_labels("duroxide.db.sp_calls", &[("sp_name", "ack_worker")]),
            Some(1),
            "Expected 1 ack_worker call"
        );
    }

    #[test]
    fn test_fetch_effectiveness_metrics() {
        let recorder = DebuggingRecorder::new();

        metrics::with_local_recorder(&recorder, || {
            // Simulate orchestration fetches: 10 attempts, 7 successful (70% effectiveness)
            for _ in 0..10 {
                record_fetch_attempt(FetchType::Orchestration);
            }
            for _ in 0..7 {
                record_fetch_success(FetchType::Orchestration, 1);
            }

            // Simulate work item fetches: 20 attempts, 15 successful (75% effectiveness)
            for _ in 0..20 {
                record_fetch_attempt(FetchType::WorkItem);
            }
            for _ in 0..15 {
                record_fetch_success(FetchType::WorkItem, 1);
            }
        });

        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // Verify orchestration fetch metrics
        assert_eq!(
            snapshot.find_counter_with_labels(
                "duroxide.fetch.attempts",
                &[("fetch_type", "orchestration")]
            ),
            Some(10),
            "Expected 10 orchestration fetch attempts"
        );
        assert_eq!(
            snapshot.find_counter_with_labels(
                "duroxide.fetch.items",
                &[("fetch_type", "orchestration")]
            ),
            Some(7),
            "Expected 7 orchestration items fetched"
        );

        // Verify work item fetch metrics
        assert_eq!(
            snapshot.find_counter_with_labels(
                "duroxide.fetch.attempts",
                &[("fetch_type", "work_item")]
            ),
            Some(20),
            "Expected 20 work item fetch attempts"
        );
        assert_eq!(
            snapshot
                .find_counter_with_labels("duroxide.fetch.items", &[("fetch_type", "work_item")]),
            Some(15),
            "Expected 15 work items fetched"
        );
    }

    #[test]
    fn test_fetch_effectiveness_with_batching() {
        let recorder = DebuggingRecorder::new();

        metrics::with_local_recorder(&recorder, || {
            // Simulate a batch fetch scenario where one fetch returns 5 items
            record_fetch_attempt(FetchType::WorkItem);
            record_fetch_success(FetchType::WorkItem, 5); // Batch of 5 items

            // Regular fetches
            record_fetch_attempt(FetchType::WorkItem);
            record_fetch_success(FetchType::WorkItem, 1);

            // Empty fetch (timed out)
            record_fetch_attempt(FetchType::WorkItem);
            // No success recorded - this is an empty fetch
        });

        let snapshot = MetricsSnapshot::from_recorder(&recorder);

        // 3 attempts total
        assert_eq!(
            snapshot.find_counter_with_labels(
                "duroxide.fetch.attempts",
                &[("fetch_type", "work_item")]
            ),
            Some(3),
            "Expected 3 work item fetch attempts"
        );

        // 6 items total (5 from batch + 1 regular)
        assert_eq!(
            snapshot
                .find_counter_with_labels("duroxide.fetch.items", &[("fetch_type", "work_item")]),
            Some(6),
            "Expected 6 work items fetched (batch + regular)"
        );

        // Effectiveness = 6/3 = 2.0 (above 1.0 due to batching)
    }

    #[test]
    fn test_fetch_type_as_str() {
        assert_eq!(FetchType::Orchestration.as_str(), "orchestration");
        assert_eq!(FetchType::WorkItem.as_str(), "work_item");
    }
}
