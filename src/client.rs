// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Cached client infrastructure for user session calls
//!
//! This module provides cached Tokio runtime and Duroxide client for efficient
//! df.start(), df.signal(), and df.cancel() calls from user sessions.
//!
//! The client is lazily initialized on first use and can automatically
//! recover from connection failures by re-creating the pool on next call.

use std::cell::RefCell;
use std::sync::OnceLock;

use duroxide::Client;
use pgrx::prelude::*;
use tokio::runtime::Runtime;

use crate::types::{
    backend_duroxide_schema, connect_as_user_for_new_transaction, new_backend_provider,
    postgres_connection_string,
};

/// Cached tokio runtime for client operations.
static CLIENT_RUNTIME: OnceLock<Runtime> = OnceLock::new();

// Per-backend cached Duroxide client. Uses thread_local + RefCell because
// PostgreSQL backends are single-threaded forked processes. This allows
// the client to be reset on connection failures (unlike OnceLock which
// is permanent).
thread_local! {
    static DUROXIDE_CLIENT: RefCell<Option<Client>> = const { RefCell::new(None) };
}

/// Check whether the background worker has finished initializing the duroxide
/// schema for the current binary's expected schema version.
///
/// Returns `false` if `<provider_schema>._worker_ready` does not exist, has no
/// row, or has a `schema_version` below `WORKER_SCHEMA_VERSION`. This is a fast
/// SPI read called once per session on the first call to any `df.*` function
/// that needs the duroxide client.
fn is_worker_ready() -> bool {
    let schema = backend_duroxide_schema();

    // First check if the readiness table exists via the catalogue.  Querying
    // the non-existent table directly would raise a PostgreSQL ERROR that
    // aborts the current (sub)transaction — even if caught in Rust.
    let table_exists = Spi::get_one_with_args::<bool>(
        "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_tables \
         WHERE schemaname = $1 AND tablename = '_worker_ready')",
        &[schema.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false);

    if !table_exists {
        return false;
    }

    Spi::get_one_with_args::<bool>(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM {}._worker_ready WHERE schema_version >= $1)",
            schema
        ),
        &[crate::WORKER_SCHEMA_VERSION.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false)
}

/// Get or create the cached tokio runtime.
fn get_client_runtime() -> &'static Runtime {
    CLIENT_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// Initialize or get the cached Duroxide client, executing `f` with it.
/// If the client doesn't exist yet, creates it. If `f` returns an error
/// that looks like a connection failure, resets the client so the next
/// call will re-initialize.
fn with_duroxide_client<T, F>(f: F) -> Result<T, String>
where
    F: FnOnce(&Client, &Runtime) -> Result<T, String>,
{
    let rt = get_client_runtime();

    // Try to use existing client
    let has_client = DUROXIDE_CLIENT.with(|cell| cell.borrow().is_some());

    if !has_client {
        // Need to create a new client
        if !is_worker_ready() {
            return Err(
                "pg_durable background worker not yet initialized — try again in a moment"
                    .to_string(),
            );
        }

        let pg_conn_str = postgres_connection_string();
        let schema = backend_duroxide_schema();
        let client = rt.block_on(async {
            // Limit backend provider to 1 connection — backends need minimal
            // duroxide access (start/cancel/signal only).
            //
            // SAFETY: Each PostgreSQL backend is a separate process (fork model).
            // This code runs in a single-threaded tokio runtime with no worker
            // threads. No concurrent thread can be reading env simultaneously.
            unsafe {
                std::env::set_var("DUROXIDE_PG_POOL_MAX", "1");
            }

            let store = new_backend_provider(&pg_conn_str, schema).await?;
            Ok::<Client, String>(Client::new(store))
        })?;

        DUROXIDE_CLIENT.with(|cell| {
            *cell.borrow_mut() = Some(client);
        });
    }

    // Execute the operation with the client
    let result = DUROXIDE_CLIENT.with(|cell| {
        let borrow = cell.borrow();
        let client = borrow
            .as_ref()
            .ok_or_else(|| "Client unexpectedly missing".to_string())?;
        f(client, rt)
    });

    // On connection-level errors, reset the client so next call retries
    if let Err(ref e) = result {
        if is_connection_error(e) {
            DUROXIDE_CLIENT.with(|cell| {
                *cell.borrow_mut() = None;
            });
        }
    }

    result
}

