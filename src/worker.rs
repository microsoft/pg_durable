//! Background worker for pg_durable
//!
//! This module sets up and runs the Duroxide background worker that processes
//! durable functions.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use std::sync::Arc;
use std::time::Duration;

use duroxide::runtime;
use duroxide_pg_opt::PostgresProvider;
use sqlx::postgres::PgPoolOptions;
use tracing_subscriber::EnvFilter;

use crate::registry::{create_activity_registry, create_orchestration_registry};
use crate::types::{postgres_connection_string, worker_provider_config, DUROXIDE_SCHEMA};

/// Initialize tracing subscriber for duroxide logs.
/// Must be called before Runtime::start_with_store() to capture all logs.
fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("warn,duroxide::orchestration=info,duroxide::activity=info,sqlx_postgres::options::pgpass=error")
    });

    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_ansi(false) // Disable ANSI colors since logs go to file
        .try_init();
}

/// Initialize the background worker
pub fn register_background_worker() {
    BackgroundWorkerBuilder::new("pg_durable_worker")
        .set_function("duroxide_worker_main")
        .set_library("pg_durable")
        .set_argument(0i32.into_datum())
        .enable_shmem_access(None)
        .set_start_time(BgWorkerStartTime::RecoveryFinished)
        .set_restart_time(Some(Duration::from_secs(5)))
        .load();
}

/// Check if PostgreSQL has requested shutdown
fn is_shutdown_requested() -> bool {
    unsafe {
        std::ptr::read_volatile(std::ptr::addr_of!(pgrx::pg_sys::ShutdownRequestPending)) != 0
    }
}

/// Main duroxide background worker
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn duroxide_worker_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    // Initialize tracing before duroxide runtime to capture all logs including startup
    init_tracing();

    log!("pg_durable: duroxide background worker starting...");

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            log!("pg_durable: failed to create tokio runtime: {}", e);
            return;
        }
    };

    rt.block_on(async {
        run_duroxide_runtime().await;
    });

    rt.shutdown_timeout(Duration::from_secs(5));
    log!("pg_durable: duroxide background worker terminated cleanly");
}

/// Run the duroxide runtime with proper shutdown handling
async fn run_duroxide_runtime() {
    const WAIT_FOR_EXTENSION_POLL_INTERVAL: Duration = Duration::from_secs(5);
    const EXTENSION_DROP_POLL_INTERVAL: Duration = Duration::from_secs(5);
    const INIT_RETRY_INTERVAL: Duration = Duration::from_secs(5);
    const SHUTDOWN_CHECK_INTERVAL: Duration = Duration::from_secs(1);

    let pg_conn_str = postgres_connection_string();
    log!(
        "pg_durable: background worker connected to PostgreSQL at {} (schema: {})",
        pg_conn_str,
        DUROXIDE_SCHEMA
    );

    // Single-connection pool reused for all extension-existence polling, avoiding
    // the overhead of opening/closing a TCP connection on every check.
    let poll_pool = match sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&pg_conn_str)
        .await
    {
        Ok(pool) => pool,
        Err(e) => {
            log!(
                "pg_durable: failed to create polling pool (will retry via restart): {}",
                e
            );
            return;
        }
    };

    loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested, exiting");
            break;
        }

        if !wait_for_extension_creation(&poll_pool, WAIT_FOR_EXTENSION_POLL_INTERVAL).await {
            break;
        }

        let Some(duroxide_runtime) =
            initialize_duroxide_runtime(&pg_conn_str, INIT_RETRY_INTERVAL, &poll_pool).await
        else {
            // Shutdown requested or extension dropped while initializing.
            continue;
        };

        // Write a sentinel so we can detect drop+recreate even if the
        // extension is always present in pg_extension between polls.
        let epoch_id = match write_epoch_sentinel(&poll_pool).await {
            Ok(id) => {
                log!("pg_durable: epoch sentinel written ({})", id);
                Some(id)
            }
            Err(e) => {
                log!("pg_durable: failed to write epoch sentinel: {} — falling back to extension-exists polling", e);
                None
            }
        };

        run_until_extension_dropped_or_shutdown(
            &poll_pool,
            duroxide_runtime,
            EXTENSION_DROP_POLL_INTERVAL,
            SHUTDOWN_CHECK_INTERVAL,
            epoch_id.as_deref(),
        )
        .await;
    }

    poll_pool.close().await;
}

async fn wait_for_extension_creation(poll_pool: &sqlx::PgPool, poll_interval: Duration) -> bool {
    log!("pg_durable: waiting for CREATE EXTENSION pg_durable...");

    loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested while waiting for extension");
            return false;
        }

        if check_extension_exists(poll_pool).await {
            log!("pg_durable: extension detected, proceeding with initialization");
            return true;
        }

        tokio::time::sleep(poll_interval).await;
    }
}

