//! End-to-end tests for the activity session feature on PostgreSQL.
//!
//! Adapted from upstream duroxide `tests/session_e2e_tests.rs` and
//! `tests/scenarios/sessions.rs`, but using PostgreSQL (via duroxide-pg-opt)
//! instead of SQLite in-memory.
#![allow(clippy::unwrap_used)]
#![allow(clippy::expect_used)]

use duroxide::runtime::registry::ActivityRegistry;
use duroxide::runtime::{self, RuntimeOptions};
use duroxide::{ActivityContext, Client, OrchestrationContext, OrchestrationRegistry};
use semver::Version;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

mod common;

static INIT_LOGGING: std::sync::Once = std::sync::Once::new();

fn init_test_logging() {
    INIT_LOGGING.call_once(|| {
        use tracing_subscriber::EnvFilter;
        let env_filter =
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("debug"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_max_level(tracing::Level::INFO)
            .with_test_writer()
            .try_init();
    });
}

// ============================================================================
// 1. Basic session scheduling
// ============================================================================

/// Two activities on the same session_id complete in order.
#[tokio::test]
async fn test_session_activity_basic() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Echo", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("echo:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "SessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let r1 = ctx
                    .schedule_activity_on_session("Echo", "hello", "my-session")
                    .await?;
                let r2 = ctx
                    .schedule_activity_on_session("Echo", "world", "my-session")
                    .await?;
                Ok(format!("{r1}|{r2}"))
            },
        )
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-session-basic", "SessionOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-session-basic", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "echo:hello|echo:world");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 2. Session ID visible in ActivityContext
// ============================================================================

/// Verify `ActivityContext::session_id()` returns the correct session ID.
#[tokio::test]
async fn test_session_id_visible_in_activity_context() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let session_seen = Arc::new(AtomicBool::new(false));
    let session_seen_clone = session_seen.clone();

    let activities = ActivityRegistry::builder()
        .register(
            "CheckSession",
            move |ctx: ActivityContext, _input: String| {
                let seen = session_seen_clone.clone();
                async move {
                    if ctx.session_id() == Some("test-session-123") {
                        seen.store(true, Ordering::SeqCst);
                    }
                    Ok("ok".to_string())
                }
            },
        )
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "CheckSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                ctx.schedule_activity_on_session("CheckSession", "input", "test-session-123")
                    .await?;
                Ok("done".to_string())
            },
        )
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-ctx-session", "CheckSessionOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-ctx-session", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { .. } => {}
        other => panic!("Expected completed, got {:?}", other),
    }

    assert!(
        session_seen.load(Ordering::SeqCst),
        "Activity should see session_id 'test-session-123' in context"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 3. Mixed session and regular activities
// ============================================================================

/// Mix session-pinned and regular activities in the same orchestration.
#[tokio::test]
async fn test_mixed_session_and_regular_activities() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register(
            "SessionTask",
            |_ctx: ActivityContext, input: String| async move {
                Ok(format!("session:{input}"))
            },
        )
        .register(
            "RegularTask",
            |_ctx: ActivityContext, input: String| async move {
                Ok(format!("regular:{input}"))
            },
        )
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "MixedOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let r1 = ctx.schedule_activity("RegularTask", "a").await?;
                let r2 = ctx
                    .schedule_activity_on_session("SessionTask", "b", "sess-1")
                    .await?;
                let r3 = ctx.schedule_activity("RegularTask", "c").await?;
                Ok(format!("{r1}|{r2}|{r3}"))
            },
        )
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-mixed", "MixedOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-mixed", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "regular:a|session:b|regular:c");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 4. Multiple sessions in one orchestration
// ============================================================================

/// Two different session IDs in the same orchestration both complete.
#[tokio::test]
async fn test_multiple_sessions_in_orchestration() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register(
            "Task",
            |_ctx: ActivityContext, input: String| async move { Ok(input) },
        )
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "MultiSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let r1 = ctx
                    .schedule_activity_on_session("Task", "a", "session-A")
                    .await?;
                let r2 = ctx
                    .schedule_activity_on_session("Task", "b", "session-B")
                    .await?;
                let r3 = ctx
                    .schedule_activity_on_session("Task", "c", "session-A")
                    .await?;
                Ok(format!("{r1}|{r2}|{r3}"))
            },
        )
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-multi-session", "MultiSessionOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-multi-session", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "a|b|c");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 5. Session with worker_node_id
// ============================================================================