/// Heuristic to detect connection-level errors that warrant client reset.
fn is_connection_error(err: &str) -> bool {
    let lower = err.to_lowercase();
    lower.contains("connection")
        || lower.contains("pool timed out")
        || lower.contains("broken pipe")
        || lower.contains("reset by peer")
        || lower.contains("closed")
}

/// Test-accessible wrapper for is_connection_error.
#[cfg(any(test, feature = "pg_test"))]
pub(crate) fn is_connection_error_for_test(err: &str) -> bool {
    is_connection_error(err)
}

async fn list_running_descendants(client: &Client, root_instance_id: &str) -> Vec<String> {
    let tree = match client.get_instance_tree(root_instance_id).await {
        Ok(tree) => tree,
        Err(e) => {
            warning!(
                "pg_durable: failed to inspect instance tree for signal fan-out (root={}): {:?}",
                root_instance_id,
                e
            );
            return vec![];
        }
    };

    let mut descendants = Vec::new();
    for child_instance_id in tree.all_ids {
        if child_instance_id == root_instance_id {
            continue;
        }

        match client.get_instance_info(&child_instance_id).await {
            Ok(info) if info.status.eq_ignore_ascii_case("running") => {
                descendants.push(child_instance_id);
            }
            Ok(_) => {}
            Err(e) => {
                warning!(
                    "pg_durable: failed to inspect child instance status for signal fan-out (child={}): {:?}",
                    child_instance_id, e
                );
            }
        }
    }

    descendants
}

/// Start a durable function via the shared PostgreSQL store.
pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    log!(
        "pg_durable: start_durable_function for instance {}",
        instance_id
    );

    let fn_name = function_name.to_string();
    let inst_id = instance_id.to_string();
    let inp = input.to_string();

    with_duroxide_client(|client, rt| {
        rt.block_on(async {
            client
                .start_orchestration(&inst_id, &fn_name, &inp)
                .await
                .map_err(|e| format!("Failed to start durable function: {e:?}"))?;
            Ok(())
        })
    })
}

/// Upper bound (milliseconds) on the `transaction_mode => 'new'` `df.start()`
/// statement.
///
/// The caller's transaction is still open while we wait, and it may hold locks
/// the separate session needs (an explicit `LOCK TABLE` on a `df` table, a
/// concurrent DDL, ...). PostgreSQL cannot break that cycle: the separate
/// session waits on a lock, but the caller waits on a socket, which the
/// deadlock detector does not see. Without a bound the caller would hang
/// forever, so cap the statement and surface a plain error instead.
const NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS: u64 = 30_000;

fn format_new_transaction_start_error(sqlstate: Option<&str>, message: &str) -> String {
    let lower = message.to_lowercase();

    match sqlstate {
        Some("55P03") if lower.contains("lock timeout") => format!(
            "pg_durable: transaction_mode => 'new' launch hit lock_timeout after \
             {NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS}ms while waiting on a lock in the \
             loopback session: {message}"
        ),
        Some("57014") if lower.contains("statement timeout") => format!(
            "pg_durable: transaction_mode => 'new' launch hit statement_timeout after \
             {NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS}ms while running df.start() in the \
             loopback session: {message}"
        ),
        _ => format!("df.start() on new transaction failed: {message}"),
    }
}

fn classify_new_transaction_start_error(err: sqlx::Error) -> String {
    let message = err.to_string();
    let sqlstate = err
        .as_database_error()
        .and_then(|db_err| db_err.code().map(|code| code.to_string()));
    format_new_transaction_start_error(sqlstate.as_deref(), &message)
}

