//! Long-polling notifier for PostgreSQL provider.
//!
//! The notifier thread listens for PostgreSQL NOTIFY events and manages timer heaps
//! to wake dispatchers at the right time, reducing idle database polling.

use sqlx::postgres::PgListener;
use sqlx::PgPool;
use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{oneshot, Notify};
use tokio::time::sleep_until;
use tracing::{debug, error, info, warn};

#[cfg(feature = "test-fault-injection")]
use crate::fault_injection::FaultInjector;

/// Configuration for long-polling behavior.
#[derive(Debug, Clone)]
pub struct LongPollConfig {
    /// Enable long-polling (LISTEN/NOTIFY based).
    /// Default: true
    pub enabled: bool,

    /// Interval for querying upcoming timers from the database.
    /// The notifier queries for work with visible_at within this window.
    /// Also serves as a safety net to catch any missed NOTIFYs.
    /// Default: 60 seconds
    pub notifier_poll_interval: Duration,

    /// Grace period added to timer delays to ensure we never wake early.
    /// Accounts for tokio timer jitter and processing overhead.
    /// delay = (visible_at - now) + timer_grace_period
    /// Default: 100ms
    pub timer_grace_period: Duration,
}

impl Default for LongPollConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            notifier_poll_interval: Duration::from_secs(60),
            timer_grace_period: Duration::from_millis(100),
        }
    }
}

/// Result of a refresh query containing upcoming timer timestamps.
struct RefreshResult {
    orch_timers: Vec<i64>,   // visible_at as epoch ms
    worker_timers: Vec<i64>, // visible_at as epoch ms
}

/// The notifier thread that manages LISTEN/NOTIFY and timer heaps.
pub struct Notifier {
    /// PostgreSQL connection for LISTEN
    pg_listener: PgListener,
    pool: PgPool,
    schema_name: String,

    /// Timer heaps (min-heap by fire time)
    orch_heap: BinaryHeap<Reverse<Instant>>,
    worker_heap: BinaryHeap<Reverse<Instant>>,

    /// Dispatcher wake channels
    orch_notify: Arc<Notify>,
    worker_notify: Arc<Notify>,

    /// Refresh scheduling
    next_refresh: Instant,

    /// Active refresh task (if any)
    pending_refresh: Option<oneshot::Receiver<RefreshResult>>,

    /// Configuration
    config: LongPollConfig,

    /// Fault injector for testing (only available with test-fault-injection feature)
    #[cfg(feature = "test-fault-injection")]
    fault_injector: Option<Arc<FaultInjector>>,
}

impl Notifier {
    /// Create a new notifier and subscribe to NOTIFY channels.
    pub async fn new(
        pool: PgPool,
        schema_name: String,
        orch_notify: Arc<Notify>,
        worker_notify: Arc<Notify>,
        config: LongPollConfig,
    ) -> Result<Self, sqlx::Error> {
        Self::new_internal(
            pool,
            schema_name,
            orch_notify,
            worker_notify,
            config,
            #[cfg(feature = "test-fault-injection")]
            None,
        )
        .await
    }

    /// Create a new notifier with fault injection for testing.
    #[cfg(feature = "test-fault-injection")]
    pub async fn new_with_fault_injection(
        pool: PgPool,
        schema_name: String,
        orch_notify: Arc<Notify>,
        worker_notify: Arc<Notify>,
        config: LongPollConfig,
        fault_injector: Arc<FaultInjector>,
    ) -> Result<Self, sqlx::Error> {
        Self::new_internal(
            pool,
            schema_name,
            orch_notify,
            worker_notify,
            config,
            Some(fault_injector),
        )
        .await
    }