/// With worker_node_id set, multiple activities on the same session complete
/// without head-of-line blocking across worker_concurrency slots.
#[tokio::test]
async fn test_session_with_worker_node_id_completes() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Work", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("done:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("StableOrch", |ctx: OrchestrationContext, _input: String| async move {
            let r1 = ctx.schedule_activity_on_session("Work", "a", "stable-sess").await?;
            let r2 = ctx.schedule_activity_on_session("Work", "b", "stable-sess").await?;
            let r3 = ctx.schedule_activity_on_session("Work", "c", "stable-sess").await?;
            Ok(format!("{r1}|{r2}|{r3}"))
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 4,
        worker_node_id: Some("stable-pod-1".to_string()),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-stable-node", "StableOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-stable-node", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "done:a|done:b|done:c");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 6. Fan-out: concurrent session activities on the same session
// ============================================================================

/// Fan-out multiple concurrent session activities on the same session using `join3`.
#[tokio::test]
async fn test_session_fan_out_same_session() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let counter = Arc::new(AtomicUsize::new(0));
    let counter_clone = counter.clone();

    let activities = ActivityRegistry::builder()
        .register("FanTask", move |_ctx: ActivityContext, input: String| {
            let c = counter_clone.clone();
            async move {
                c.fetch_add(1, Ordering::SeqCst);
                Ok(format!("fan:{input}"))
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "FanOutOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let f1 =
                    ctx.schedule_activity_on_session("FanTask", "x", "fan-session");
                let f2 =
                    ctx.schedule_activity_on_session("FanTask", "y", "fan-session");
                let f3 =
                    ctx.schedule_activity_on_session("FanTask", "z", "fan-session");
                let (r1, r2, r3) = ctx.join3(f1, f2, f3).await;
                Ok(format!("{}|{}|{}", r1?, r2?, r3?))
            },
        )
        .build();

    // Use worker_node_id so all slots can serve the same session concurrently
    let options = RuntimeOptions {
        worker_concurrency: 4,
        worker_node_id: Some("fan-node".to_string()),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-fan-out", "FanOutOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-fan-out", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "fan:x|fan:y|fan:z");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    assert!(
        counter.load(Ordering::SeqCst) >= 3,
        "All 3 fan-out activities should have executed"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 7. Copilot SDK session pattern (simplified)
// ============================================================================

/// Models the durable-copilot-sdk pattern: an orchestration calls `runAgentTurn`
/// with session affinity, using `continue_as_new` for multi-turn conversations.
///
/// Simplified for PostgreSQL: starts 2 single-turn conversations and verifies
/// in-memory session state accumulates correctly.
#[tokio::test]
async fn test_copilot_sdk_session_pattern() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    // ── SessionManager: in-memory session cache ──
    struct SessionManager {
        sessions: std::sync::Mutex<HashMap<String, Vec<String>>>,
        create_count: AtomicUsize,
    }

    impl SessionManager {
        fn new() -> Self {
            Self {
                sessions: std::sync::Mutex::new(HashMap::new()),
                create_count: AtomicUsize::new(0),
            }
        }

        fn get_or_create(&self, session_id: &str) -> Vec<String> {
            let mut map = self.sessions.lock().unwrap();
            if let Some(msgs) = map.get(session_id) {
                msgs.clone()
            } else {
                self.create_count.fetch_add(1, Ordering::SeqCst);
                let msgs = Vec::new();
                map.insert(session_id.to_string(), msgs.clone());
                msgs
            }
        }

        fn update(&self, session_id: &str, messages: Vec<String>) {
            self.sessions
                .lock()
                .unwrap()
                .insert(session_id.to_string(), messages);
        }

        fn message_count(&self, session_id: &str) -> usize {
            self.sessions
                .lock()
                .unwrap()
                .get(session_id)
                .map(|m| m.len())
                .unwrap_or(0)
        }
    }

    let session_mgr = Arc::new(SessionManager::new());
    let mgr_clone = session_mgr.clone();

    let activities = ActivityRegistry::builder()
        .register(
            "runAgentTurn",
            move |ctx: ActivityContext, input: String| {
                let mgr = mgr_clone.clone();
                async move {
                    // input = "session_id|prompt"
                    let parts: Vec<&str> = input.splitn(2, '|').collect();
                    let session_id = parts[0];
                    let prompt = parts.get(1).unwrap_or(&"");

                    // Verify session routing
                    assert_eq!(
                        ctx.session_id(),
                        Some(session_id),
                        "Activity must see its session_id"
                    );

                    let mut messages = mgr.get_or_create(session_id);
                    messages.push(format!("user:{prompt}"));
                    let response = format!("assistant:reply-to-{prompt}");
                    messages.push(response.clone());
                    mgr.update(session_id, messages);

                    Ok(response)
                }
            },
        )
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "durable-turn",
            |ctx: OrchestrationContext, input: String| async move {
                // input = "session_id|prompt"
                let parts: Vec<&str> = input.splitn(2, '|').collect();
                let session_id = parts[0].to_string();

                let result = ctx
                    .schedule_activity_on_session("runAgentTurn", &input, &session_id)
                    .await?;

                Ok(result)
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        worker_node_id: Some("copilot-pod".to_string()),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    // Start 2 conversations
    client
        .start_orchestration("conv-1", "durable-turn", "sess-conv-1|Hello Rust")
        .await
        .unwrap();
    client
        .start_orchestration("conv-2", "durable-turn", "sess-conv-2|Explain async")
        .await
        .unwrap();

    // Wait for both to complete
    for conv_id in &["conv-1", "conv-2"] {
        match client
            .wait_for_orchestration(conv_id, Duration::from_secs(30))
            .await
            .unwrap()
        {
            runtime::OrchestrationStatus::Completed { output, .. } => {
                assert!(
                    output.contains("assistant:reply-to-"),
                    "Conversation {conv_id} should have a reply, got: {output}"
                );
            }
            other => panic!("Conversation {conv_id} expected completed, got {:?}", other),
        }
    }

    // Verify in-memory session state accumulated correctly
    assert_eq!(
        session_mgr.message_count("sess-conv-1"),
        2,
        "Session conv-1 should have 2 messages (user + assistant)"
    );
    assert_eq!(
        session_mgr.message_count("sess-conv-2"),
        2,
        "Session conv-2 should have 2 messages (user + assistant)"
    );
    assert_eq!(
        session_mgr.create_count.load(Ordering::SeqCst),
        2,
        "Each session should be created exactly once"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 8. Typed session activity
// ============================================================================

/// schedule_activity_on_session_typed works with serde types.
#[tokio::test]
async fn test_session_activity_typed() {
    init_test_logging();
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize)]
    struct DoubleInput {
        value: i32,
    }

    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Double", |_ctx: ActivityContext, input: String| async move {
            let parsed: DoubleInput = serde_json::from_str(&input).unwrap();
            Ok(serde_json::to_string(&(parsed.value * 2)).unwrap())
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "TypedSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let result: i32 = ctx
                    .schedule_activity_on_session_typed("Double", &DoubleInput { value: 21 }, "typed-sess")
                    .await?;
                Ok(result.to_string())
            },
        )
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-typed-session", "TypedSessionOrch", "")
        .await
        .unwrap();
    match client
        .wait_for_orchestration("test-typed-session", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "42");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 9. Process-level session identity E2E tests
// ============================================================================

/// With worker_node_id set, multiple different sessions can be served in parallel
/// by different worker slots sharing the same session identity.
#[tokio::test]
async fn test_session_worker_node_id_multiple_sessions_parallel() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let counter = Arc::new(AtomicUsize::new(0));
    let counter_clone = counter.clone();

    let activities = ActivityRegistry::builder()
        .register("Count", move |_ctx: ActivityContext, _input: String| {
            let c = counter_clone.clone();
            async move {
                c.fetch_add(1, Ordering::SeqCst);
                Ok("counted".to_string())
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "ParallelSessions",
            |ctx: OrchestrationContext, _input: String| async move {
                // Schedule activities on 3 different sessions
                let f1 = ctx.schedule_activity_on_session("Count", "x", "sess-1");
                let f2 = ctx.schedule_activity_on_session("Count", "y", "sess-2");
                let f3 = ctx.schedule_activity_on_session("Count", "z", "sess-3");
                let results = ctx.join3(f1, f2, f3).await;
                let r1 = results.0?;
                let r2 = results.1?;
                let r3 = results.2?;
                Ok(format!("{r1}|{r2}|{r3}"))
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 4,
        worker_node_id: Some("multi-sess-pod".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-parallel-sess", "ParallelSessions", "")
        .await
        .unwrap();
    match client
        .wait_for_orchestration("test-parallel-sess", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "counted|counted|counted");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    // At-least-once: counter may exceed 3 if an ack fails and the activity retries
    assert!(
        counter.load(Ordering::SeqCst) >= 3,
        "All 3 session activities should have executed"
    );
    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Ephemeral mode (worker_node_id=None) with worker_concurrency=1 still works.
/// Regression test for the per-slot identity path.
#[tokio::test]
async fn test_ephemeral_session_still_works() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Echo", |_ctx: ActivityContext, input: String| async move { Ok(input) })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "EphemeralOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let r = ctx
                    .schedule_activity_on_session("Echo", "ephemeral-val", "eph-sess")
                    .await?;
                Ok(r)
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 1,
        worker_node_id: None,
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-ephemeral", "EphemeralOrch", "")
        .await
        .unwrap();
    match client
        .wait_for_orchestration("test-ephemeral", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "ephemeral-val");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// With worker_node_id set, ActivityContext::session_id() returns the session ID
/// (not the worker node identity).
#[tokio::test]
async fn test_session_with_worker_node_id_activity_context_has_session_id() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let correct_session = Arc::new(AtomicBool::new(false));
    let correct_session_clone = correct_session.clone();

    let activities = ActivityRegistry::builder()
        .register("CheckSess", move |ctx: ActivityContext, _input: String| {
            let flag = correct_session_clone.clone();
            async move {
                // session_id() should return "my-session", NOT "k8s-pod-name"
                if ctx.session_id() == Some("my-session") {
                    flag.store(true, Ordering::SeqCst);
                }
                Ok("ok".to_string())
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "NodeIdSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                ctx.schedule_activity_on_session("CheckSess", "", "my-session").await?;
                Ok("done".to_string())
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        worker_node_id: Some("k8s-pod-name".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-node-ctx", "NodeIdSessionOrch", "")
        .await
        .unwrap();
    match client
        .wait_for_orchestration("test-node-ctx", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { .. } => {}
        other => panic!("Expected completed, got {:?}", other),
    }

    assert!(
        correct_session.load(Ordering::SeqCst),
        "ActivityContext::session_id() should return the session ID, not the worker_node_id"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Proves that with process-level session identity (worker_node_id set),
/// two worker slots can concurrently serve the same session.
#[tokio::test]
async fn test_two_slots_serve_same_session_concurrently() {
    init_test_logging();
    use std::sync::atomic::AtomicI32;

    let (store, schema) = common::create_postgres_store().await;

    let in_flight = Arc::new(AtomicI32::new(0));
    let max_concurrent = Arc::new(AtomicI32::new(0));

    let in_flight_a = in_flight.clone();
    let max_concurrent_a = max_concurrent.clone();
    let in_flight_b = in_flight.clone();
    let max_concurrent_b = max_concurrent.clone();

    let activities = ActivityRegistry::builder()
        .register("SlowTask", move |_ctx: ActivityContext, input: String| {
            let inf = in_flight_a.clone();
            let maxc = max_concurrent_a.clone();
            async move {
                let current = inf.fetch_add(1, Ordering::SeqCst) + 1;
                maxc.fetch_max(current, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(500)).await;
                inf.fetch_sub(1, Ordering::SeqCst);
                Ok(format!("slow:{input}"))
            }
        })
        .register("FastTask", move |_ctx: ActivityContext, input: String| {
            let inf = in_flight_b.clone();
            let maxc = max_concurrent_b.clone();
            async move {
                let current = inf.fetch_add(1, Ordering::SeqCst) + 1;
                maxc.fetch_max(current, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(200)).await;
                inf.fetch_sub(1, Ordering::SeqCst);
                Ok(format!("fast:{input}"))
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "ConcurrentSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let f1 = ctx.schedule_activity_on_session("SlowTask", "a", "same-session");
                let f2 = ctx.schedule_activity_on_session("FastTask", "b", "same-session");
                let (r1, r2) = ctx.join2(f1, f2).await;
                Ok(format!("{}|{}", r1?, r2?))
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        worker_node_id: Some("my-node".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-concurrent-session", "ConcurrentSessionOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-concurrent-session", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "slow:a|fast:b");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    assert_eq!(
        max_concurrent.load(Ordering::SeqCst),
        2,
        "Both activities should have been in-flight simultaneously, \
         proving two slots served the same session concurrently"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Without worker_node_id (ephemeral per-slot identity), two activities
/// on the same session are serialized because only one slot owns the session.
#[tokio::test]
async fn test_ephemeral_same_session_serialized() {
    init_test_logging();
    use std::sync::atomic::AtomicI32;

    let (store, schema) = common::create_postgres_store().await;

    let in_flight = Arc::new(AtomicI32::new(0));
    let max_concurrent = Arc::new(AtomicI32::new(0));

    let in_flight_a = in_flight.clone();
    let max_concurrent_a = max_concurrent.clone();
    let in_flight_b = in_flight.clone();
    let max_concurrent_b = max_concurrent.clone();

    let activities = ActivityRegistry::builder()
        .register("SlowTask", move |_ctx: ActivityContext, input: String| {
            let inf = in_flight_a.clone();
            let maxc = max_concurrent_a.clone();
            async move {
                let current = inf.fetch_add(1, Ordering::SeqCst) + 1;
                maxc.fetch_max(current, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(500)).await;
                inf.fetch_sub(1, Ordering::SeqCst);
                Ok(format!("slow:{input}"))
            }
        })
        .register("FastTask", move |_ctx: ActivityContext, input: String| {
            let inf = in_flight_b.clone();
            let maxc = max_concurrent_b.clone();
            async move {
                let current = inf.fetch_add(1, Ordering::SeqCst) + 1;
                maxc.fetch_max(current, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(200)).await;
                inf.fetch_sub(1, Ordering::SeqCst);
                Ok(format!("fast:{input}"))
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "SerialSessionOrch",
            |ctx: OrchestrationContext, _input: String| async move {
                let f1 = ctx.schedule_activity_on_session("SlowTask", "a", "same-session");
                let f2 = ctx.schedule_activity_on_session("FastTask", "b", "same-session");
                let (r1, r2) = ctx.join2(f1, f2).await;
                Ok(format!("{}|{}", r1?, r2?))
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        worker_node_id: None,
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-serial-session", "SerialSessionOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-serial-session", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "slow:a|fast:b");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    assert_eq!(
        max_concurrent.load(Ordering::SeqCst),
        1,
        "Without stable worker_node_id, only one slot owns the session, \
         so activities must execute sequentially (max_concurrent == 1)"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 10. Fan-out / Fan-in with Sessions
// ============================================================================

/// Fan-out/fan-in: multiple activities on different sessions execute in parallel,
/// then results are collected.
#[tokio::test]
async fn test_session_fan_out_fan_in() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Process", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("processed:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("FanOutOrch", |ctx: OrchestrationContext, _input: String| async move {
            let futures: Vec<_> = (0..3)
                .map(|i| {
                    let session = format!("session-{i}");
                    ctx.schedule_activity_on_session("Process", i.to_string(), session)
                })
                .collect();

            let results = ctx.join(futures).await;
            let outputs: Vec<String> = results.into_iter().collect::<Result<Vec<_>, _>>()?;
            Ok(outputs.join("|"))
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 4,
        worker_node_id: Some("fan-pod".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-fan-out", "FanOutOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-fan-out", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "processed:0|processed:1|processed:2");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Fan-out/fan-in mixing session and non-session activities in the same join.
#[tokio::test]
async fn test_session_fan_out_mixed_with_regular() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("SessionWork", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("sess:{input}"))
        })
        .register("RegularWork", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("reg:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("MixedFanOrch", |ctx: OrchestrationContext, _input: String| async move {
            let f1 = ctx.schedule_activity_on_session("SessionWork", "a", "s1");
            let f2 = ctx.schedule_activity("RegularWork", "b");
            let f3 = ctx.schedule_activity_on_session("SessionWork", "c", "s2");
            let f4 = ctx.schedule_activity("RegularWork", "d");

            let results = ctx.join(vec![f1, f2, f3, f4]).await;
            let outputs: Vec<String> = results.into_iter().collect::<Result<Vec<_>, _>>()?;
            Ok(outputs.join("|"))
        })
        .build();

    let rt =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-mixed-fan", "MixedFanOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-mixed-fan", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "sess:a|reg:b|sess:c|reg:d");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Fan-out with multiple activities per session: 2 on session-A, 2 on session-B,
/// and 2 non-session activities, all scheduled in parallel via ctx.join.
#[tokio::test]
async fn test_fan_out_multiple_per_session_mixed() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Tag", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("tag:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("MultiMixOrch", |ctx: OrchestrationContext, _input: String| async move {
            let f1 = ctx.schedule_activity_on_session("Tag", "s1-a", "session-1");
            let f2 = ctx.schedule_activity_on_session("Tag", "s1-b", "session-1");
            let f3 = ctx.schedule_activity_on_session("Tag", "s2-a", "session-2");
            let f4 = ctx.schedule_activity_on_session("Tag", "s2-b", "session-2");
            let f5 = ctx.schedule_activity("Tag", "no-sess-a");
            let f6 = ctx.schedule_activity("Tag", "no-sess-b");

            let results = ctx.join(vec![f1, f2, f3, f4, f5, f6]).await;
            let outputs: Vec<String> = results.into_iter().collect::<Result<Vec<_>, _>>()?;
            Ok(outputs.join("|"))
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 4,
        worker_node_id: Some("mix-pod".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-multi-mix", "MultiMixOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-multi-mix", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(
                output,
                "tag:s1-a|tag:s1-b|tag:s2-a|tag:s2-b|tag:no-sess-a|tag:no-sess-b"
            );
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 11. Sessions across continue-as-new with version bumps
// ============================================================================

/// Session survives continue-as-new within the same version.
#[tokio::test]
async fn test_session_survives_continue_as_new() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Track", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("tracked:{input}"))
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("SessionCAN", |ctx: OrchestrationContext, input: String| async move {
            let iteration: u32 = input.parse().unwrap_or(0);
            let r = ctx
                .schedule_activity_on_session("Track", format!("iter-{iteration}"), "persistent-session")
                .await?;
            if iteration == 0 {
                ctx.continue_as_new("1").await
            } else {
                Ok(r)
            }
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 1,
        orchestration_concurrency: 1,
        worker_node_id: Some("can-pod".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-session-can", "SessionCAN", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-session-can", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "tracked:iter-1");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Continue-as-new with versioned upgrade: v1 schedules session activity then
/// explicitly continues to v2 via continue_as_new_versioned.
#[tokio::test]
async fn test_session_continue_as_new_versioned_upgrade() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder()
        .register("Work", |_ctx: ActivityContext, input: String| async move {
            Ok(format!("done:{input}"))
        })
        .build();

    let v1 = |ctx: OrchestrationContext, _input: String| async move {
        let r = ctx
            .schedule_activity_on_session("Work", "from-v1", "upgrade-session")
            .await?;
        ctx.continue_as_new_versioned("2.0.0", r).await
    };

    let v2 = |ctx: OrchestrationContext, input: String| async move {
        let r = ctx
            .schedule_activity_on_session("Work", "from-v2", "upgrade-session")
            .await?;
        Ok(format!("{input}+{r}"))
    };

    let orchestrations = OrchestrationRegistry::builder()
        .register("UpgradeSession", v1)
        .register_versioned("UpgradeSession", "2.0.0", v2)
        .set_policy(
            "UpgradeSession",
            duroxide::runtime::VersionPolicy::Exact(Version::parse("1.0.0").unwrap()),
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 1,
        orchestration_concurrency: 1,
        worker_node_id: Some("upgrade-pod".to_string()),
        ..Default::default()
    };
    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-session-can-ver", "UpgradeSession", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-session-can-ver", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "done:from-v1+done:from-v2");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 12. Validation and capacity tests
// ============================================================================

/// Validates that `start_with_options` panics when `session_idle_timeout` is not
/// greater than the worker lock renewal interval.
#[tokio::test]
#[should_panic(expected = "session_idle_timeout")]
async fn test_session_idle_timeout_must_exceed_worker_renewal_interval() {
    init_test_logging();
    let (store, _schema) = common::create_postgres_store().await;

    let activities = ActivityRegistry::builder().build();
    let orchestrations = OrchestrationRegistry::builder().build();

    let options = RuntimeOptions {
        session_idle_timeout: Duration::from_secs(25),
        worker_lock_timeout: Duration::from_secs(30),
        worker_lock_renewal_buffer: Duration::from_secs(5),
        ..Default::default()
    };

    // This should panic
    let _rt = runtime::Runtime::start_with_options(store, activities, orchestrations, options).await;
}

/// Verify that max_sessions_per_runtime is enforced via runtime-side ref counting.
#[tokio::test]
async fn test_max_sessions_per_runtime_enforced() {
    init_test_logging();
    use std::sync::atomic::Ordering as AOrdering;

    let (store, schema) = common::create_postgres_store().await;

    let concurrent = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));

    let concurrent_c = concurrent.clone();
    let peak_c = peak.clone();

    let activities = ActivityRegistry::builder()
        .register("SlowSession", move |_ctx: ActivityContext, _input: String| {
            let conc = concurrent_c.clone();
            let pk = peak_c.clone();
            async move {
                let cur = conc.fetch_add(1, AOrdering::SeqCst) + 1;
                pk.fetch_max(cur, AOrdering::SeqCst);
                tokio::time::sleep(Duration::from_millis(200)).await;
                conc.fetch_sub(1, AOrdering::SeqCst);
                Ok("done".to_string())
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("TwoSessions", |ctx: OrchestrationContext, _input: String| async move {
            let f1 = ctx.schedule_activity_on_session("SlowSession", "a", "session-A");
            let f2 = ctx.schedule_activity_on_session("SlowSession", "b", "session-B");
            let results = ctx.join(vec![f1, f2]).await;
            let r1 = results[0].as_ref().map_err(|e| e.clone())?;
            let r2 = results[1].as_ref().map_err(|e| e.clone())?;
            Ok(format!("{r1}|{r2}"))
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        max_sessions_per_runtime: 1,
        orchestration_concurrency: 1,
        // Short long-poll timeout so capacity-blocked slots re-check quickly
        dispatcher_long_poll_timeout: Duration::from_secs(2),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-max-sessions", "TwoSessions", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-max-sessions", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "done|done");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    assert_eq!(
        peak.load(AOrdering::SeqCst),
        1,
        "With max_sessions_per_runtime=1, activities on different sessions should not run concurrently"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Verify that multiple activities on the SAME session count as 1 distinct session.
#[tokio::test]
async fn test_same_session_shares_one_slot() {
    init_test_logging();
    use std::sync::atomic::Ordering as AOrdering;

    let (store, schema) = common::create_postgres_store().await;

    let concurrent = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));

    let concurrent_c = concurrent.clone();
    let peak_c = peak.clone();

    let activities = ActivityRegistry::builder()
        .register("SlowSame", move |_ctx: ActivityContext, _input: String| {
            let conc = concurrent_c.clone();
            let pk = peak_c.clone();
            async move {
                let cur = conc.fetch_add(1, AOrdering::SeqCst) + 1;
                pk.fetch_max(cur, AOrdering::SeqCst);
                tokio::time::sleep(Duration::from_millis(300)).await;
                conc.fetch_sub(1, AOrdering::SeqCst);
                Ok("ok".to_string())
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register(
            "SameSessionFanOut",
            |ctx: OrchestrationContext, _input: String| async move {
                let f1 = ctx.schedule_activity_on_session("SlowSame", "a", "shared-session");
                let f2 = ctx.schedule_activity_on_session("SlowSame", "b", "shared-session");
                let results = ctx.join(vec![f1, f2]).await;
                let r1 = results[0].as_ref().map_err(|e| e.clone())?;
                let r2 = results[1].as_ref().map_err(|e| e.clone())?;
                Ok(format!("{r1}|{r2}"))
            },
        )
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        max_sessions_per_runtime: 1,
        orchestration_concurrency: 1,
        // Short long-poll timeout so capacity-blocked slots re-check quickly
        dispatcher_long_poll_timeout: Duration::from_secs(2),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-same-session-slot", "SameSessionFanOut", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("test-same-session-slot", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "ok|ok");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Verify that a session-bound activity is blocked when at capacity, then
/// unblocked once the blocking session completes.
#[tokio::test]
async fn test_session_cap_blocks_then_unblocks() {
    init_test_logging();
    use std::sync::Mutex;
    use tokio::sync::Notify;

    let (store, schema) = common::create_postgres_store().await;

    let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let release_a: Arc<Notify> = Arc::new(Notify::new());

    let log_c = log.clone();
    let release_a_c = release_a.clone();

    let activities = ActivityRegistry::builder()
        .register("Tracked", move |_ctx: ActivityContext, input: String| {
            let lg = log_c.clone();
            let release = release_a_c.clone();
            async move {
                lg.lock().unwrap().push(format!("{input}-started"));

                if input == "A" {
                    release.notified().await;
                }

                lg.lock().unwrap().push(format!("{input}-finished"));
                Ok(format!("result-{input}"))
            }
        })
        .build();

    let orchestrations = OrchestrationRegistry::builder()
        .register("BlockUnblock", |ctx: OrchestrationContext, _input: String| async move {
            let fa = ctx.schedule_activity_on_session("Tracked", "A", "session-A");
            let fb = ctx.schedule_activity_on_session("Tracked", "B", "session-B");
            let results = ctx.join(vec![fa, fb]).await;
            let ra = results[0].as_ref().map_err(|e| e.clone())?;
            let rb = results[1].as_ref().map_err(|e| e.clone())?;
            Ok(format!("{ra}|{rb}"))
        })
        .build();

    let options = RuntimeOptions {
        worker_concurrency: 2,
        max_sessions_per_runtime: 1,
        orchestration_concurrency: 1,
        // Short long-poll timeout so capacity-blocked slots re-check quickly
        dispatcher_long_poll_timeout: Duration::from_secs(2),
        ..Default::default()
    };

    let rt = runtime::Runtime::start_with_options(
        store.clone(),
        activities,
        orchestrations,
        options,
    )
    .await;
    let client = Client::new(store.clone());

    client
        .start_orchestration("test-block-unblock", "BlockUnblock", "")
        .await
        .unwrap();

    // Wait for activity-A to start
    let a_started = {
        let mut found = false;
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let events = log.lock().unwrap().clone();
            if events.contains(&"A-started".to_string()) {
                found = true;
                break;
            }
        }
        found
    };
    assert!(a_started, "Timed out waiting for activity A to start");

    // Give B a chance to start if it were going to (it shouldn't with cap=1)
    tokio::time::sleep(Duration::from_millis(200)).await;

    {
        let events = log.lock().unwrap().clone();
        assert!(
            !events.contains(&"B-started".to_string()),
            "B should NOT have started while A holds the session cap, got: {events:?}"
        );
    }

    // Release A
    release_a.notify_one();

    match client
        .wait_for_orchestration("test-block-unblock", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            assert_eq!(output, "result-A|result-B");
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    let events = log.lock().unwrap().clone();
    let a_finished = events
        .iter()
        .position(|e| e == "A-finished")
        .expect("A-finished missing");
    let b_started = events.iter().position(|e| e == "B-started").expect("B-started missing");
    assert!(
        a_finished < b_started,
        "B should start only after A finishes. Event log: {events:?}"
    );

    rt.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

// ============================================================================
// 13. Multi-worker E2E tests (two runtimes, shared store)
// ============================================================================

/// Complex orchestration across 2 worker runtimes sharing the same store.
#[tokio::test]
async fn test_multi_worker_complex_orchestration() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let worker_a_count = Arc::new(AtomicUsize::new(0));
    let worker_b_count = Arc::new(AtomicUsize::new(0));

    fn build_activities(counter: Arc<AtomicUsize>) -> ActivityRegistry {
        ActivityRegistry::builder()
            .register("SessionWork", move |ctx: ActivityContext, input: String| {
                let c = counter.clone();
                async move {
                    c.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    assert!(ctx.session_id().is_some(), "SessionWork must have a session_id");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    Ok(format!("session-result:{input}"))
                }
            })
            .register("PlainWork", |_ctx: ActivityContext, input: String| async move {
                tokio::time::sleep(Duration::from_millis(30)).await;
                Ok(format!("plain-result:{input}"))
            })
            .build()
    }

    fn build_orchestrations() -> OrchestrationRegistry {
        OrchestrationRegistry::builder()
            .register(
                "MultiWorkerOrch",
                |ctx: OrchestrationContext, input: String| async move {
                    let parts: Vec<&str> = input.splitn(2, '|').collect();
                    let cycle: u32 = parts[0].parse().unwrap_or(0);
                    let prev = parts.get(1).unwrap_or(&"").to_string();

                    match cycle {
                        0 => {
                            let s1 = ctx.schedule_activity_on_session("SessionWork", "a", "sess-alpha");
                            let s2 = ctx.schedule_activity_on_session("SessionWork", "b", "sess-alpha");
                            let s3 = ctx.schedule_activity_on_session("SessionWork", "c", "sess-beta");
                            let p1 = ctx.schedule_activity("PlainWork", "d");
                            let results = ctx.join(vec![s1, s2, s3, p1]).await;
                            let combined: Vec<String> = results
                                .into_iter()
                                .map(|r| r.unwrap_or_else(|e| format!("ERR:{e}")))
                                .collect();

                            ctx.continue_as_new(format!("1|{}", combined.join(";"))).await
                        }
                        1 => {
                            let r1 = ctx
                                .schedule_activity_on_session("SessionWork", "e", "sess-alpha")
                                .await?;
                            let r2 = ctx
                                .schedule_activity_on_session("SessionWork", "f", "sess-beta")
                                .await?;
                            Ok(format!("{prev};{r1};{r2}"))
                        }
                        _ => Ok(format!("unexpected cycle {cycle}")),
                    }
                },
            )
            .build()
    }

    let rt_a = runtime::Runtime::start_with_options(
        store.clone(),
        build_activities(worker_a_count.clone()),
        build_orchestrations(),
        RuntimeOptions {
            worker_concurrency: 2,
            orchestration_concurrency: 2,
            worker_node_id: Some("node-A".to_string()),
            max_sessions_per_runtime: 4,
            ..Default::default()
        },
    )
    .await;

    let rt_b = runtime::Runtime::start_with_options(
        store.clone(),
        build_activities(worker_b_count.clone()),
        build_orchestrations(),
        RuntimeOptions {
            worker_concurrency: 2,
            orchestration_concurrency: 2,
            worker_node_id: Some("node-B".to_string()),
            max_sessions_per_runtime: 4,
            ..Default::default()
        },
    )
    .await;

    let client = Client::new(store.clone());

    client
        .start_orchestration("multi-worker-complex", "MultiWorkerOrch", "0|")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("multi-worker-complex", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            let parts: Vec<&str> = output.split(';').collect();
            assert_eq!(parts.len(), 6, "Should have 6 results total, got: {output}");

            let session_results: Vec<&&str> = parts.iter().filter(|p| p.contains("session-result:")).collect();
            assert_eq!(session_results.len(), 5, "Should have 5 session results, got: {output}");

            assert!(
                output.contains("plain-result:d"),
                "Plain activity result missing: {output}"
            );
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    let a = worker_a_count.load(Ordering::SeqCst);
    let b = worker_b_count.load(Ordering::SeqCst);
    assert_eq!(
        a + b,
        5,
        "Total session activities should be 5 (3 + 2 from CAN), got A={a} B={b}"
    );

    rt_a.shutdown(None).await;
    rt_b.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}

/// Heterogeneous multi-worker test: different max_sessions and session_lock_timeout.
#[tokio::test]
async fn test_multi_worker_heterogeneous_config() {
    init_test_logging();
    let (store, schema) = common::create_postgres_store().await;

    let worker_a_sessions = Arc::new(AtomicUsize::new(0));
    let worker_b_sessions = Arc::new(AtomicUsize::new(0));

    fn build_activities(counter: Arc<AtomicUsize>) -> ActivityRegistry {
        ActivityRegistry::builder()
            .register("Work", move |_ctx: ActivityContext, input: String| {
                let c = counter.clone();
                async move {
                    c.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(800)).await;
                    Ok(format!("done:{input}"))
                }
            })
            .build()
    }

    fn build_orchestrations() -> OrchestrationRegistry {
        OrchestrationRegistry::builder()
            .register("HeteroOrch", |ctx: OrchestrationContext, _input: String| async move {
                let f1 = ctx.schedule_activity_on_session("Work", "1", "sess-X");
                let f2 = ctx.schedule_activity_on_session("Work", "2", "sess-Y");
                let f3 = ctx.schedule_activity_on_session("Work", "3", "sess-Z");
                let results = ctx.join(vec![f1, f2, f3]).await;
                let combined: String = results
                    .into_iter()
                    .map(|r| r.unwrap_or_else(|e| format!("ERR:{e}")))
                    .collect::<Vec<_>>()
                    .join("|");
                Ok(combined)
            })
            .build()
    }

    let rt_a = runtime::Runtime::start_with_options(
        store.clone(),
        build_activities(worker_a_sessions.clone()),
        build_orchestrations(),
        RuntimeOptions {
            worker_concurrency: 2,
            orchestration_concurrency: 2,
            worker_node_id: Some("constrained-node".to_string()),
            max_sessions_per_runtime: 1,
            session_lock_timeout: Duration::from_secs(5),
            session_lock_renewal_buffer: Duration::from_secs(1),
            session_idle_timeout: Duration::from_secs(30),
            // Short long-poll timeout so capacity-blocked slots re-check quickly
            dispatcher_long_poll_timeout: Duration::from_secs(2),
            ..Default::default()
        },
    )
    .await;

    let rt_b = runtime::Runtime::start_with_options(
        store.clone(),
        build_activities(worker_b_sessions.clone()),
        build_orchestrations(),
        RuntimeOptions {
            worker_concurrency: 2,
            orchestration_concurrency: 2,
            worker_node_id: Some("unconstrained-node".to_string()),
            max_sessions_per_runtime: 10,
            session_lock_timeout: Duration::from_secs(30),
            session_lock_renewal_buffer: Duration::from_secs(5),
            session_idle_timeout: Duration::from_secs(60),
            ..Default::default()
        },
    )
    .await;

    let client = Client::new(store.clone());

    client
        .start_orchestration("hetero-test", "HeteroOrch", "")
        .await
        .unwrap();

    match client
        .wait_for_orchestration("hetero-test", Duration::from_secs(30))
        .await
        .unwrap()
    {
        runtime::OrchestrationStatus::Completed { output, .. } => {
            let parts: Vec<&str> = output.split('|').collect();
            assert_eq!(parts.len(), 3, "Should have 3 results, got: {output}");
            for p in &parts {
                assert!(
                    p.starts_with("done:"),
                    "Each result should start with 'done:', got: {p}"
                );
            }
        }
        other => panic!("Expected completed, got {:?}", other),
    }

    let a = worker_a_sessions.load(Ordering::SeqCst);
    let b = worker_b_sessions.load(Ordering::SeqCst);
    assert_eq!(a + b, 3, "Total should be 3, got A={a} B={b}");
    assert!(
        b >= 1,
        "Worker B should handle at least 1 session (overflow from A's max_sessions=1), got A={a} B={b}"
    );

    rt_a.shutdown(None).await;
    rt_b.shutdown(None).await;
    common::cleanup_schema(&schema).await;
}