async fn check_extension_exists(pool: &sqlx::PgPool) -> bool {
    let result: Result<(bool,), sqlx::Error> =
        sqlx::query_as("SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_durable')")
            .fetch_one(pool)
            .await;

    result.map(|(exists,)| exists).unwrap_or(false)
}

async fn initialize_duroxide_runtime(
    pg_conn_str: &str,
    retry_interval: Duration,
    poll_pool: &sqlx::PgPool,
) -> Option<Arc<runtime::Runtime>> {
    log!("pg_durable: initializing duroxide runtime...");

    loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested during initialization");
            return None;
        }

        if !check_extension_exists(poll_pool).await {
            log!("pg_durable: extension no longer exists; returning to wait state");
            return None;
        }

        let store =
            match PostgresProvider::new_with_config(pg_conn_str, worker_provider_config()).await {
                Ok(s) => Arc::new(s),
                Err(e) => {
                    log!(
                        "pg_durable: failed to create PostgreSQL store (will retry): {}",
                        e
                    );
                    tokio::time::sleep(retry_interval).await;
                    continue;
                }
            };

        let pg_pool = match PgPoolOptions::new()
            .max_connections(5)
            .after_connect(|conn, _meta| {
                Box::pin(async move {
                    sqlx::query("SET df.in_workflow = 'true'")
                        .execute(&mut *conn)
                        .await?;
                    Ok(())
                })
            })
            .connect(pg_conn_str)
            .await
        {
            Ok(pool) => Arc::new(pool),
            Err(e) => {
                log!(
                    "pg_durable: failed to create PostgreSQL pool (will retry): {}",
                    e
                );
                tokio::time::sleep(retry_interval).await;
                continue;
            }
        };

        let activities = create_activity_registry(pg_pool);
        let orchestrations = create_orchestration_registry();

        let duroxide_runtime =
            runtime::Runtime::start_with_store(store, activities, orchestrations).await;

        log!("pg_durable: duroxide runtime started");
        return Some(duroxide_runtime);
    }
}

/// Write the epoch sentinel after a successful runtime init.
/// Returns the generated epoch_id on success.
async fn write_epoch_sentinel(pool: &sqlx::PgPool) -> Result<String, sqlx::Error> {
    let epoch_id = uuid::Uuid::new_v4().to_string();
    sqlx::query("DELETE FROM df._worker_epoch")
        .execute(pool)
        .await?;
    sqlx::query("INSERT INTO df._worker_epoch (epoch_id) VALUES ($1::uuid)")
        .bind(&epoch_id)
        .execute(pool)
        .await?;
    Ok(epoch_id)
}

/// Check whether our epoch sentinel still exists.
///
/// Returns `true` when the sentinel row is intact (keep running),
/// `false` when it is missing or the query fails (extension dropped
/// or drop+recreated).
async fn check_epoch_sentinel(pool: &sqlx::PgPool, epoch_id: &str) -> bool {
    let result: Result<(bool,), sqlx::Error> =
        sqlx::query_as("SELECT EXISTS(SELECT 1 FROM df._worker_epoch WHERE epoch_id = $1::uuid)")
            .bind(epoch_id)
            .fetch_one(pool)
            .await;

    // Query error (table/schema gone) ⇒ treat as "dropped"
    result.map(|(exists,)| exists).unwrap_or(false)
}

async fn run_until_extension_dropped_or_shutdown(
    poll_pool: &sqlx::PgPool,
    duroxide_runtime: Arc<runtime::Runtime>,
    drop_poll_interval: Duration,
    shutdown_check_interval: Duration,
    epoch_id: Option<&str>,
) {
    log!("pg_durable: processing durable functions...");

    let mut drop_check = tokio::time::interval(drop_poll_interval);
    drop_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = tokio::time::sleep(shutdown_check_interval) => {
                // is_shutdown_requested reads a volatile atomic; no spawn_blocking needed.
                if is_shutdown_requested() {
                    log!("pg_durable: shutdown signal received");
                    break;
                }
            }
            _ = drop_check.tick() => {
                let still_valid = match epoch_id {
                    Some(eid) => check_epoch_sentinel(poll_pool, eid).await,
                    None => check_extension_exists(poll_pool).await,
                };
                if !still_valid {
                    log!("pg_durable: epoch sentinel gone — extension dropped or recreated");
                    break;
                }
            }
        }
    }

    log!("pg_durable: initiating duroxide runtime shutdown...");
    duroxide_runtime.shutdown(Some(10_000)).await;
    log!("pg_durable: duroxide runtime shutdown complete");
}
