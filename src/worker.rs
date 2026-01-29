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
use sqlx::PgPool;
use tracing_subscriber::EnvFilter;

use crate::registry::{create_activity_registry, create_orchestration_registry};
use crate::types::{postgres_connection_string, DUROXIDE_SCHEMA};

/// Initialize tracing subscriber for duroxide logs.
/// Must be called before Runtime::start_with_store() to capture all logs.
fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("warn,duroxide::orchestration=info,duroxide::activity=info")
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
            warning!("pg_durable: failed to create tokio runtime: {}", e);
            return;
        }
    };

    rt.block_on(async {
        // Create shared connection pool early (used for health checks and activities)
        let pg_conn_str = postgres_connection_string();
        let pg_pool = match create_shared_pool(&pg_conn_str).await {
            Some(pool) => Arc::new(pool),
            None => {
                warning!("pg_durable: failed to create connection pool, worker exiting");
                return;
            }
        };

        log!("pg_durable: shared connection pool created");

        let mut duroxide_runtime: Option<Arc<runtime::Runtime>> = None;

        loop {
            // 1. Check for shutdown signal
            let should_shutdown = tokio::task::spawn_blocking(is_shutdown_requested)
                .await
                .unwrap_or(false);

            if should_shutdown {
                log!("pg_durable: shutdown signal received");
                if let Some(runtime) = duroxide_runtime.take() {
                    log!("pg_durable: shutting down duroxide runtime...");
                    runtime.shutdown(Some(10_000)).await;
                    log!("pg_durable: duroxide runtime shutdown complete");
                }
                break;
            }

            // 2. If runtime is initialized, check if we should stop it
            if duroxide_runtime.is_some() && check_schema_or_tables_missing(&pg_pool).await {
                log!("pg_durable: duroxide schema or tables dropped, stopping runtime...");
                duroxide_runtime
                    .take()
                    .unwrap()
                    .shutdown(Some(10_000))
                    .await;
                log!("pg_durable: duroxide runtime stopped");
            }

            // 3. If runtime is not initialized, check if we should start it
            if duroxide_runtime.is_none() && check_schema_exists(&pg_pool).await {
                log!("pg_durable: duroxide schema detected, initializing runtime...");
                duroxide_runtime = initialize_duroxide_runtime(pg_pool.clone()).await;
                if duroxide_runtime.is_some() {
                    log!("pg_durable: duroxide runtime started, processing durable functions...");
                }
            }

            // 4. Sleep before next iteration
            tokio::time::sleep(Duration::from_millis(1000)).await;
        }

        pg_pool.close().await;
    });

    rt.shutdown_timeout(Duration::from_secs(5));
    log!("pg_durable: duroxide background worker terminated cleanly");
}

/// Create shared connection pool with special handling for test databases.
/// Returns None if database doesn't exist (except for regression databases which retry).
async fn create_shared_pool(pg_conn_str: &str) -> Option<PgPool> {
    use crate::types::get_database_name;

    let database_name = get_database_name();
    let is_regression_db = database_name == "regression" || database_name == "contrib_regression";

    loop {
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
            .connect(pg_conn_str)
            .await
        {
            Ok(pool) => return Some(pool),
            Err(e) => {
                // Check if this is a "database does not exist" error (SQLSTATE 3D000)
                let is_db_not_exists = e
                    .as_database_error()
                    .and_then(|db_err| db_err.code())
                    .map(|code| code == "3D000")
                    .unwrap_or(false);

                // Exit immediately only for non-regression databases that don't exist
                if !is_regression_db && is_db_not_exists {
                    warning!("pg_durable: database '{}' does not exist", database_name);
                    return None;
                }

                // For all other errors (regression DB doesn't exist, auth failures, etc.), retry
                warning!(
                    "pg_durable: failed to connect to database '{}': {}, retrying in 1s...",
                    database_name,
                    e
                );
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

/// Check if duroxide schema exists (used when waiting to initialize duroxide-pg)
/// Returns true if schema exists, false otherwise.
/// Only checks schema existence - tables will be created by PostgresProvider::new_with_schema().
async fn check_schema_exists(pool: &PgPool) -> bool {
    let result: Result<bool, _> =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname = 'duroxide')")
            .fetch_one(pool)
            .await;

    result.unwrap_or(false)
}

/// Check if duroxide schema or key tables are missing (used in runtime loop to detect drops)
/// Returns true if schema or tables are missing (indicating DROP EXTENSION CASCADE occurred).
/// This checks for both schema AND a key duroxide-pg table (executions) to handle the edge
/// case where DROP EXTENSION CASCADE + CREATE EXTENSION happens within the check interval.
async fn check_schema_or_tables_missing(pool: &PgPool) -> bool {
    // Check if both schema AND a key table exist (duroxide.executions)
    let exists: Result<bool, _> = sqlx::query_scalar(
        "SELECT EXISTS(
            SELECT 1 FROM pg_namespace n
            JOIN pg_class c ON c.relnamespace = n.oid
            WHERE n.nspname = 'duroxide' AND c.relname = 'executions'
        )",
    )
    .fetch_one(pool)
    .await;

    // Return true if missing (invert exists check)
    // Default to false on error to avoid spurious shutdowns
    !exists.unwrap_or(false)
}

/// Initialize the duroxide runtime and return it.
/// Returns None if initialization fails.
async fn initialize_duroxide_runtime(pg_pool: Arc<PgPool>) -> Option<Arc<runtime::Runtime>> {
    use crate::types::get_database_name;

    let pg_conn_str = postgres_connection_string();
    let database_name = get_database_name();

    log!(
        "pg_durable: connecting to PostgreSQL at {} (schema: {})",
        pg_conn_str,
        DUROXIDE_SCHEMA
    );

    // Create PostgreSQL store (fail fast if database doesn't exist)
    let store = match PostgresProvider::new_with_schema(&pg_conn_str, Some(DUROXIDE_SCHEMA)).await {
        Ok(s) => Arc::new(s),
        Err(e) => {
            warning!(
                "pg_durable: failed to create PostgreSQL store for database '{}': {}",
                database_name,
                e
            );
            warning!(
                "pg_durable: worker will not retry. Ensure database '{}' exists and extension is created.",
                database_name
            );
            return None;
        }
    };

    log!(
        "pg_durable: PostgreSQL store created in schema '{}'",
        DUROXIDE_SCHEMA
    );

    // Create registries using the shared pool
    let activities = create_activity_registry(pg_pool);
    let orchestrations = create_orchestration_registry();

    let duroxide_runtime =
        runtime::Runtime::start_with_store(store.clone(), activities, orchestrations).await;

    Some(duroxide_runtime)
}
