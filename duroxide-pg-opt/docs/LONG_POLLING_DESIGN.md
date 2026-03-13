# Long-Polling Design for PostgreSQL Provider

> Reducing PostgreSQL query load using LISTEN/NOTIFY with timer-aware wake scheduling.

## Problem Statement

The current PostgreSQL provider uses a polling-based approach to detect new work:

```
Dispatcher Loop:
1. Call fetch_orchestration_item() → Query DB
2. If None, return immediately
3. Runtime sleeps for dispatcher_idle_sleep (e.g., 50ms)
4. Repeat
```

With N dispatchers polling every X ms, this generates:
- `N × (1000/X) × 2` queries/second (orchestrator + worker queues)
- Example: 4 dispatchers at 50ms = **160 queries/second even when idle**

This creates unnecessary database load and costs, especially in cloud-hosted PostgreSQL.

## Goals

1. **Reduce idle query load by 99%+** (from ~160 q/s to ~1 q/5min per dispatcher)
2. **Maintain or improve work detection latency** (~100ms vs current 0-50ms average)
3. **Precise timer handling** (timers fire within 100ms of visibility time)
4. **Zero changes to duroxide core** - all changes in provider only
5. **Graceful degradation** - if NOTIFY fails, fall back to poll_timeout polling

## Design Overview

### Core Principle

**Notifier is smart. Dispatchers are dumb.**