/// Run `df.start()` on an already-established separate session.
async fn start_on_new_session(
    conn: &mut sqlx::postgres::PgConnection,
    fut: &str,
    label: &Option<String>,
    database: &Option<String>,
    retry: Option<crate::types::RetryPolicySpec>,
) -> Result<String, String> {
    use sqlx::Row;

    // `connect_as_user` marks its connections as workflow-execution sessions
    // (`df.in_workflow='true'`) because it is normally called from the
    // background worker. This is user-initiated work, not workflow execution,
    // so clear the flag: this session must behave exactly as if the caller had
    // run `df.start()` directly, including under the in-workflow guards.
    sqlx::query("SET df.in_workflow = 'false'")
        .execute(&mut *conn)
        .await
        .map_err(|e| format!("failed to clear df.in_workflow on new-transaction session: {e}"))?;

    // Bound both the lock wait and the statement itself. See
    // NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS for why this is not optional. Two
    // statements because sqlx prepares every query, and the extended protocol
    // rejects multi-statement strings.
    for stmt in [
        format!("SET lock_timeout = {NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS}"),
        format!("SET statement_timeout = {NEW_TRANSACTION_START_STATEMENT_TIMEOUT_MS}"),
    ] {
        sqlx::query(&stmt)
            .execute(&mut *conn)
            .await
            .map_err(|e| format!("failed to set timeouts on new-transaction session: {e}"))?;
    }

    // Three positional arguments on purpose: this must also resolve on schemas
    // predating `transaction_mode`, where `df.start` takes exactly three. On
    // current schemas it resolves to the newest `df.start` and defaults
    // to 'caller', which is what we want — the separate session is already the
    // new transaction, so it must not recurse.
    //
    // `retry` is `Some` only when the caller reached df.start() through a schema that
    // declares the failure-policy arguments, so forwarding them cannot break resolution on
    // an older schema (which would have entered through the four-argument symbol and passed
    // `None`). The interval is bound as a microsecond string rather than an interval type so
    // no extra sqlx type mapping is needed.
    let row = match retry {
        Some(spec) => {
            sqlx::query("SELECT df.start($1, $2, $3, 'caller', $4, $5::interval, $6) AS id")
                .bind(fut)
                .bind(label)
                .bind(database)
                .bind(spec.max_attempts as i32)
                .bind(format!("{} microseconds", spec.max_backoff_micros))
                .bind(match spec.on_failure {
                    crate::types::OnFailure::Continue => "continue",
                    crate::types::OnFailure::Fail => "fail",
                })
                .fetch_one(&mut *conn)
                .await
        }
        None => {
            sqlx::query("SELECT df.start($1, $2, $3) AS id")
                .bind(fut)
                .bind(label)
                .bind(database)
                .fetch_one(&mut *conn)
                .await
        }
    }
    .map_err(classify_new_transaction_start_error)?;

    row.try_get("id")
        .map_err(|e| format!("df.start() on new transaction returned no instance id: {e}"))
}

/// Start a durable function **in its own transaction**.
///
/// The graph is persisted and enqueued on a *separate* PostgreSQL session, so
/// it commits independently and **survives a rollback of the caller's
/// transaction**. This provides the rollback-survival outcome of an Oracle
/// autonomous transaction for asynchronously started work; unlike an Oracle
/// autonomous routine, the workflow does not complete synchronously and its
/// execution errors do not propagate through this call.
///
/// Mechanism: open a fresh loopback connection authenticated as `user` and run
/// the ordinary `df.start(...)` there. Because sqlx runs each statement in
/// autocommit mode, that inner `df.start` commits in its own transaction the
/// moment it returns — regardless of what the outer caller later does. This is
/// the same "separate backend" technique `pg_background` uses, but it reuses
/// pg_durable's existing graph construction and duroxide enqueue path
/// unchanged.
///
/// Returns the new instance id.
pub fn start_in_new_transaction(
    fut: &str,
    label: Option<&str>,
    database: Option<&str>,
    user: &str,
    retry: Option<crate::types::RetryPolicySpec>,
) -> Result<String, String> {
    use sqlx::Connection;

    let rt = get_client_runtime();

    let fut = fut.to_string();
    let label = label.map(|s| s.to_string());
    let database = database.map(|s| s.to_string());
    let user = user.to_string();

    rt.block_on(async {
        // The extension lives in exactly one database (see docs/multi-database.md),
        // so `database=None` resolves to that control database — the same one
        // holding the `df` tables this backend writes through SPI. The `database`
        // argument is forwarded to the inner `df.start()`, which records it as an
        // instance property for the worker to execute against.
        let mut conn = connect_as_user_for_new_transaction(&user).await?;

        let result = start_on_new_session(&mut conn, &fut, &label, &database, retry).await;

        // Close explicitly so the extra backend exits promptly rather than
        // lingering until the server notices a dropped socket.
        if let Err(e) = conn.close().await {
            log!("pg_durable: closing new-transaction start session failed: {e}");
        }

        if let Err(ref e) = result {
            // The inner df.start() runs in autocommit, so a failure before it
            // returned rolled itself back — nothing to clean up. A failure
            // *after* it committed (decoding the returned id) would leave a
            // running instance whose id the caller never learns, so log loudly.
            log!("pg_durable: start in new transaction failed: {e}");
        }

        result
    })
}

