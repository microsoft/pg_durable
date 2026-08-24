// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! NOTIFY listener that wakes `df.wait_for_condition()` waiters early.
//!
//! One `PgListener` holds a single `LISTEN pg_durable_condition` for the
//! extension database, so the worker never issues `LISTEN`/`UNLISTEN` as
//! waiters come and go. Routing is done on the payload instead: the payload is
//! the `notify_key`, and `df.condition_waiters` maps it to the instances
//! parked on it.
//!
//! Waking is `Client::enqueue_event`, not `raise_event`. `dequeue_event` (what
//! the orchestration node subscribes with) consumes `WorkItem::QueueMessage`,
//! which only `enqueue_event` produces, and it is a mailbox — an event that
//! lands while the instance is not parked is buffered rather than dropped.
//! `raise_external_event` is doubly wrong here: it also fans out to child
//! instances, which is signal semantics.
//!
//! The listener runs inside the background worker, which connects over
//! host/port with sqlx. That matters: a background worker that issued `LISTEN`
//! through SPI would receive only a latch wake, with the payload logged rather
//! than delivered.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use duroxide::Client;
use pgrx::log;
use sqlx::postgres::PgListener;

use crate::types::condition_queue_name;

/// The single channel every condition producer notifies.
pub const CHANNEL: &str = "pg_durable_condition";

/// Minimum spacing between two wakes for the same `notify_key`.
///
/// An idle system gets its wake immediately; a producer notifying thousands of
/// times a second still causes at most one re-evaluation per key per second.
/// That costs no trigger latency, since `LOOP_MIN_ITER_DURATION` already stops
/// a loop from firing more than once a second.
const SUPPRESS_WINDOW: Duration = Duration::from_secs(1);

/// Whether a notification for `key` should wake its waiters, given the last
/// wake time per key. Records the decision in `seen`.
fn should_raise(key: &str, now: Instant, seen: &mut HashMap<String, Instant>) -> bool {
    // Drop entries that can no longer suppress anything, so an unbounded stream
    // of distinct keys does not grow the map forever.
    seen.retain(|_, last| now.duration_since(*last) < SUPPRESS_WINDOW);

    match seen.get(key) {
        Some(last) if now.duration_since(*last) < SUPPRESS_WINDOW => false,
        _ => {
            seen.insert(key.to_string(), now);
            true
        }
    }
}

async fn waiters_for_key(pool: &sqlx::PgPool, key: &str) -> Result<Vec<String>, sqlx::Error> {
    sqlx::query_scalar::<_, String>(
        "SELECT instance_id FROM df.condition_waiters WHERE notify_key = $1",
    )
    .bind(key)
    .fetch_all(pool)
    .await
}

async fn all_waiters(pool: &sqlx::PgPool) -> Result<Vec<(String, String)>, sqlx::Error> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT instance_id, notify_key FROM df.condition_waiters",
    )
    .fetch_all(pool)
    .await
}

async fn wake(client: &Client, instance: &str, key: &str) {
    if let Err(e) = client
        .enqueue_event(instance, condition_queue_name(key), "")
        .await
    {
        log!("pg_durable: waking condition waiter {instance} on '{key}' failed: {e}");
    }
}

/// Notifications sent while nothing was listening are gone, so on every
/// (re)connect wake every registered waiter once. That bounds catch-up to the
/// number of waiters instead of leaving each one to its interval backstop.
async fn resync(pool: &sqlx::PgPool, client: &Client) {
    match all_waiters(pool).await {
        Ok(waiters) => {
            for (instance, key) in &waiters {
                wake(client, instance, key).await;
            }
            if !waiters.is_empty() {
                log!(
                    "pg_durable: condition listener resynced {} waiter(s)",
                    waiters.len()
                );
            }
        }
        // The table is absent on a schema older than 0.2.6 (Scenario B1).
        // Waiters then fall back to their interval, which is the documented
        // backstop, so this is not fatal.
        Err(e) => log!("pg_durable: condition listener resync failed: {e}"),
    }
}

/// Listen for condition notifications until the task is aborted.
///
/// Reconnects on error rather than returning, so a terminated backend or a
/// restarted server does not permanently disable early wakeups.
pub async fn run(conn_str: String, pool: Arc<sqlx::PgPool>, client: Client) {
    /// Backoff between reconnect attempts.
    const RECONNECT_DELAY: Duration = Duration::from_secs(5);

    let mut seen: HashMap<String, Instant> = HashMap::new();

    loop {
        let mut listener = match PgListener::connect(&conn_str).await {
            Ok(l) => l,
            Err(e) => {
                log!("pg_durable: condition listener connect failed: {e}");
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };

        if let Err(e) = listener.listen(CHANNEL).await {
            log!("pg_durable: LISTEN {CHANNEL} failed: {e}");
            tokio::time::sleep(RECONNECT_DELAY).await;
            continue;
        }

        log!("pg_durable: condition listener attached to '{CHANNEL}'");
        seen.clear();
        resync(&pool, &client).await;

        loop {
            match listener.recv().await {
                Ok(notification) => {
                    let key = notification.payload();
                    if key.is_empty() || !should_raise(key, Instant::now(), &mut seen) {
                        continue;
                    }
                    match waiters_for_key(&pool, key).await {
                        Ok(instances) => {
                            for instance in &instances {
                                wake(&client, instance, key).await;
                            }
                        }
                        Err(e) => {
                            log!("pg_durable: looking up condition waiters for '{key}' failed: {e}")
                        }
                    }
                }
                Err(e) => {
                    log!("pg_durable: condition listener disconnected: {e}");
                    break;
                }
            }
        }

        tokio::time::sleep(RECONNECT_DELAY).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::time::{Duration, Instant};

    #[test]
    fn first_notification_for_a_key_raises() {
        let mut seen = HashMap::new();
        let now = Instant::now();
        assert!(should_raise("k", now, &mut seen));
    }

    #[test]
    fn repeat_within_window_is_suppressed() {
        let mut seen = HashMap::new();
        let now = Instant::now();
        assert!(should_raise("k", now, &mut seen));
        assert!(!should_raise(
            "k",
            now + Duration::from_millis(999),
            &mut seen
        ));
    }

    #[test]
    fn repeat_after_window_raises() {
        let mut seen = HashMap::new();
        let now = Instant::now();
        assert!(should_raise("k", now, &mut seen));
        assert!(should_raise(
            "k",
            now + Duration::from_millis(1_000),
            &mut seen
        ));
    }

    #[test]
    fn suppression_is_per_key() {
        let mut seen = HashMap::new();
        let now = Instant::now();
        assert!(should_raise("a", now, &mut seen));
        assert!(should_raise("b", now, &mut seen));
    }

    /// A busy producer must not grow the suppression map without bound.
    #[test]
    fn stale_keys_are_evicted() {
        let mut seen = HashMap::new();
        let start = Instant::now();
        for i in 0..10 {
            should_raise(&format!("k{i}"), start, &mut seen);
        }
        assert_eq!(seen.len(), 10);
        should_raise("fresh", start + Duration::from_secs(60), &mut seen);
        assert_eq!(seen.len(), 1, "expected stale keys to be evicted");
    }
}