- **Notifier thread**: Listens for NOTIFY, manages timer heap, wakes dispatchers at the right time
- **Dispatchers**: Try to fetch, wait for wake or timeout, fetch again

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PostgreSQL                                      │
│                                                                             │
│   ┌─────────────────────┐           ┌─────────────────────┐                 │
│   │  orchestrator_queue │           │    worker_queue     │                 │
│   │                     │           │                     │                 │
│   │  INSERT trigger ────┼───────────┼──── INSERT trigger  │                 │
│   └──────────┬──────────┘           └──────────┬──────────┘                 │
│              │                                 │                            │
│              ▼                                 ▼                            │
│        NOTIFY 'orch_work'              NOTIFY 'worker_work'                 │
│        payload: visible_at_ms          payload: visible_at_ms               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PostgresProvider                                   │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         Notifier Thread                                 │ │
│  │                                                                        │ │
│  │   PgListener (dedicated connection)                                    │ │
│  │   Timer heaps (orch + worker)                                          │ │
│  │   Refresh query (async, non-blocking)                                  │ │
│  │                                                                        │ │
│  │   Responsibilities:                                                    │ │
│  │   • Receive NOTIFY from PostgreSQL                                     │ │
│  │   • Track upcoming timers (visible_at in future)                       │ │
│  │   • Wake dispatchers when work is ready                                │ │
│  │   • Periodically refresh timer list from DB                            │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                              │                                              │
│                              │ notify_waiters()                             │
│                              ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    tokio::sync::Notify                                  │ │
│  │                                                                        │ │
│  │   orch_notify: Arc<Notify>    worker_notify: Arc<Notify>               │ │
│  │                                                                        │ │
│  │   • Wake ALL waiting dispatchers                                       │ │
│  │   • No buffering (if no waiter, notification is "lost" - that's OK)   │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                    │              │              │                          │
│                    ▼              ▼              ▼                          │
│             ┌───────────┐  ┌───────────┐  ┌───────────┐                    │
│             │Dispatcher │  │Dispatcher │  │Dispatcher │                    │
│             │    1      │  │    2      │  │    3      │                    │
│             │           │  │           │  │           │                    │
│             │ fetch()   │  │ fetch()   │  │ fetch()   │                    │
│             │ wait()    │  │ wait()    │  │ wait()    │                    │
│             │ fetch()   │  │ fetch()   │  │ fetch()   │                    │
│             └───────────┘  └───────────┘  └───────────┘                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Database Schema

### NOTIFY Triggers

```sql
-- Migration: Add NOTIFY triggers for long-polling

-- Orchestrator queue notification
-- Payload: visible_at as epoch milliseconds
CREATE OR REPLACE FUNCTION {schema}.notify_orch_work()
RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify(
        '{schema}_orch_work',
        (EXTRACT(EPOCH FROM NEW.visible_at) * 1000)::BIGINT::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Worker queue notification
CREATE OR REPLACE FUNCTION {schema}.notify_worker_work()
RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify(
        '{schema}_worker_work',
        (EXTRACT(EPOCH FROM NEW.visible_at) * 1000)::BIGINT::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach triggers
CREATE TRIGGER trg_orch_notify
    AFTER INSERT ON {schema}.orchestrator_queue
    FOR EACH ROW EXECUTE FUNCTION {schema}.notify_orch_work();

CREATE TRIGGER trg_worker_notify
    AFTER INSERT ON {schema}.worker_queue
    FOR EACH ROW EXECUTE FUNCTION {schema}.notify_worker_work();
```

## Clock Source Design

### Decision: Rust Clock Only (No DB-Generated Timestamps)

All timestamps in the system are generated by the Rust application using `SystemTime::now()`. 
The PostgreSQL database **never** generates timestamps via `NOW()` or `CURRENT_TIMESTAMP`.

**Rationale:**

1. **Single Clock Source**: All `visible_at` values come from the same clock source, making timing analysis simpler
2. **Predictable Behavior**: When a node writes `visible_at = now + delay`, it can later read with the same clock
3. **Multi-Node Consistency**: Each node uses its own NTP-synced clock; cross-node skew is bounded by NTP accuracy (~50ms typical)
4. **Testability**: Can inject mock clocks for deterministic testing

**Implementation:**

```rust
impl PostgresProvider {
    /// Single source of truth for all timestamps
    fn now_millis() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
    }
}
```

All stored procedures that need timestamps receive `p_now_ms BIGINT` as a parameter:
- `ack_orchestration_item(p_lock_token, p_now_ms, ...)`
- `ack_worker(p_lock_token, p_now_ms, ...)`
- `enqueue_worker_work(p_work_item, p_now_ms)`
- `enqueue_orchestrator_work(p_instance_id, p_work_item, p_visible_at, p_now_ms, ...)`
- `abandon_orchestration_item(p_lock_token, p_now_ms, ...)`
- `abandon_work_item(p_lock_token, p_now_ms, ...)`

**Table Schema:**

Timestamp columns use `NOT NULL` without defaults, forcing the provider to always supply values:

```sql
CREATE TABLE orchestrator_queue (
    ...
    visible_at TIMESTAMPTZ NOT NULL,  -- No DEFAULT
    created_at TIMESTAMPTZ NOT NULL   -- No DEFAULT
);
```

### Multi-Node Clock Skew Analysis

**Scenario: Two nodes (A and B) with clock skew**

```
Node A clock: 12:00:00.000
Node B clock: 12:00:00.100  (100ms ahead)
DB has no clock (all timestamps from nodes)

Case 1: Node A writes timer, Node A reads
  - A writes: visible_at = 12:00:05.000 (5s timer)
  - A reads at its 12:00:05.000: timer is visible ✓

Case 2: Node A writes timer, Node B reads
  - A writes: visible_at = 12:00:05.000
  - B reads at its 12:00:05.000 (which is A's 12:00:04.900)
  - B thinks timer is ready, but item was written with A's clock
  - Timer fires 100ms "early" from A's perspective
  - Grace period (100ms) absorbs this ✓

Case 3: Node B writes timer, Node A reads  
  - B writes: visible_at = 12:00:05.100 (B's now + 5s)
  - A reads at its 12:00:05.100 (which is B's 12:00:05.200)
  - Timer fires 100ms "late" from B's perspective
  - Acceptable - within NTP bounds ✓
```

**Conclusion:** With NTP-synced servers (typical skew < 100ms), the 100ms grace period provides sufficient tolerance.

### Corner Cases

| Case | Description | Impact | Mitigation |
|------|-------------|--------|------------|
| Node clock jumps forward | NTP correction or manual change | Timers may fire early | Grace period absorbs small jumps; large jumps are operational errors |
| Node clock jumps backward | NTP correction | Timers may be delayed | Eventually fire when clock catches up |
| DB restarts | Irrelevant - DB doesn't track time | None | N/A |
| Node restart | New `now_millis()` calls from fresh SystemTime | None - clock continues | N/A |
| VM suspend/resume | Clock may jump on resume | Same as clock jump | Same mitigations |

## Configuration

```rust
/// Configuration for long-polling behavior
pub struct LongPollConfig {
    /// Enable long-polling (LISTEN/NOTIFY based)
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
```

## Notifier Thread

### Structure

```rust
struct Notifier {
    // PostgreSQL connection for LISTEN
    pg_listener: PgListener,
    pool: PgPool,
    schema_name: String,
    
    // Timer heaps (min-heap by fire time)
    orch_heap: BinaryHeap<Reverse<Instant>>,
    worker_heap: BinaryHeap<Reverse<Instant>>,
    
    // Dispatcher wake channels
    orch_notify: Arc<Notify>,
    worker_notify: Arc<Notify>,
    
    // Refresh scheduling
    next_refresh: Instant,
    
    // Active refresh task (if any)
    // Using oneshot because each refresh produces exactly one result.
    // We store the receiver here; sender goes to the spawned task.
    pending_refresh: Option<oneshot::Receiver<RefreshResult>>,
    
    // Config
    config: LongPollConfig,
}

struct RefreshResult {
    orch_timers: Vec<i64>,   // visible_at as epoch ms
    worker_timers: Vec<i64>,
}
```

**Why `oneshot` instead of `mpsc`?**
- Each refresh task produces exactly ONE result
- `oneshot::Receiver` is consumed on receive (no stale results)
- `pending_refresh: Option<...>` replaces the `refresh_in_progress` bool
- Cleaner semantics: `Some(rx)` = refresh in progress, `None` = idle

### Construction and Connection

```rust
impl Notifier {
    async fn new(
        pool: PgPool,
        schema_name: String,
        orch_notify: Arc<Notify>,
        worker_notify: Arc<Notify>,
        config: LongPollConfig,
    ) -> Result<Self, Error> {
        let mut notifier = Self {
            pg_listener: PgListener::connect_with(&pool).await?,
            pool,
            schema_name,
            orch_heap: BinaryHeap::new(),
            worker_heap: BinaryHeap::new(),
            orch_notify,
            worker_notify,
            next_refresh: Instant::now(), // Immediate first refresh
            pending_refresh: None,
            config,
        };
        
        notifier.subscribe_channels().await?;
        Ok(notifier)
    }
    
    /// Subscribe to NOTIFY channels. Used by new() and handle_reconnect().
    async fn subscribe_channels(&mut self) -> Result<(), Error> {
        self.pg_listener
            .listen(&format!("{}_orch_work", self.schema_name))
            .await?;
        self.pg_listener
            .listen(&format!("{}_worker_work", self.schema_name))
            .await?;
        Ok(())
    }
}
```

### Main Loop

```rust
impl Notifier {
    async fn run(&mut self) {
        loop {
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
            
            select! {
                // PostgreSQL NOTIFY received
                result = self.pg_listener.recv() => {
                    match result {
                        Ok(notification) => self.handle_notify(notification),
                        Err(_) => self.handle_reconnect().await,
                    }
                }
                
                // Timer or refresh time reached
                _ = sleep_until(next_wake) => {
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
                    self.pending_refresh = None;  // Consume the receiver
                    self.handle_refresh_result(result);
                }
            }
        }
    }
    
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
}
```

### Handling NOTIFY

```rust
impl Notifier {
    fn handle_notify(&mut self, notification: PgNotification) {
        let visible_at_ms: i64 = notification.payload()
            .parse()
            .unwrap_or(0);  // 0 = treat as immediate
        
        let now_ms = current_epoch_ms();
        let window_end_ms = instant_to_epoch_ms(self.next_refresh);
        
        let is_orch = notification.channel().ends_with("_orch_work");
        
        if visible_at_ms <= now_ms {
            // Immediately visible → wake dispatchers now
            // No grace period needed: NOTIFY only fires after INSERT commits,
            // so the row is already queryable.
            self.wake_dispatchers(is_orch);
        } else if visible_at_ms <= window_end_ms {
            // Future timer within current window → schedule a timer
            // 
            // We add grace_period to the DELAY (not to visible_at) to ensure
            // the timer fires slightly after visible_at, even if tokio fires
            // a few ms early due to timer jitter.
            //
            // delay = (visible_at - now) + grace_period
            //
            // Example with Node B 100ms ahead:
            //   now_ms = T+0.1, visible_at = T+5, grace = 100ms
            //   delay = (T+5 - T+0.1) + 0.1 = 5.0 seconds
            //   fires at T+5.1 (Node B clock) → definitely past T+5
            //
            let delay_ms = (visible_at_ms - now_ms) + self.config.timer_grace_period.as_millis() as i64;
            let fire_at = Instant::now() + Duration::from_millis(delay_ms as u64);
            
            if is_orch {
                self.orch_heap.push(Reverse(fire_at));
            } else {
                self.worker_heap.push(Reverse(fire_at));
            }
        }
        // Beyond window → ignore, refresh will catch it
    }
    
    fn wake_dispatchers(&self, is_orch: bool) {
        if is_orch {
            self.orch_notify.notify_waiters();
        } else {
            self.worker_notify.notify_waiters();
        }
    }
}
```

### Timer Management

```rust
impl Notifier {
    fn pop_and_wake_expired_timers(&mut self) {
        let now = Instant::now();
        
        // Pop expired orchestrator timers
        while let Some(Reverse(fire_at)) = self.orch_heap.peek() {
            if *fire_at <= now {
                self.orch_heap.pop();
                self.orch_notify.notify_waiters();
            } else {
                break;
            }
        }
        
        // Pop expired worker timers
        while let Some(Reverse(fire_at)) = self.worker_heap.peek() {
            if *fire_at <= now {
                self.worker_heap.pop();
                self.worker_notify.notify_waiters();
            } else {
                break;
            }
        }
    }
}
```

### Refresh Query (Non-Blocking)

The refresh query is spawned as a separate task to avoid blocking the main loop during slow queries (up to 5s latency).

```rust
impl Notifier {
    fn maybe_start_refresh(&mut self) {
        // Skip if refresh already in progress or not yet due
        if self.pending_refresh.is_some() || Instant::now() < self.next_refresh {
            return;
        }
        
        let (tx, rx) = oneshot::channel();
        self.pending_refresh = Some(rx);
        
        let pool = self.pool.clone();
        let schema = self.schema_name.clone();
        let now_ms = current_epoch_ms();  // Rust clock
        let window_end_ms = now_ms + self.config.notifier_poll_interval.as_millis() as i64;
        
        tokio::spawn(async move {
            // Query for upcoming timers in both queues
            // Use Rust clock ($1) for "now" comparison, not database NOW()
            let orch_timers = sqlx::query_scalar::<_, i64>(&format!(
                "SELECT (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT
                 FROM {}.orchestrator_queue
                 WHERE (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT > $1
                   AND (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT <= $2
                   AND locked_until IS NULL",
                schema
            ))
            .bind(now_ms)
            .bind(window_end_ms)
            .fetch_all(&pool)
            .await
            .unwrap_or_default();
            
            let worker_timers = sqlx::query_scalar::<_, i64>(&format!(
                "SELECT (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT
                 FROM {}.worker_queue
                 WHERE (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT > $1
                   AND (EXTRACT(EPOCH FROM visible_at) * 1000)::BIGINT <= $2
                   AND locked_until IS NULL",
                schema
            ))
            .bind(now_ms)
            .bind(window_end_ms)
            .fetch_all(&pool)
            .await
            .unwrap_or_default();
            
            // Send result (ignore error if receiver dropped)
            let _ = tx.send(RefreshResult { orch_timers, worker_timers });
        });
    }
    
    fn handle_refresh_result(&mut self, result: RefreshResult) {
        let now_ms = current_epoch_ms();
        let grace_ms = self.config.timer_grace_period.as_millis() as i64;
        
        // Add orchestrator timers
        for visible_at_ms in result.orch_timers {
            // delay = (visible_at - now) + grace_period
            let delay_ms = (visible_at_ms - now_ms) + grace_ms;
            if delay_ms > 0 {
                let fire_at = Instant::now() + Duration::from_millis(delay_ms as u64);
                self.orch_heap.push(Reverse(fire_at));
            }
        }
        
        // Add worker timers
        for visible_at_ms in result.worker_timers {
            // delay = (visible_at - now) + grace_period
            let delay_ms = (visible_at_ms - now_ms) + grace_ms;
            if delay_ms > 0 {
                let fire_at = Instant::now() + Duration::from_millis(delay_ms as u64);
                self.worker_heap.push(Reverse(fire_at));
            }
        }
        
        // pending_refresh already set to None in select! branch
        self.next_refresh = Instant::now() + self.config.notifier_poll_interval;
    }
}
```

### Reconnection Handling

```rust
impl Notifier {
    async fn handle_reconnect(&mut self) {
        // Backoff before reconnect attempt
        tokio::time::sleep(Duration::from_secs(1)).await;
        
        // Reconnect and resubscribe (reuses subscribe_channels from new())
        if let Ok(listener) = PgListener::connect_with(&self.pool).await {
            self.pg_listener = listener;
            
            if self.subscribe_channels().await.is_ok() {
                // Wake all dispatchers to catch any missed NOTIFYs during disconnect
                self.orch_notify.notify_waiters();
                self.worker_notify.notify_waiters();
                
                // Force immediate refresh to rebuild timer heaps
                self.next_refresh = Instant::now();
            }
        }
        // If reconnect fails, loop will call handle_reconnect again on next recv() error
    }
}
```

## Dispatcher Integration

The dispatcher's fetch methods are modified to wait for a wake signal or timeout:

```rust
impl PostgresProvider {
    async fn fetch_orchestration_item(
        &self,
        lock_timeout: Duration,
        poll_timeout: Duration,
    ) -> Result<Option<(OrchestrationItem, String, u32)>, ProviderError> {
        
        // Step 1: Try to fetch immediately
        let result = self.do_fetch_orchestration_item(lock_timeout).await?;
        if result.is_some() {
            return Ok(result);
        }
        
        // Step 2: No work - wait for wake signal or timeout
        if let Some(notify) = &self.orch_notify {
            select! {
                _ = notify.notified() => {
                    // Woken by notifier (NOTIFY or timer) - fetch now
                    return self.do_fetch_orchestration_item(lock_timeout).await;
                }
                _ = tokio::time::sleep(poll_timeout) => {
                    // Timeout - return None, let runtime handle idle sleep
                    // Next call will do_fetch() as first step anyway
                    return Ok(None);
                }
            }
        }
        
        // Long-poll disabled - return immediately (old behavior)
        Ok(None)
    }
    
    async fn fetch_work_item(
        &self,
        lock_timeout: Duration,
        poll_timeout: Duration,
    ) -> Result<Option<(WorkItem, String, u32)>, ProviderError> {
        
        // Same pattern as fetch_orchestration_item
        let result = self.do_fetch_work_item(lock_timeout).await?;
        if result.is_some() {
            return Ok(result);
        }
        
        if let Some(notify) = &self.worker_notify {
            select! {
                _ = notify.notified() => {
                    return self.do_fetch_work_item(lock_timeout).await;
                }
                _ = tokio::time::sleep(poll_timeout) => {
                    return Ok(None);
                }
            }
        }
        
        Ok(None)
    }
}
```

## Timing Analysis

### NOTIFY Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NOTIFY Decision Tree                                 │
│                                                                             │
│   NOTIFY received with visible_at:                                          │
│                                                                             │
│                         visible_at                                          │
│                             │                                               │
│                             ▼                                               │
│                 ┌───────────────────────┐                                   │
│                 │  visible_at <= now?   │                                   │
│                 └───────────┬───────────┘                                   │
│                             │                                               │
│                ┌────────────┴────────────┐                                  │
│                ▼                         ▼                                  │
│              YES                        NO                                  │
│                │                         │                                  │
│                ▼                         ▼                                  │
│   ┌─────────────────────┐   ┌─────────────────────────────┐                │
│   │ Wake dispatchers    │   │ visible_at <= next_refresh? │                │
│   │ immediately         │   └─────────────┬───────────────┘                │
│   └─────────────────────┘                 │                                │
│                              ┌────────────┴────────────┐                   │
│                              ▼                         ▼                   │
│                            YES                        NO                   │
│                              │                         │                   │
│                              ▼                         ▼                   │
│                 ┌──────────────────────┐   ┌─────────────────────┐         │
│                 │ heap.push(           │   │ Ignore              │         │
│                 │   visible_at + 100ms │   │ (refresh will       │         │
│                 │ )                    │   │  catch it later)    │         │
│                 └──────────────────────┘   └─────────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Timer Buffer (100ms Grace Period)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Timer Fire Sequence                                  │
│                                                                             │
│   visible_at          visible_at + 100ms         fetch query                │
│       │                      │                       │                      │
│       ▼                      ▼                       ▼                      │
│   ────┼──────────────────────┼───────────────────────┼───────►              │
│       │                      │                       │                      │
│       │   ◄── grace ──►      │                       │                      │
│       │      period          │                       │                      │
│       │      100ms           │                       │                      │
│       │                      │                       │                      │
│    Row becomes            Timer fires,          SELECT succeeds             │
│    queryable              wake dispatchers      (row definitely visible)    │
│                                                                             │
│   Why 100ms buffer?                                                         │
│   • Clock skew between application and database                             │
│   • Network latency                                                         │
│   • Transaction commit timing                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Timeline Examples

```
notifier_poll_interval = 60s
timer_grace_period = 100ms

═══════════════════════════════════════════════════════════════════════════════

Case 1: Immediate Work
──────────────────────

t=0:      INSERT(visible_at=NOW) → NOTIFY(payload=now_ms)
t=0+ε:    Notifier: visible_at <= now → wake dispatchers
t=0+ε:    Dispatcher wakes, fetches work ✓

Latency: <1ms

═══════════════════════════════════════════════════════════════════════════════

Case 2: Timer Within Window
───────────────────────────

t=0:      Notifier starts, next_refresh = 60s
t=5s:     INSERT(visible_at = t+25s = 30s) → NOTIFY(payload=30000)
          Notifier: 30s > now, 30s <= 60s → heap.push(30.1s)
t=30.1s:  Timer fires → wake dispatchers
t=30.1s:  Dispatcher fetches work ✓

Latency: 100ms (grace period)

═══════════════════════════════════════════════════════════════════════════════

Case 3: Timer Beyond Window
───────────────────────────

t=0:      Notifier starts, next_refresh = 60s
t=10s:    INSERT(visible_at = t+70s = 80s) → NOTIFY(payload=80000)
          Notifier: 80s > 60s → IGNORE
t=60s:    Refresh query: visible_at in (60s, 120s)
          Finds visible_at=80s → heap.push(80.1s)
          next_refresh = 120s
t=80.1s:  Timer fires → wake dispatchers ✓

Latency: 100ms (grace period)

═══════════════════════════════════════════════════════════════════════════════

Case 4: Work Exists Before Notifier Starts
──────────────────────────────────────────

t=-5s:    INSERT(visible_at = now) → work is immediately visible
t=0:      Notifier starts
          Refresh query: visible_at in (0, 60s)
          (visible_at = -5s not in range, missed by query)
t=0.5s:   Dispatcher starts
          do_fetch() → FINDS THE WORK! ✓

Key: Dispatcher always calls do_fetch() first, catches existing work.

═══════════════════════════════════════════════════════════════════════════════

Case 5: NOTIFY Lost (All Dispatchers Busy)
──────────────────────────────────────────

t=0:      All dispatchers processing work
t=1s:     INSERT(visible_at=now) → NOTIFY
          Notifier: notify_waiters() → no waiters, "lost"
t=2s:     Dispatcher 1 finishes processing
          Calls fetch_orchestration_item()
          Step 1: do_fetch() → FINDS THE WORK! ✓

Key: do_fetch() always runs first, notification is optimization only.

═══════════════════════════════════════════════════════════════════════════════
```

## Failure Modes and Resilience

### Litmus Test: Notifier Thread Dead

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Q: Do dispatchers function correctly if notifier thread is dead?          │
│                                                                             │
│   A: YES - they degrade to poll_timeout polling.                            │
│                                                                             │
│   Dispatcher fetch():                                                       │
│     1. do_fetch() → None                                                    │
│     2. select! {                                                            │
│          notify.notified() => {}  ← never fires (thread dead)               │
│          sleep(poll_timeout) => {} ← fires after poll_timeout               │
│        }                                                                    │
│     3. do_fetch() → might find work                                         │
│                                                                             │
│   Result: Polls every poll_timeout (default 5 min) instead of on-demand.    │
│   Work is never lost, just detected with higher latency.                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Resilience Summary

| Failure Mode | Behavior | Impact |
|--------------|----------|--------|
| Notifier thread dead | Fall back to poll_timeout | Latency up to poll_timeout |
| NOTIFY connection drops | Reconnect + wake all + refresh | Brief delay, then normal |
| NOTIFY lost (no waiters) | do_fetch() finds work anyway | No impact |
| Refresh query slow (5s) | Non-blocking, loop continues | No impact on NOTIFY/timers |
| Refresh query fails | Retry on next interval | Timers may be delayed |
| Duplicate timers in heap | Extra wake, dispatcher polls | Harmless (slight overhead) |

### Why `tokio::sync::Notify` is Sufficient

| Concern | Answer |
|---------|--------|
| What if notification is lost? | `do_fetch()` runs first every loop, finds visible work |
| What about buffering? | Not needed - work is in DB, not in channel |
| Thundering herd? | Yes, all dispatchers wake, but `SKIP LOCKED` handles contention |
| Memory usage? | Zero buffering, minimal overhead |

## Query Load Analysis

### Before (Short Polling)

```
4 dispatchers × 20 polls/sec × 2 queues = 160 queries/sec when idle
```

### After (Long Polling)

```
Idle state:
- 0 polls from dispatchers (waiting on notify)
- 1 refresh query per 60s = 0.017 queries/sec per queue
- Total: ~0.03 queries/sec

Active state:
- NOTIFY triggers immediate wake
- 1 query per work item processed
- Same as before for actual work
```

### Improvement

```
Idle: 160 q/s → 0.03 q/s = 99.98% reduction
Active: Same query efficiency (one fetch per work item)
```

## Provider Structure Changes

```rust
pub struct PostgresProvider {
    pool: Arc<PgPool>,
    schema_name: String,
    
    // Long-poll infrastructure (None if disabled)
    orch_notify: Option<Arc<Notify>>,
    worker_notify: Option<Arc<Notify>>,
    notifier_handle: Option<JoinHandle<()>>,
    
    // Config
    long_poll_config: LongPollConfig,
}

impl PostgresProvider {
    /// Create provider with default config (long-poll disabled)
    pub async fn new(database_url: &str) -> Result<Self> {
        Self::new_with_options(database_url, None, LongPollConfig::default()).await
    }
    
    /// Create provider with long-polling enabled
    pub async fn new_with_long_poll(database_url: &str) -> Result<Self> {
        let config = LongPollConfig {
            enabled: true,
            ..Default::default()
        };
        Self::new_with_options(database_url, None, config).await
    }
    
    /// Create provider with full configuration
    pub async fn new_with_options(
        database_url: &str,
        schema_name: Option<&str>,
        config: LongPollConfig,
    ) -> Result<Self> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .connect(database_url)
            .await?;
        
        let schema = schema_name.unwrap_or("public").to_string();
        
        let (orch_notify, worker_notify, notifier_handle) = if config.enabled {
            let orch_notify = Arc::new(Notify::new());
            let worker_notify = Arc::new(Notify::new());
            
            let notifier = Notifier::new(
                pool.clone(),
                schema.clone(),
                orch_notify.clone(),
                worker_notify.clone(),
                config.clone(),
            ).await?;
            
            let handle = tokio::spawn(async move {
                notifier.run().await;
            });
            
            (Some(orch_notify), Some(worker_notify), Some(handle))
        } else {
            (None, None, None)
        };
        
        Ok(Self {
            pool: Arc::new(pool),
            schema_name: schema,
            orch_notify,
            worker_notify,
            notifier_handle,
            long_poll_config: config,
        })
    }
}

impl Drop for PostgresProvider {
    fn drop(&mut self) {
        if let Some(handle) = self.notifier_handle.take() {
            handle.abort();
        }
    }
}
```

## Summary

| Component | Responsibility |
|-----------|----------------|
| **Database triggers** | Fire NOTIFY with visible_at on INSERT |
| **Notifier thread** | Listen for NOTIFY, manage timer heap, wake dispatchers |
| **Timer heap** | Track upcoming visible_at times, fire at +100ms grace |
| **Refresh query** | Periodic safety net, catch missed NOTIFYs, rebuild heap |
| **Dispatcher** | fetch() → wait(notify OR timeout) → fetch() |
| **poll_timeout** | Ultimate safety net, graceful degradation |

### Key Design Properties

1. **Correctness independent of notifier** - Dispatchers work if notifier dies
2. **No work lost** - Work is in DB, notifications are optimization
3. **Bounded memory** - Timer heap only tracks within refresh window
4. **Non-blocking refresh** - Slow queries don't block NOTIFY handling
5. **Graceful degradation** - Falls back to poll_timeout polling
6. **Simple dispatchers** - All timing logic in notifier thread

---

## Test Plan

### Unit Tests

#### 1. Notifier NOTIFY Handling

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `notify_immediate_work_wakes_dispatchers` | Notifier running | NOTIFY with visible_at = now | `notify_waiters()` called immediately |
| `notify_past_visible_at_wakes_immediately` | Notifier running | NOTIFY with visible_at = now - 5s | `notify_waiters()` called immediately (already visible) |
| `notify_future_timer_adds_to_heap` | Notifier running, next_refresh = 60s | NOTIFY with visible_at = now + 30s | Timer added to heap, fires at now + 30.1s |
| `notify_beyond_window_ignored` | Notifier running, next_refresh = 60s | NOTIFY with visible_at = now + 90s | Timer NOT added (refresh will catch) |
| `notify_invalid_payload_treated_as_immediate` | Notifier running | NOTIFY with payload = "garbage" | `notify_waiters()` called (default to 0) |
| `notify_empty_payload_treated_as_immediate` | Notifier running | NOTIFY with payload = "" | `notify_waiters()` called |

#### 2. Timer Heap Management

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `timer_fires_at_visible_at_plus_grace` | Timer at t=10s in heap | Advance to t=10.1s | `notify_waiters()` called |
| `timer_does_not_fire_early` | Timer at t=10s in heap | Advance to t=9.9s | No wake |
| `multiple_timers_fire_in_order` | Timers at t=5s, t=10s, t=15s | Advance time | Wakes at 5.1s, 10.1s, 15.1s |
| `expired_timers_popped_in_batch` | Timers at t=5s, t=6s, t=7s | Advance to t=10s | All three fire, heap empty |
| `orch_and_worker_timers_separate` | Orch timer at t=5s, worker at t=10s | Advance time | Correct notify channel woken |

#### 3. Refresh Query

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `refresh_queries_correct_window` | next_refresh = now | Trigger refresh | Query for visible_at in (now, now+60s) |
| `refresh_adds_timers_to_heap` | DB has timers at t+10s, t+30s | Refresh completes | Both timers in heap |
| `refresh_skips_already_passed_timers` | DB has timer at t-5s | Refresh completes | Timer NOT added to heap |
| `refresh_is_non_blocking` | - | Start refresh, receive NOTIFY | NOTIFY processed immediately |
| `refresh_updates_next_refresh_time` | next_refresh = t | Refresh completes | next_refresh = t + 60s |
| `concurrent_refresh_prevented` | Refresh in progress | Trigger refresh again | Second refresh ignored |

#### 4. Dispatcher Fetch Logic

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `fetch_returns_immediately_when_work_exists` | Work in queue | Call fetch() | Returns work, no wait |
| `fetch_waits_for_notify_when_no_work` | No work, notify channel | Call fetch() | Blocks until notify |
| `fetch_times_out_after_poll_timeout` | No work, no notify | Call fetch(poll_timeout=1s) | Returns None after 1s |
| `fetch_works_without_notify_channel` | Long-poll disabled | Call fetch() | Returns immediately (old behavior) |
| `fetch_finds_work_after_wake` | No work initially | Insert work, notify, check fetch | Returns the new work |

### Integration Tests

#### 5. End-to-End NOTIFY Flow

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `e2e_immediate_work_detected` | Provider with long-poll | INSERT into orch queue | Dispatcher wakes within 100ms |
| `e2e_timer_fires_correctly` | Provider with long-poll | INSERT with visible_at = now + 5s | Dispatcher wakes at 5.1s |
| `e2e_multiple_dispatchers_wake` | 3 dispatchers waiting | INSERT immediate work | All 3 wake, 1 gets work |
| `e2e_worker_and_orch_separate` | Dispatchers for both queues | INSERT into worker queue | Only worker dispatchers wake |

#### 6. Resilience Tests

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `resilience_notifier_dead` | Kill notifier thread | INSERT work, wait poll_timeout | Dispatcher finds work via timeout |
| `resilience_connection_drop` | Drop PgListener connection | Wait for reconnect, INSERT | Work detected after reconnect |
| `resilience_notify_during_busy` | All dispatchers processing | INSERT immediate work | Next free dispatcher finds work |
| `resilience_work_before_startup` | INSERT work before provider | Start provider | Dispatcher finds work on first fetch |
| `resilience_slow_refresh_query` | Mock 5s query latency | NOTIFY during refresh | NOTIFY processed immediately |

#### 7. Timer Precision Tests

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `timer_precision_100ms_grace` | - | INSERT with visible_at = now + 1s | Wake at 1.1s ± 50ms |
| `timer_precision_many_timers` | 100 timers at 100ms intervals | Wait for all | All fire within 50ms of expected |
| `timer_precision_under_load` | High insert rate | Measure timer accuracy | 95th percentile < 200ms error |

### Performance Tests

#### 8. Query Load Verification

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `perf_idle_query_count` | Provider with long-poll, idle | Count queries over 5 min | < 10 queries total |
| `perf_no_polling_when_idle` | Provider with long-poll, idle | Monitor for 1 min | 0 fetch queries |
| `perf_immediate_work_latency` | Provider with long-poll | Measure INSERT to fetch time | p99 < 50ms |

#### 9. High Query Latency Tests

These tests verify the system handles slow database queries gracefully (up to 5s latency).

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `latency_refresh_does_not_block_notify` | Inject 5s refresh query delay | NOTIFY during refresh | NOTIFY processed < 100ms |
| `latency_refresh_does_not_block_timers` | Inject 5s refresh query delay | Timer should fire during refresh | Timer fires on schedule |
| `latency_multiple_refreshes_not_stacked` | Inject 3s delay, 1s refresh interval | Wait 5s | Only 1 refresh query runs at a time |
| `latency_refresh_result_applied_correctly` | Inject 2s delay | Check heap after refresh | Timers added correctly despite delay |
| `latency_stale_refresh_data_handled` | Inject 5s delay | Insert timer at t+3s during query | Timer caught by NOTIFY, not duplicate |
| `latency_fetch_timeout_independent` | Inject 5s refresh delay | Dispatcher with 1s poll_timeout | Dispatcher times out correctly |

**Latency Simulation Approach:**

```rust
/// Wrapper to inject latency into database queries
struct LatencyInjector {
    base_pool: PgPool,
    refresh_delay: AtomicU64,  // milliseconds
    fetch_delay: AtomicU64,
}

impl LatencyInjector {
    fn set_refresh_delay(&self, delay: Duration) {
        self.refresh_delay.store(delay.as_millis() as u64, Ordering::Relaxed);
    }
    
    fn set_fetch_delay(&self, delay: Duration) {
        self.fetch_delay.store(delay.as_millis() as u64, Ordering::Relaxed);
    }
    
    async fn execute_refresh_query(&self, query: &str) -> Result<Vec<i64>> {
        let delay = self.refresh_delay.load(Ordering::Relaxed);
        if delay > 0 {
            tokio::time::sleep(Duration::from_millis(delay)).await;
        }
        sqlx::query_scalar(query).fetch_all(&self.base_pool).await
    }
}
```

**Test Scenarios with Latency:**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              Scenario: 5s Refresh Latency with Concurrent NOTIFY            │
│                                                                             │
│   t=0:      Refresh starts (will take 5s)                                   │
│   t=1s:     NOTIFY arrives (immediate work)                                 │
│             → Main loop NOT blocked                                         │
│             → notify_waiters() called immediately ✓                         │
│   t=2s:     NOTIFY arrives (timer at t+3s = 5s)                             │
│             → Timer added to heap for t=5.1s ✓                              │
│   t=5s:     Refresh completes                                               │
│             → Process results, schedule next refresh                        │
│   t=5.1s:   Timer fires → wake dispatchers ✓                                │
│                                                                             │
│   Verification:                                                             │
│   • NOTIFY at t=1s woke dispatchers at t=1s (not t=5s)                      │
│   • Timer at t=5s fired at t=5.1s (not delayed by refresh)                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│              Scenario: Slow Fetch Query (Dispatcher Side)                    │
│                                                                             │
│   t=0:      Dispatcher calls fetch(), starts query (will take 3s)           │
│   t=1s:     NOTIFY arrives                                                  │
│             → Dispatcher still in query, not waiting on notify              │
│             → Notification "lost" for this dispatcher                       │
│   t=3s:     Fetch query completes → returns work                            │
│   t=3s+ε:   Dispatcher returns, calls fetch() again                         │
│             → do_fetch() finds any new work from t=1s ✓                     │
│                                                                             │
│   Key: Slow fetch is fine because:                                          │
│   1. Dispatcher will call do_fetch() again after returning                  │
│   2. Work is in DB, will be found on next fetch                             │
│   3. Other dispatchers can pick up work                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### 10. Stress Tests

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `stress_high_notify_rate` | Provider with long-poll | 1000 NOTIFY/sec for 1 min | No crashes, all work processed |
| `stress_many_timers` | Provider with long-poll | INSERT 10000 timers, random visible_at | All fire correctly |
| `stress_connection_flapping` | Provider with long-poll | Drop connection every 5s | Work still processed |

#### 11. Clock Skew and Fault Injection Tests

These tests verify correct behavior under clock anomalies and multi-node scenarios.

| Test | Setup | Action | Expected |
|------|-------|--------|----------|
| `clock_skew_within_grace_period` | Mock clock 50ms ahead | Write timer, read from "other node" | Timer fires correctly (within grace) |
| `clock_skew_exceeds_grace_period` | Mock clock 200ms behind | Write timer, advance, read | Timer may fire late; falls back to poll_timeout |
| `clock_jump_forward_small` | Advance mock clock 50ms suddenly | Timer scheduled for near-future | Timer fires early; grace period absorbs |
| `clock_jump_forward_large` | Advance mock clock 10s suddenly | Multiple pending timers | All pending timers fire immediately |
| `clock_jump_backward` | Rewind mock clock 100ms | Timer scheduled | Timer delayed until clock catches up |
| `multi_node_write_read` | Two providers (A, B) with offset clocks | A writes timer, B reads | Timer visible within grace period tolerance |

**Fault Injection Scenarios:**

| Test | Fault Injected | Expected Behavior |
|------|----------------|-------------------|
| `fault_notifier_panic` | Force panic in notifier thread | Dispatchers fall back to poll_timeout |
| `fault_pg_listener_disconnect` | Close listener connection | Auto-reconnect, wake all, refresh heap |
| `fault_refresh_query_timeout` | Query hangs for 30s | Main loop continues processing NOTIFY/timers |
| `fault_refresh_query_error` | Query returns error | Retry on next interval, log warning |
| `fault_notify_channel_full` | N/A (Notify has no buffer) | Implicit test - ensure no deadlock |
| `fault_heap_corruption` | Insert timer with negative delay | Timer fires immediately (no crash) |
| `fault_db_connection_pool_exhausted` | Max out pool connections | Refresh query waits, NOTIFY still works |

**Clock Injection Implementation:**

```rust
/// Injectable clock for testing clock skew scenarios
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> i64;
}

/// Real system clock (production)
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
    }
}

/// Controllable clock for testing
pub struct MockClock {
    offset_ms: AtomicI64,  // Offset from real time
    base: SystemClock,
}

impl MockClock {
    pub fn new() -> Self {
        Self {
            offset_ms: AtomicI64::new(0),
            base: SystemClock,
        }
    }
    
    /// Simulate clock skew (positive = ahead, negative = behind)
    pub fn set_skew(&self, skew: Duration, ahead: bool) {
        let ms = skew.as_millis() as i64;
        self.offset_ms.store(if ahead { ms } else { -ms }, Ordering::SeqCst);
    }
    
    /// Simulate sudden clock jump
    pub fn jump(&self, amount: Duration, forward: bool) {
        let delta = amount.as_millis() as i64;
        if forward {
            self.offset_ms.fetch_add(delta, Ordering::SeqCst);
        } else {
            self.offset_ms.fetch_sub(delta, Ordering::SeqCst);
        }
    }
}

impl Clock for MockClock {
    fn now_ms(&self) -> i64 {
        self.base.now_ms() + self.offset_ms.load(Ordering::SeqCst)
    }
}
```

**Multi-Node Simulation:**

```rust
/// Simulate two nodes with different clocks
#[tokio::test]
async fn test_multi_node_clock_skew() {
    let db_url = test_database_url();
    
    // Node A: 100ms behind
    let clock_a = Arc::new(MockClock::new());
    clock_a.set_skew(Duration::from_millis(100), false);
    let provider_a = PostgresProvider::new_with_clock(&db_url, clock_a.clone()).await.unwrap();
    
    // Node B: Real time
    let clock_b = Arc::new(MockClock::new());
    let provider_b = PostgresProvider::new_with_clock(&db_url, clock_b.clone()).await.unwrap();
    
    // Node A schedules a timer for "5 seconds from now" (A's now)
    // A's now is actually 4.9s in real time, so visible_at = real_now + 4.9s
    provider_a.enqueue_orchestrator_work(
        "test-instance",
        WorkItem::TimerFired { instance: "test".into(), fire_at_ms: clock_a.now_ms() as u64 + 5000 },
        None,
    ).await.unwrap();
    
    // Node B checks visibility using its clock (real time)
    // Timer should be visible at real_now + 4.9s, which is 100ms earlier than B expects
    // Grace period (100ms) should absorb this skew
    
    // Wait 5s (real time) + grace period
    tokio::time::sleep(Duration::from_millis(5100)).await;
    
    // Node B should find the work
    let result = provider_b.fetch_orchestration_item(
        Duration::from_secs(30),
        Duration::from_secs(1),
    ).await.unwrap();
    
    assert!(result.is_some(), "Timer should be visible despite 100ms clock skew");
}
```

### Test Utilities

```rust
/// Test helper to advance time in notifier
struct MockClock {
    current: AtomicI64,
}

impl MockClock {
    fn advance(&self, duration: Duration) {
        self.current.fetch_add(duration.as_millis() as i64, Ordering::Relaxed);
    }
    
    fn now_ms(&self) -> i64 {
        self.current.load(Ordering::Relaxed)
    }
}

/// Test helper to capture wake events
struct WakeRecorder {
    wakes: Mutex<Vec<(Instant, QueueType)>>,
}

impl WakeRecorder {
    fn record(&self, queue_type: QueueType) {
        self.wakes.lock().unwrap().push((Instant::now(), queue_type));
    }
    
    fn count(&self) -> usize {
        self.wakes.lock().unwrap().len()
    }
    
    fn last_wake(&self) -> Option<(Instant, QueueType)> {
        self.wakes.lock().unwrap().last().copied()
    }
}

/// Test helper to simulate slow queries
async fn with_query_delay<T>(delay: Duration, query: impl Future<Output = T>) -> T {
    tokio::time::sleep(delay).await;
    query.await
}
```

### Test Configuration

```rust
/// Fast config for testing (shorter intervals)
fn test_long_poll_config() -> LongPollConfig {
    LongPollConfig {
        enabled: true,
        notifier_poll_interval: Duration::from_secs(5),  // 5s instead of 60s
        timer_grace_period: Duration::from_millis(10),   // 10ms instead of 100ms
    }
}
```

### Test Execution Order

1. **Unit tests first** - Fast, no database required for most
2. **Integration tests** - Require PostgreSQL, use test schema
3. **Resilience tests** - May be flaky, run with retries
4. **Performance tests** - Run separately, require stable environment
5. **Stress tests** - Run in CI nightly, not on every commit

### Coverage Goals

| Component | Target Coverage |
|-----------|-----------------|
| Notifier NOTIFY handling | 100% |
| Timer heap operations | 100% |
| Refresh query logic | 90% |
| Dispatcher fetch paths | 100% |
| Error handling / reconnect | 80% |
| Edge cases (payload parsing) | 100% |
