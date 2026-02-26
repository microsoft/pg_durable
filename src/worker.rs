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
use crate::types::{postgres_connection_string, DUROXIDE_SCHEMA};

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
    log!("pg_durable: initializing duroxide runtime with PostgreSQL store...");

    let pg_conn_str = postgres_connection_string();
    log!(
        "pg_durable: connecting to PostgreSQL at {} (schema: {})",
        pg_conn_str,
        DUROXIDE_SCHEMA
    );

    // Retry connection with exponential backoff (useful for pg_regress tests where database may not exist yet)
    let store = loop {
        match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
            Ok(s) => break Arc::new(s),
            Err(e) => {
                log!(
                    "pg_durable: failed to create PostgreSQL store (will retry): {}",
                    e
                );

                // Check for shutdown before retrying
                if tokio::task::spawn_blocking(is_shutdown_requested)
                    .await
                    .unwrap_or(false)
                {
                    log!("pg_durable: shutdown requested during connection retry, exiting");
                    return;
                }

                // Retry after 5 seconds
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    };

    log!(
        "pg_durable: PostgreSQL store created in schema '{}'",
        DUROXIDE_SCHEMA
    );

    // Create connection pool with session variable marking workflow context
    let pg_pool = loop {
        match PgPoolOptions::new()
            .max_connections(5)
            .after_connect(|conn, _meta| {
                Box::pin(async move {
                    // Mark this connection as being used by the workflow runtime
                    sqlx::query("SET df.in_workflow = 'true'")
                        .execute(&mut *conn)
                        .await?;
                    Ok(())
                })
            })
            .connect(&pg_conn_str)
            .await
        {
            Ok(pool) => {
                log!("pg_durable: PostgreSQL connection pool created");
                break Arc::new(pool);
            }
            Err(e) => {
                log!(
                    "pg_durable: failed to create PostgreSQL pool (will retry): {}",
                    e
                );

                // Check for shutdown before retrying
                if tokio::task::spawn_blocking(is_shutdown_requested)
                    .await
                    .unwrap_or(false)
                {
                    log!("pg_durable: shutdown requested during pool creation, exiting");
                    return;
                }

                // Retry after 5 seconds
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    };

    // Create registries
    let activities = create_activity_registry(pg_pool);
    let orchestrations = create_orchestration_registry();

    let duroxide_runtime =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;

    log!("pg_durable: duroxide runtime started, processing durable functions...");

    // Keep runtime alive until shutdown signal
    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;

        let should_shutdown = tokio::task::spawn_blocking(is_shutdown_requested)
            .await
            .unwrap_or(false);

        if should_shutdown {
            log!("pg_durable: shutdown signal received, stopping duroxide runtime...");
            break;
        }
    }

    log!("pg_durable: initiating duroxide runtime shutdown...");
    duroxide_runtime.shutdown(Some(10_000)).await;
    log!("pg_durable: duroxide runtime shutdown complete");
}