    async fn new_internal(
        pool: PgPool,
        schema_name: String,
        orch_notify: Arc<Notify>,
        worker_notify: Arc<Notify>,
        config: LongPollConfig,
        #[cfg(feature = "test-fault-injection")] fault_injector: Option<Arc<FaultInjector>>,
    ) -> Result<Self, sqlx::Error> {
        let pg_listener = PgListener::connect_with(&pool).await?;

        let mut notifier = Self {
            pg_listener,
            pool,
            schema_name,
            orch_heap: BinaryHeap::new(),
            worker_heap: BinaryHeap::new(),
            orch_notify,
            worker_notify,
            next_refresh: Instant::now(), // Immediate first refresh
            pending_refresh: None,
            config,
            #[cfg(feature = "test-fault-injection")]
            fault_injector,
        };

        notifier.subscribe_channels().await?;

        info!(
            target = "duroxide::providers::postgres::notifier",
            schema = %notifier.schema_name,
            "Notifier started, listening for NOTIFY events"
        );

        Ok(notifier)
    }

    /// Subscribe to NOTIFY channels. Used by new() and handle_reconnect().
    async fn subscribe_channels(&mut self) -> Result<(), sqlx::Error> {
        let orch_channel = format!("{}_orch_work", self.schema_name);
        let worker_channel = format!("{}_worker_work", self.schema_name);

        self.pg_listener.listen(&orch_channel).await?;
        self.pg_listener.listen(&worker_channel).await?;

        debug!(
            target = "duroxide::providers::postgres::notifier",
            orch_channel = %orch_channel,
            worker_channel = %worker_channel,
            "Subscribed to NOTIFY channels"
        );

        Ok(())
    }

    /// Main loop - runs until the notifier is dropped.
    pub async fn run(&mut self) {
        loop {
            // Check for fault injection: should we panic?
            #[cfg(feature = "test-fault-injection")]
            if let Some(ref fi) = self.fault_injector {
                if fi.should_notifier_panic() {
                    panic!("Fault injection: notifier panic triggered");
                }
                if fi.should_reconnect() {
                    warn!(
                        target = "duroxide::providers::postgres::notifier",
                        "Fault injection: forcing reconnect"
                    );
                    self.handle_reconnect().await;
                    continue;
                }
            }

            // Calculate next wake time
            let next_timer = self.earliest_timer();
            let refresh_in_progress = self.pending_refresh.is_some();

            let next_wake = if refresh_in_progress {
                // Don't wait for refresh time if query already running
                next_timer.unwrap_or_else(|| Instant::now() + Duration::from_secs(60))
            } else {
                match next_timer {
                    Some(t) => t.min(self.next_refresh),
                    None => self.next_refresh,
                }
            };

            tokio::select! {
                // PostgreSQL NOTIFY received
                result = self.pg_listener.recv() => {
                    match result {
                        Ok(notification) => {
                            self.handle_notify(notification);
                        }
                        Err(e) => {
                            warn!(
                                target = "duroxide::providers::postgres::notifier",
                                error = %e,
                                "LISTEN connection error, reconnecting..."
                            );
                            self.handle_reconnect().await;
                        }
                    }
                }

                // Timer or refresh time reached
                _ = sleep_until(next_wake.into()) => {
                    self.pop_and_wake_expired_timers();
                    self.maybe_start_refresh();
                }

                // Refresh query completed (non-blocking)
                Some(result) = async {
                    match &mut self.pending_refresh {
                        Some(rx) => rx.await.ok(),
                        None => std::future::pending().await,
                    }
                } => {
                    self.pending_refresh = None;
                    self.handle_refresh_result(result);
                }
            }
        }
    }