/// Cancel a durable function.
pub fn cancel_durable_function(instance_id: &str, reason: &str) -> Result<(), String> {
    let inst_id = instance_id.to_string();
    let rsn = reason.to_string();

    with_duroxide_client(|client, rt| {
        rt.block_on(async {
            client
                .cancel_instance(&inst_id, &rsn)
                .await
                .map_err(|e| format!("Failed to cancel durable function: {e:?}"))?;
            Ok(())
        })
    })
}

/// Raise an external event (signal) to a running orchestration.
pub fn raise_external_event(instance_id: &str, event_name: &str, data: &str) -> Result<(), String> {
    let inst_id = instance_id.to_string();
    let evt_name = event_name.to_string();
    let evt_data = data.to_string();

    with_duroxide_client(|client, rt| {
        rt.block_on(async {
            client
                .raise_event(&inst_id, &evt_name, &evt_data)
                .await
                .map_err(|e| format!("Failed to raise event: {e:?}"))?;

            for child_instance_id in list_running_descendants(client, &inst_id).await {
                if let Err(e) = client
                    .raise_event(&child_instance_id, &evt_name, &evt_data)
                    .await
                {
                    warning!(
                        "pg_durable: failed to fan out signal '{}' to child instance {}: {:?}",
                        evt_name,
                        child_instance_id,
                        e
                    );
                }
            }

            Ok(())
        })
    })
}

#[cfg(test)]
mod tests {
    use super::{format_new_transaction_start_error, is_connection_error};

    #[test]
    fn detects_connection_refused() {
        assert!(is_connection_error(
            "Failed to start durable function: connection refused"
        ));
    }

    #[test]
    fn detects_broken_pipe() {
        assert!(is_connection_error("IO error: broken pipe"));
    }

    #[test]
    fn detects_pool_timeout() {
        assert!(is_connection_error(
            "pool timed out while waiting for an open connection"
        ));
    }

    #[test]
    fn detects_connection_reset() {
        assert!(is_connection_error("reset by peer"));
    }

    #[test]
    fn detects_connection_closed() {
        assert!(is_connection_error("connection closed unexpectedly"));
    }

    #[test]
    fn does_not_match_normal_errors() {
        assert!(!is_connection_error("Instance not found"));
        assert!(!is_connection_error("permission denied for table foo"));
        assert!(!is_connection_error("syntax error at position 42"));
        assert!(!is_connection_error(
            "Orchestration already exists for instance abc123"
        ));
    }

    #[test]
    fn classifies_new_transaction_lock_timeout() {
        let formatted = format_new_transaction_start_error(
            Some("55P03"),
            "canceling statement due to lock timeout",
        );

        assert!(formatted.contains("lock_timeout"));
        assert!(formatted.contains("30000ms"));
    }

    #[test]
    fn classifies_new_transaction_statement_timeout() {
        let formatted = format_new_transaction_start_error(
            Some("57014"),
            "canceling statement due to statement timeout",
        );

        assert!(formatted.contains("statement_timeout"));
        assert!(formatted.contains("30000ms"));
    }

    #[test]
    fn preserves_other_new_transaction_errors() {
        let formatted = format_new_transaction_start_error(Some("42501"), "permission denied");

        assert_eq!(
            formatted,
            "df.start() on new transaction failed: permission denied"
        );
    }
}