    /// Find the earliest timer across both heaps.
    fn earliest_timer(&self) -> Option<Instant> {
        let orch = self.orch_heap.peek().map(|r| r.0);
        let worker = self.worker_heap.peek().map(|r| r.0);
        match (orch, worker) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (Some(a), None) => Some(a),
            (None, Some(b)) => Some(b),
            (None, None) => None,
        }
    }

    /// Handle a NOTIFY from PostgreSQL.
    fn handle_notify(&mut self, notification: sqlx::postgres::PgNotification) {
        let now_ms = current_epoch_ms();
        let window_end_ms = now_ms + self.config.notifier_poll_interval.as_millis() as i64;
        let now_instant = Instant::now();

        let is_orch = notification.channel().ends_with("_orch_work");

        let action = parse_notify_action(
            notification.payload(),
            now_ms,
            window_end_ms,
            self.config.timer_grace_period,
            now_instant,
        );

        match action {
            NotifyAction::WakeNow => {
                debug!(
                    target = "duroxide::providers::postgres::notifier",
                    channel = %notification.channel(),
                    payload = %notification.payload(),
                    "Immediate work, waking dispatchers"
                );
                self.wake_dispatchers(is_orch);
            }
            NotifyAction::AddTimer { fire_at } => {
                debug!(
                    target = "duroxide::providers::postgres::notifier",
                    channel = %notification.channel(),
                    payload = %notification.payload(),
                    "Future timer, adding to heap"
                );
                if is_orch {
                    self.orch_heap.push(Reverse(fire_at));
                } else {
                    self.worker_heap.push(Reverse(fire_at));
                }
            }
            NotifyAction::Ignore => {
                debug!(
                    target = "duroxide::providers::postgres::notifier",
                    channel = %notification.channel(),
                    payload = %notification.payload(),
                    "Timer beyond window, ignoring"
                );
            }
        }
    }

    /// Wake all waiting dispatchers for the given queue type.
    ///
    /// Worker uses `notify_waiters()` so that ALL worker slots wake up.
    /// This is required for session routing: a session-bound item can only
    /// be served by the slot that owns the session, so waking just one
    /// slot (which might be the wrong one) would cause a deadlock.
    fn wake_dispatchers(&self, is_orch: bool) {
        if is_orch {
            self.orch_notify.notify_one();
        } else {
            self.worker_notify.notify_waiters();
        }
    }

    /// Pop and fire any expired timers from both heaps.
    fn pop_and_wake_expired_timers(&mut self) {
        let now = Instant::now();

        // Pop expired orchestrator timers
        while let Some(Reverse(fire_at)) = self.orch_heap.peek() {
            if *fire_at <= now {
                self.orch_heap.pop();
                self.orch_notify.notify_one();
            } else {
                break;
            }
        }

        // Pop expired worker timers (notify_waiters for session routing correctness)
        while let Some(Reverse(fire_at)) = self.worker_heap.peek() {
            if *fire_at <= now {
                self.worker_heap.pop();
                self.worker_notify.notify_waiters();
            } else {
                break;
            }
        }
    }

    /// Start a refresh query if not already in progress and it's time.
    fn maybe_start_refresh(&mut self) {
        if self.pending_refresh.is_some() || Instant::now() < self.next_refresh {
            return;
        }

        let (tx, rx) = oneshot::channel();
        self.pending_refresh = Some(rx);

        let pool = self.pool.clone();
        let schema = self.schema_name.clone();
        let now_ms = current_epoch_ms();
        let window_end_ms = now_ms + self.config.notifier_poll_interval.as_millis() as i64;

        // Get fault injection parameters before spawning
        #[cfg(feature = "test-fault-injection")]
        let fault_injector = self.fault_injector.clone();

        debug!(
            target = "duroxide::providers::postgres::notifier",
            now_ms = now_ms,
            window_end_ms = window_end_ms,
            "Starting refresh query"
        );

        tokio::spawn(async move {
            // Check for fault injection: add delay before refresh
            #[cfg(feature = "test-fault-injection")]
            if let Some(ref fi) = fault_injector {
                let delay = fi.get_refresh_delay();
                if !delay.is_zero() {
                    tokio::time::sleep(delay).await;
                }
            }

            // Check for fault injection: should refresh error?
            #[cfg(feature = "test-fault-injection")]
            if let Some(ref fi) = fault_injector {
                if fi.should_refresh_error() {
                    warn!(
                        target = "duroxide::providers::postgres::notifier",
                        "Fault injection: simulating refresh error"
                    );
                    // Send empty result to simulate error recovery
                    let _ = tx.send(RefreshResult {
                        orch_timers: Vec::new(),
                        worker_timers: Vec::new(),
                    });
                    return;
                }
            }

            // Query for upcoming timers in both queues
            // Use Rust clock ($1) for "now" comparison, not database NOW()
            let orch_timers = sqlx::query_scalar::<_, i64>(&format!(
                "SELECT (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT
                 FROM {schema}.orchestrator_queue
                 WHERE (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT > $1
                   AND (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT <= $2
                   AND lock_token IS NULL"
            ))
            .bind(now_ms)
            .bind(window_end_ms)
            .fetch_all(&pool)
            .await
            .unwrap_or_default();

            // TODO: After adding visible_at column to worker_queue (see docs/WORKER_VISIBLE_AT_PROPOSAL.md),
            // query for future worker timers here similar to orch_timers above.
            // Worker queue items are currently always immediately available (no visible_at column)
            let worker_timers: Vec<i64> = Vec::new();

            // Send result (ignore error if receiver dropped)
            let _ = tx.send(RefreshResult {
                orch_timers,
                worker_timers,
            });
        });
    }

    /// Process the result of a refresh query.
    fn handle_refresh_result(&mut self, result: RefreshResult) {
        let now_ms = current_epoch_ms();
        let now_instant = Instant::now();

        debug!(
            target = "duroxide::providers::postgres::notifier",
            orch_count = result.orch_timers.len(),
            worker_count = result.worker_timers.len(),
            "Refresh query completed"
        );

        // Add orchestrator timers
        for fire_at in timers_from_refresh(
            &result.orch_timers,
            now_ms,
            self.config.timer_grace_period,
            now_instant,
        ) {
            self.orch_heap.push(Reverse(fire_at));
        }

        // Add worker timers
        for fire_at in timers_from_refresh(
            &result.worker_timers,
            now_ms,
            self.config.timer_grace_period,
            now_instant,
        ) {
            self.worker_heap.push(Reverse(fire_at));
        }

        // Schedule next refresh
        self.next_refresh = Instant::now() + self.config.notifier_poll_interval;
    }

    /// Handle reconnection after a LISTEN connection failure.
    async fn handle_reconnect(&mut self) {
        // Backoff before reconnect attempt
        tokio::time::sleep(Duration::from_secs(1)).await;

        // Reconnect and resubscribe
        match PgListener::connect_with(&self.pool).await {
            Ok(listener) => {
                self.pg_listener = listener;

                if self.subscribe_channels().await.is_ok() {
                    info!(
                        target = "duroxide::providers::postgres::notifier",
                        "Reconnected to PostgreSQL LISTEN"
                    );

                    // Wake all dispatchers to catch any missed NOTIFYs during disconnect
                    self.orch_notify.notify_one();
                    self.worker_notify.notify_waiters();

                    // Force immediate refresh to rebuild timer heaps
                    self.next_refresh = Instant::now();
                }
            }
            Err(e) => {
                error!(
                    target = "duroxide::providers::postgres::notifier",
                    error = %e,
                    "Failed to reconnect, will retry on next loop iteration"
                );
            }
        }
        // If reconnect fails, loop will call handle_reconnect again on next recv() error
    }
}

/// Get current time as epoch milliseconds (Rust clock).
fn current_epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// Action determined by parsing a NOTIFY payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotifyAction {
    /// Work is immediately visible, wake dispatchers now.
    WakeNow,
    /// Work will be visible in the future, add timer.
    AddTimer { fire_at: Instant },
    /// Work is too far in the future, ignore (refresh will catch it).
    Ignore,
}

/// Parse a NOTIFY payload and determine what action to take.
///
/// This is a pure function for testability.
pub fn parse_notify_action(
    payload: &str,
    now_ms: i64,
    window_end_ms: i64,
    grace_period: Duration,
    now_instant: Instant,
) -> NotifyAction {
    let visible_at_ms: i64 = payload.parse().unwrap_or(0); // 0 = treat as immediate

    if visible_at_ms <= now_ms {
        // Immediately visible (or past) → wake dispatchers now
        NotifyAction::WakeNow
    } else if visible_at_ms <= window_end_ms {
        // Future timer within current window → schedule a timer
        let delay_ms = (visible_at_ms - now_ms) + grace_period.as_millis() as i64;
        let fire_at = now_instant + Duration::from_millis(delay_ms as u64);
        NotifyAction::AddTimer { fire_at }
    } else {
        // Beyond window → ignore, refresh will catch it
        NotifyAction::Ignore
    }
}

/// Calculate timers to add from refresh result.
///
/// Returns Vec of (fire_at Instant) for timers that should be added to the heap.
/// Filters out any timers that are already expired.
///
/// NOTE: There's an edge case where items could be missed if:
/// 1. Item had visible_at just barely in the future when query started
/// 2. Query takes longer than that margin to complete
/// 3. By the time we process results, the item has expired (delay <= 0)
///
/// This is acceptable because:
/// - The original NOTIFY when the item was inserted should have already woken dispatchers
/// - poll_timeout (default 5s) provides a safety net for any missed items
/// - This edge case is rare (query must be slow AND item must be near-immediate)
/// - Adding an extra wake for expired items isn't worth the overhead
pub fn timers_from_refresh(
    visible_at_times: &[i64],
    now_ms: i64,
    grace_period: Duration,
    now_instant: Instant,
) -> Vec<Instant> {
    visible_at_times
        .iter()
        .filter_map(|&visible_at_ms| {
            let delay_ms = (visible_at_ms - now_ms) + grace_period.as_millis() as i64;
            if delay_ms > 0 {
                Some(now_instant + Duration::from_millis(delay_ms as u64))
            } else {
                None
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // =======================================================================
    // Basic Tests
    // =======================================================================

    #[test]
    fn test_current_epoch_ms() {
        let ms = current_epoch_ms();
        // Should be a reasonable timestamp (after 2020)
        assert!(ms > 1_577_836_800_000); // 2020-01-01
        assert!(ms < 2_524_608_000_000); // 2050-01-01
    }

    #[test]
    fn test_longpoll_config_default() {
        let config = LongPollConfig::default();
        assert!(config.enabled);
        assert_eq!(config.notifier_poll_interval, Duration::from_secs(60));
        assert_eq!(config.timer_grace_period, Duration::from_millis(100));
    }

    // =======================================================================
    // Category 1: NOTIFY Handling Tests
    // =======================================================================

    #[test]
    fn notify_immediate_work_wakes_dispatchers() {
        // NOTIFY with visible_at = now should wake dispatchers immediately
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &now_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        assert_eq!(action, NotifyAction::WakeNow);
    }

    #[test]
    fn notify_past_visible_at_wakes_immediately() {
        // NOTIFY with visible_at in the past should wake immediately
        let now_ms = 1_700_000_000_000i64;
        let past_ms = now_ms - 5_000; // 5 seconds ago
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &past_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        assert_eq!(action, NotifyAction::WakeNow);
    }

    #[test]
    fn notify_future_timer_adds_to_heap() {
        // NOTIFY with visible_at in the future (within window) should add timer
        let now_ms = 1_700_000_000_000i64;
        let future_ms = now_ms + 30_000; // 30 seconds from now
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &future_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        match action {
            NotifyAction::AddTimer { fire_at } => {
                // fire_at should be approximately now + 30s + 100ms grace
                let expected_delay = Duration::from_millis(30_100);
                let actual_delay = fire_at.duration_since(now_instant);
                assert!(
                    actual_delay >= expected_delay - Duration::from_millis(10)
                        && actual_delay <= expected_delay + Duration::from_millis(10),
                    "Expected delay ~30.1s, got {actual_delay:?}"
                );
            }
            other => panic!("Expected AddTimer, got {other:?}"),
        }
    }

    #[test]
    fn notify_beyond_window_ignored() {
        // NOTIFY with visible_at beyond the refresh window should be ignored
        let now_ms = 1_700_000_000_000i64;
        let far_future_ms = now_ms + 90_000; // 90 seconds (beyond 60s window)
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &far_future_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        assert_eq!(action, NotifyAction::Ignore);
    }

    #[test]
    fn notify_invalid_payload_treated_as_immediate() {
        // Invalid payload should be treated as immediate (parsed as 0)
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action("garbage", now_ms, window_end_ms, grace, now_instant);

        assert_eq!(action, NotifyAction::WakeNow);
    }

    #[test]
    fn notify_empty_payload_treated_as_immediate() {
        // Empty payload should be treated as immediate (parsed as 0)
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action("", now_ms, window_end_ms, grace, now_instant);

        assert_eq!(action, NotifyAction::WakeNow);
    }

    // =======================================================================
    // Category 2: Timer Heap Management Tests
    // =======================================================================

    #[test]
    fn timer_fires_at_visible_at_plus_grace() {
        // Timer should fire at visible_at + grace_period
        let now_ms = 1_700_000_000_000i64;
        let visible_at_ms = now_ms + 10_000; // 10 seconds from now
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &visible_at_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        match action {
            NotifyAction::AddTimer { fire_at } => {
                let delay = fire_at.duration_since(now_instant);
                // Should be 10s + 100ms = 10.1s
                let expected = Duration::from_millis(10_100);
                assert!(
                    delay >= expected - Duration::from_millis(5)
                        && delay <= expected + Duration::from_millis(5),
                    "Timer should fire at visible_at + grace, got {delay:?}"
                );
            }
            other => panic!("Expected AddTimer, got {other:?}"),
        }
    }

    #[test]
    fn timer_heap_ordering() {
        // Min-heap should return timers in order (earliest first)
        let mut heap: BinaryHeap<Reverse<Instant>> = BinaryHeap::new();
        let now = Instant::now();

        let t1 = now + Duration::from_secs(10);
        let t2 = now + Duration::from_secs(5);
        let t3 = now + Duration::from_secs(15);

        heap.push(Reverse(t1));
        heap.push(Reverse(t2));
        heap.push(Reverse(t3));

        // Should pop in order: t2 (5s), t1 (10s), t3 (15s)
        assert_eq!(heap.pop().unwrap().0, t2);
        assert_eq!(heap.pop().unwrap().0, t1);
        assert_eq!(heap.pop().unwrap().0, t3);
    }

    #[test]
    fn expired_timers_popped_in_batch() {
        // Multiple expired timers should all be poppable
        let mut heap: BinaryHeap<Reverse<Instant>> = BinaryHeap::new();
        let past = Instant::now() - Duration::from_secs(1);

        // Add 3 timers all in the past
        heap.push(Reverse(past - Duration::from_millis(100)));
        heap.push(Reverse(past - Duration::from_millis(200)));
        heap.push(Reverse(past - Duration::from_millis(300)));

        let now = Instant::now();
        let mut fired = 0;

        while let Some(Reverse(fire_at)) = heap.peek() {
            if *fire_at <= now {
                heap.pop();
                fired += 1;
            } else {
                break;
            }
        }

        assert_eq!(fired, 3);
        assert!(heap.is_empty());
    }

    #[test]
    fn timer_does_not_fire_early() {
        // A timer in the future should not fire yet
        let mut heap: BinaryHeap<Reverse<Instant>> = BinaryHeap::new();
        let now = Instant::now();
        let future = now + Duration::from_secs(10);

        heap.push(Reverse(future));

        // Simulate checking at "now" - timer should not fire
        if let Some(Reverse(fire_at)) = heap.peek() {
            assert!(*fire_at > now, "Timer should not fire early");
        }
    }

    // =======================================================================
    // Category 3: Refresh Query Tests
    // =======================================================================

    #[test]
    fn refresh_adds_timers_to_heap() {
        // Refresh with future timers should add them to the heap
        let now_ms = 1_700_000_000_000i64;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let timers = vec![
            now_ms + 10_000, // 10s from now
            now_ms + 30_000, // 30s from now
        ];

        let result = timers_from_refresh(&timers, now_ms, grace, now_instant);

        assert_eq!(result.len(), 2);
        // First timer should fire at ~10.1s
        let delay1 = result[0].duration_since(now_instant);
        assert!(delay1 >= Duration::from_millis(10_000));
        assert!(delay1 <= Duration::from_millis(10_200));
    }

    #[test]
    fn refresh_skips_already_passed_timers() {
        // Timers in the past should not be added
        let now_ms = 1_700_000_000_000i64;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let timers = vec![
            now_ms - 5_000, // 5s ago - should be skipped
            now_ms + 100,   // 100ms from now - delay would be 200ms, should be added
        ];

        let result = timers_from_refresh(&timers, now_ms, grace, now_instant);

        // Only the future timer should be added
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn refresh_with_empty_result() {
        // Empty refresh result should produce no timers
        let now_ms = 1_700_000_000_000i64;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let timers: Vec<i64> = vec![];
        let result = timers_from_refresh(&timers, now_ms, grace, now_instant);

        assert!(result.is_empty());
    }

    #[test]
    fn refresh_timer_includes_grace_period() {
        // Timers from refresh should include grace period
        let now_ms = 1_700_000_000_000i64;
        let grace = Duration::from_millis(500); // Larger grace for clearer test
        let now_instant = Instant::now();

        let timers = vec![now_ms + 10_000]; // 10s from now

        let result = timers_from_refresh(&timers, now_ms, grace, now_instant);

        assert_eq!(result.len(), 1);
        let delay = result[0].duration_since(now_instant);
        // Should be 10s + 500ms = 10.5s
        assert!(delay >= Duration::from_millis(10_400));
        assert!(delay <= Duration::from_millis(10_600));
    }

    #[test]
    fn refresh_boundary_timer_at_exactly_now() {
        // Timer exactly at now should have delay = grace_period only
        let now_ms = 1_700_000_000_000i64;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let timers = vec![now_ms]; // Exactly now

        let result = timers_from_refresh(&timers, now_ms, grace, now_instant);

        // delay = (now_ms - now_ms) + grace = grace = 100ms
        // This is > 0, so it should be added
        assert_eq!(result.len(), 1);
        let delay = result[0].duration_since(now_instant);
        assert!(delay >= Duration::from_millis(90));
        assert!(delay <= Duration::from_millis(110));
    }

    // =======================================================================
    // Edge Case Tests
    // =======================================================================

    #[test]
    fn notify_at_window_boundary_included() {
        // Timer exactly at window end should be included
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &window_end_ms.to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        // At window_end should still be included (<=)
        match action {
            NotifyAction::AddTimer { .. } => {}
            other => panic!("Expected AddTimer at window boundary, got {other:?}"),
        }
    }

    #[test]
    fn notify_just_past_window_boundary_ignored() {
        // Timer just past window end should be ignored
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action(
            &(window_end_ms + 1).to_string(),
            now_ms,
            window_end_ms,
            grace,
            now_instant,
        );

        assert_eq!(action, NotifyAction::Ignore);
    }

    #[test]
    fn notify_negative_timestamp_treated_as_immediate() {
        // Negative timestamp (way in the past) should wake immediately
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action("-1000", now_ms, window_end_ms, grace, now_instant);

        assert_eq!(action, NotifyAction::WakeNow);
    }

    #[test]
    fn notify_zero_timestamp_treated_as_immediate() {
        // Zero timestamp (epoch) is way in the past, should wake immediately
        let now_ms = 1_700_000_000_000i64;
        let window_end_ms = now_ms + 60_000;
        let grace = Duration::from_millis(100);
        let now_instant = Instant::now();

        let action = parse_notify_action("0", now_ms, window_end_ms, grace, now_instant);

        assert_eq!(action, NotifyAction::WakeNow);
    }
}
