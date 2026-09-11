// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Background worker for pg_durable
//!
//! This module sets up and runs the Duroxide background worker that processes
//! durable functions.

use pgrx::bgworkers::*;
use pgrx::prelude::*;
use sqlx::Connection;
use std::collections::{BTreeMap, HashSet};
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use duroxide::runtime;
use duroxide::{Client, ClientError, InstanceFilter};
use duroxide_pg::PostgresProvider;
use tracing_subscriber::EnvFilter;

use crate::origin::{Origin, Router};
use crate::registry::{create_activity_registry, create_orchestration_registry};
use crate::types::{
    get_max_duroxide_connections, get_max_management_connections, get_max_user_connections,
    get_reconcile_interval, get_retention_days, postgres_connection_string,
    postgres_connection_string_with_application_name, resolve_duroxide_schema_pool,
    worker_provider_config, WORKER_MANAGEMENT_APPLICATION_NAME, WORKER_POLL_APPLICATION_NAME,
};

// Retention policy for terminal ('completed'/'failed'/'cancelled') instances.
// A terminal instance is removed when it is OUTSIDE the newest
// TERMINAL_INSTANCE_MAX_KEEP rows (a hard cap enforced regardless of age) OR
// older than pg_durable.retention_days. Equivalently, an instance is retained
// only while it is BOTH among the newest TERMINAL_INSTANCE_MAX_KEEP terminal rows
// AND younger than the retention window. The number of retained terminal
// instances therefore never exceeds TERMINAL_INSTANCE_MAX_KEEP.
const TERMINAL_INSTANCE_MAX_KEEP: i64 = 10_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExpiredDeletion {
    pub instances_deleted: i64,
    pub nodes_deleted: i64,
    /// Ids of the df.instances rows this deletion removed.
    pub deleted_ids: Vec<String>,
}

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

/// Returns a future that resolves once PostgreSQL signals a shutdown.
///
/// Polls `is_shutdown_requested()` at 100 ms intervals; suitable for use in
/// `tokio::select!` branches where we want to break out of a sleep early when
/// a shutdown arrives.
async fn wait_for_shutdown() {
    loop {
        if is_shutdown_requested() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
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

    // All async cleanup (pool closes, runtime shutdown) is performed inside
    // run_duroxide_runtime() above before it returns.  Use shutdown_background()
    // so we do not block waiting for any remaining Tokio blocking-pool threads
    // that were spawned by SQLx during initialization (e.g. pgpass file reads).
    // The BGW process is about to exit via proc_exit() anyway, so those threads
    // will be terminated by the OS regardless.
    rt.shutdown_background();
    log!("pg_durable: duroxide background worker terminated cleanly");
}

/// Run the duroxide runtime with proper shutdown handling
async fn run_duroxide_runtime() {
    const WAIT_FOR_EXTENSION_POLL_INTERVAL: Duration = Duration::from_secs(5);
    const EXTENSION_DROP_POLL_INTERVAL: Duration = Duration::from_secs(5);
    const INIT_RETRY_INTERVAL: Duration = Duration::from_secs(1);
    const SHUTDOWN_CHECK_INTERVAL: Duration = Duration::from_secs(1);
    // Paced so that a persistently mismatching epoch cannot spin on full runtime
    // initialization (migrations, provider construction, dispatcher startup).
    const STALE_RUNTIME_RETRY_INTERVAL: Duration = Duration::from_secs(1);

    let pg_conn_str = postgres_connection_string();
    let management_conn_str =
        postgres_connection_string_with_application_name(WORKER_MANAGEMENT_APPLICATION_NAME);
    let poll_conn_str =
        postgres_connection_string_with_application_name(WORKER_POLL_APPLICATION_NAME);
    log!(
        "pg_durable: background worker connected to PostgreSQL at {}",
        pg_conn_str,
    );

    // Validate connection limit GUCs at startup
    let mgmt_conns = get_max_management_connections();
    let duroxide_conns = get_max_duroxide_connections();
    let user_conns = get_max_user_connections();

    if duroxide_conns < 2 {
        log!(
            "pg_durable: max_duroxide_connections={} is below minimum 2 \
             (listener requires at least 1 slot). Worker refusing to start.",
            duroxide_conns
        );
        return;
    }

    if mgmt_conns == 1 {
        log!(
            "pg_durable: WARNING — max_management_connections=1 leaves no headroom; \
             consider increasing to at least 2"
        );
    }

    log!(
        "pg_durable: connection budget — management={}, duroxide={}, user={}",
        mgmt_conns,
        duroxide_conns,
        user_conns
    );

    // Management pool: consolidates former polling and activity pools into one.
    // Used for graph loading and status updates. Sized by the max_management_connections GUC.
    // Retry in a loop so the worker survives the target database not yet existing
    // (e.g. pg_regress creates `contrib_regression` after PostgreSQL starts).
    //
    // The connect() call uses acquire_timeout so a slow or shutting-down
    // PostgreSQL does not block indefinitely on the first attempt.
    let mgmt_pool = loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested before management pool created, exiting");
            return;
        }
        match sqlx::postgres::PgPoolOptions::new()
            .max_connections(mgmt_conns)
            .acquire_timeout(Duration::from_secs(5))
            .connect(&management_conn_str)
            .await
        {
            Ok(pool) => break pool,
            Err(e) => {
                log!(
                    "pg_durable: failed to create management pool (will retry in 5s): {}",
                    e
                );
                // Sleep interruptibly so shutdown does not wait a full 5s.
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                    _ = wait_for_shutdown() => {
                        log!("pg_durable: shutdown requested during management pool retry, exiting");
                        return;
                    }
                }
            }
        }
    };

    // Dedicated polling pool: a separate 1-connection pool used exclusively for
    // extension-existence checks and epoch sentinel heartbeats. This isolation
    // prevents activity work (graph loading, status updates) from starving the
    // health-check loop and causing spurious runtime shutdowns under high load.
    let poll_pool = loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested before poll pool created, exiting");
            return;
        }
        match sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .acquire_timeout(Duration::from_secs(5))
            .connect(&poll_conn_str)
            .await
        {
            Ok(pool) => break pool,
            Err(e) => {
                log!(
                    "pg_durable: failed to create poll pool (will retry in 5s): {}",
                    e
                );
                // Sleep interruptibly so shutdown does not wait a full 5s.
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                    _ = wait_for_shutdown() => {
                        log!("pg_durable: shutdown requested during poll pool retry, exiting");
                        return;
                    }
                }
            }
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

        // Capture the extension epoch identity BEFORE anything else reads the
        // extension's objects. Everything below — schema resolution, migration,
        // runtime construction, readiness publication — must describe this one
        // epoch, so a DROP/CREATE at any point after this line has to be caught
        // rather than silently certified.
        let epoch_oid = match capture_extension_epoch(&poll_pool).await {
            Ok(Some(oid)) => oid,
            Ok(None) => {
                // Dropped between the existence poll and here; go back to waiting.
                continue;
            }
            Err(e) => {
                log!(
                    "pg_durable: failed to read extension epoch (will retry): {}",
                    e
                );
                if !sleep_or_shutdown(INIT_RETRY_INTERVAL).await {
                    break;
                }
                continue;
            }
        };

        // Resolve the duroxide provider schema for this epoch. The extension may
        // have been dropped and recreated with a different schema version (e.g.
        // a fresh `_duroxide` install vs. a legacy `duroxide` install), so we
        // must re-resolve after every CREATE EXTENSION rather than once at startup.
        let duroxide_schema = resolve_duroxide_schema_pool(&mgmt_pool).await;
        log!(
            "pg_durable: using duroxide provider schema '{}' for this epoch",
            duroxide_schema
        );

        let Some((duroxide_runtime, duroxide_store)) = initialize_duroxide_runtime(
            &pg_conn_str,
            INIT_RETRY_INTERVAL,
            &mgmt_pool,
            &duroxide_schema,
        )
        .await
        else {
            // Shutdown requested or extension dropped while initializing.
            continue;
        };

        // Test-only pause that widens the window between runtime initialization
        // and readiness publication so a regression test can drop/recreate the
        // extension deterministically. Compiled out unless `test-hooks` is on.
        test_pause_before_ready().await;

        // Revalidate the epoch AFTER initialization and BEFORE publishing
        // readiness. If the extension was dropped/recreated during init, tear down
        // this now-stale runtime and retry against the current epoch, so a runtime
        // bound to provider objects that no longer exist is never certified.
        if extension_epoch_replaced(&poll_pool, epoch_oid).await {
            log!(
                "pg_durable: extension replaced during initialization — \
                 tearing down stale runtime and retrying"
            );
            teardown_runtime(duroxide_runtime, duroxide_store).await;
            if !sleep_or_shutdown(STALE_RUNTIME_RETRY_INTERVAL).await {
                break;
            }
            continue;
        }

        // Write the worker readiness record so backend sessions know the
        // duroxide schema is fully initialized for this schema version.
        // Skipped if the row already has the current WORKER_SCHEMA_VERSION.
        if let Err(e) = write_worker_ready(&mgmt_pool, &duroxide_schema, epoch_oid).await {
            log!("pg_durable: failed to write worker readiness record: {}", e);
            teardown_runtime(duroxide_runtime, duroxide_store).await;
            if !sleep_or_shutdown(STALE_RUNTIME_RETRY_INTERVAL).await {
                break;
            }
            continue;
        }

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

        // Final epoch check after readiness/sentinel writes and before entering the
        // processing loop. A drop/recreate in this narrow window would have written
        // the readiness record and sentinel into the new epoch's `df` schema, so the
        // processing loop's sentinel check could not detect the replacement. Catch it
        // here: tear down and retry against the current epoch.
        if extension_epoch_replaced(&poll_pool, epoch_oid).await {
            log!(
                "pg_durable: extension replaced after readiness publication — \
                 tearing down stale runtime and retrying"
            );
            teardown_runtime(duroxide_runtime, duroxide_store).await;
            if !sleep_or_shutdown(STALE_RUNTIME_RETRY_INTERVAL).await {
                break;
            }
            continue;
        }

        run_until_extension_dropped_or_shutdown(
            &poll_pool,
            &mgmt_pool,
            duroxide_runtime,
            duroxide_store,
            EXTENSION_DROP_POLL_INTERVAL,
            SHUTDOWN_CHECK_INTERVAL,
            epoch_id.as_deref(),
        )
        .await;
    }

    // Mark the shared pools closed and briefly poll their close futures so
    // maintenance tasks and pending acquisitions observe shutdown. In-flight
    // queries may not return connections while PostgreSQL is terminating its
    // backends, so the BGW process exit performs the final cleanup.
    const POOL_CLOSE_GRACE: Duration = Duration::from_millis(100);
    let _ = tokio::join!(
        tokio::time::timeout(POOL_CLOSE_GRACE, mgmt_pool.close()),
        tokio::time::timeout(POOL_CLOSE_GRACE, poll_pool.close()),
    );
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

        // Sleep interruptibly so shutdown does not wait the full poll_interval.
        tokio::select! {
            _ = tokio::time::sleep(poll_interval) => {}
            _ = wait_for_shutdown() => {
                log!("pg_durable: shutdown requested while waiting for extension");
                return false;
            }
        }
    }
}

async fn check_extension_exists(pool: &sqlx::PgPool) -> bool {
    let result: Result<(bool,), sqlx::Error> =
        sqlx::query_as("SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_durable')")
            .fetch_one(pool)
            .await;

    result.map(|(exists,)| exists).unwrap_or(false)
}

/// Identifies a single extension install ("epoch"). `pg_extension.oid` is a fresh
/// value for every CREATE EXTENSION, so it changes across a DROP/CREATE cycle even
/// when the extension appears continuously present between polls.
///
/// `Ok(None)` means the extension is absent; `Err` means the epoch is unknown.
/// Callers must keep those cases distinct — see `extension_epoch_replaced`.
async fn capture_extension_epoch(pool: &sqlx::PgPool) -> Result<Option<i64>, sqlx::Error> {
    let row: Option<(i64,)> =
        sqlx::query_as("SELECT oid::bigint FROM pg_extension WHERE extname = 'pg_durable'")
            .fetch_optional(pool)
            .await?;

    Ok(row.map(|(oid,)| oid))
}

/// True only when the extension is *known* to have been replaced since `captured`.
///
/// A failed read reports "not replaced": the poll pool holds a single connection,
/// and treating a transient error as a replacement would discard a healthy runtime
/// and repeat the whole initialization. The epoch sentinel poll in the processing
/// loop already detects a genuine replacement, at far lower cost.
async fn extension_epoch_replaced(pool: &sqlx::PgPool, captured: i64) -> bool {
    match capture_extension_epoch(pool).await {
        Ok(Some(current)) if current == captured => false,
        Ok(current) => {
            log!(
                "pg_durable: extension epoch changed (captured={}, current={:?})",
                captured,
                current
            );
            true
        }
        Err(e) => {
            log!(
                "pg_durable: could not read extension epoch ({}) — assuming unchanged",
                e
            );
            false
        }
    }
}

/// Interruptible sleep. Returns false when shutdown was requested during the wait.
async fn sleep_or_shutdown(duration: Duration) -> bool {
    tokio::select! {
        _ = tokio::time::sleep(duration) => true,
        _ = wait_for_shutdown() => false,
    }
}

/// Test-only hook: when the `PG_DURABLE_TEST_PAUSE_BEFORE_READY_MS` environment
/// variable is set to a positive integer, sleep that many milliseconds between
/// runtime initialization and readiness publication. This creates a deterministic
/// window for `scripts/test-epoch-race.sh` to DROP/CREATE the extension
/// mid-initialization and exercise the stale-runtime detection path.
///
/// Gated behind the `test-hooks` feature so a shipped build cannot be stalled by
/// its process environment.
#[cfg(feature = "test-hooks")]
async fn test_pause_before_ready() {
    if let Ok(val) = std::env::var("PG_DURABLE_TEST_PAUSE_BEFORE_READY_MS") {
        if let Ok(ms) = val.parse::<u64>() {
            if ms > 0 {
                log!(
                    "pg_durable: TEST hook — pausing {}ms before readiness publication",
                    ms
                );
                tokio::time::sleep(Duration::from_millis(ms)).await;
            }
        }
    }
}

#[cfg(not(feature = "test-hooks"))]
async fn test_pause_before_ready() {}

/// Returns true if the `duroxide` schema exists AND is owned by the `pg_durable`
/// extension (dependency type 'e' in pg_depend).
///
/// This prevents the BGW from running ApplyAll into an attacker-crafted schema
/// that happens to be named "duroxide" but was not created by CREATE EXTENSION.
async fn check_duroxide_schema_owned(pool: &sqlx::PgPool, schema_name: &str) -> bool {
    let result: Result<(bool,), sqlx::Error> = sqlx::query_as(
        "SELECT EXISTS (
            SELECT 1
            FROM pg_namespace n
            JOIN pg_depend d
                ON d.objid = n.oid
                AND d.classid = 'pg_namespace'::regclass
                AND d.deptype = 'e'
            JOIN pg_extension e
                ON e.oid = d.refobjid
                AND e.extname = 'pg_durable'
            WHERE n.nspname = $1
        )",
    )
    .bind(schema_name)
    .fetch_one(pool)
    .await;

    result.map(|(owned,)| owned).unwrap_or(false)
}

/// Release all objects inside the `duroxide` schema that are still owned by the
/// `pg_durable` extension, so that migration scripts (which use DROP/CREATE FUNCTION)
/// can run without hitting "cannot drop … because extension pg_durable requires it".
///
/// This is a no-op on fresh installs (nothing is extension-owned inside duroxide beyond
/// the schema namespace itself). On upgrades from v0.1.1 — where CREATE EXTENSION
/// embedded the full duroxide DDL — this de-registers those embedded objects from
/// the extension before the BGW applies any new migrations.
async fn release_extension_owned_duroxide_objects(
    pool: &sqlx::PgPool,
    schema_name: &str,
) -> Result<(), sqlx::Error> {
    sqlx::query(&format!(
        r#"DO $$
DECLARE
    r RECORD;
BEGIN
    -- Release triggers before their functions: ALTER EXTENSION DROP TRIGGER only
    -- removes the pg_depend row; the trigger itself stays on the table.  Must
    -- precede the function loop so that CASCADE on function drops doesn't error
    -- trying to drop a still-extension-owned trigger.
    FOR r IN
        SELECT quote_ident(t.tgname)                                        AS trigger_name,
               quote_ident(n.nspname) || '.' || quote_ident(c.relname)     AS table_name
        FROM pg_trigger t
        JOIN pg_class c     ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_depend d
            ON d.objid    = t.oid
            AND d.classid = 'pg_trigger'::regclass
            AND d.deptype = 'e'
        JOIN pg_extension e
            ON e.oid = d.refobjid
            AND e.extname = 'pg_durable'
        WHERE n.nspname = '{schema}'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP TRIGGER '
                || r.trigger_name || ' ON ' || r.table_name;
    END LOOP;

    -- Release functions (regular, window, and procedures)
    FOR r IN
        SELECT p.oid::regprocedure::text AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_depend d
            ON d.objid = p.oid
            AND d.classid = 'pg_proc'::regclass
            AND d.deptype = 'e'
        JOIN pg_extension e
            ON e.oid = d.refobjid
            AND e.extname = 'pg_durable'
        WHERE n.nspname = '{schema}'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP FUNCTION ' || r.sig;
    END LOOP;

    -- Release tables
    FOR r IN
        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_depend d
            ON d.objid = c.oid
            AND d.classid = 'pg_class'::regclass
            AND d.deptype = 'e'
        JOIN pg_extension e
            ON e.oid = d.refobjid
            AND e.extname = 'pg_durable'
        WHERE n.nspname = '{schema}' AND c.relkind = 'r'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP TABLE ' || r.name;
    END LOOP;

    -- Release indexes: must be de-registered before migration scripts can
    -- DROP them; PostgreSQL rejects DROP INDEX (even with IF EXISTS) when the
    -- index is still an extension member.
    FOR r IN
        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_depend d
            ON d.objid = c.oid
            AND d.classid = 'pg_class'::regclass
            AND d.deptype = 'e'
        JOIN pg_extension e
            ON e.oid = d.refobjid
            AND e.extname = 'pg_durable'
        WHERE n.nspname = '{schema}' AND c.relkind = 'i'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP INDEX ' || r.name;
    END LOOP;

    -- Release sequences
    FOR r IN
        SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_depend d
            ON d.objid = c.oid
            AND d.classid = 'pg_class'::regclass
            AND d.deptype = 'e'
        JOIN pg_extension e
            ON e.oid = d.refobjid
            AND e.extname = 'pg_durable'
        WHERE n.nspname = '{schema}' AND c.relkind = 'S'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP SEQUENCE ' || r.name;
    END LOOP;
END $$"#,
        schema = schema_name
    ))
    .execute(pool)
    .await?;
    Ok(())
}

/// Returns true if any object inside the `duroxide` schema (other than the
/// schema namespace entry itself) is still registered as an extension member.
/// Used to short-circuit `release_extension_owned_duroxide_objects` on the
/// common path (fresh 0.2.0 installs and all restarts after the first upgrade).
async fn has_extension_owned_duroxide_objects(pool: &sqlx::PgPool, schema_name: &str) -> bool {
    let result: Result<(bool,), sqlx::Error> = sqlx::query_as(
        "SELECT EXISTS (
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_class c     ON c.oid = d.objid
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = $1
            WHERE d.classid = 'pg_class'::regclass AND d.deptype = 'e'
            UNION ALL
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_proc p      ON p.oid = d.objid
            JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = $1
            WHERE d.classid = 'pg_proc'::regclass AND d.deptype = 'e'
            UNION ALL
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_trigger t   ON t.oid = d.objid
            JOIN pg_class c     ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = $1
            WHERE d.classid = 'pg_trigger'::regclass AND d.deptype = 'e'
        )",
    )
    .bind(schema_name)
    .fetch_one(pool)
    .await;
    result.map(|(b,)| b).unwrap_or(false)
}

async fn initialize_duroxide_runtime(
    pg_conn_str: &str,
    retry_interval: Duration,
    mgmt_pool: &sqlx::PgPool,
    schema_name: &str,
) -> Option<(Arc<runtime::Runtime>, Arc<PostgresProvider>)> {
    log!("pg_durable: initializing duroxide runtime...");

    // Control duroxide provider pool size via env var (the only mechanism
    // without modifying duroxide-pg).
    //
    // SAFETY: The BGW tokio runtime uses new_current_thread() — no additional
    // OS threads are spawned. PostgreSQL's fork model means this process has no
    // other threads that could be reading the environment concurrently.
    unsafe {
        std::env::set_var(
            "DUROXIDE_PG_POOL_MAX",
            get_max_duroxide_connections().to_string(),
        );
    }

    // Create the user-execution semaphore once — the GUC is Postmaster-context
    // so the value never changes within a worker lifetime.
    let user_semaphore = Arc::new(tokio::sync::Semaphore::new(
        get_max_user_connections() as usize
    ));

    loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested during initialization");
            return None;
        }

        if !check_extension_exists(mgmt_pool).await {
            log!("pg_durable: extension no longer exists; returning to wait state");
            return None;
        }

        if !check_duroxide_schema_owned(mgmt_pool, schema_name).await {
            log!(
                "pg_durable: duroxide schema missing or not extension-owned \
                 (CREATE EXTENSION may still be in progress) — will retry"
            );
            tokio::select! {
                _ = tokio::time::sleep(retry_interval) => {}
                _ = wait_for_shutdown() => { return None; }
            }
            continue;
        }

        // Release any duroxide objects still owned by the extension so migration
        // scripts (which use DROP/CREATE FUNCTION) can run freely.  This is a
        // no-op on fresh installs; on upgrades from ≤0.1.1 it de-registers the
        // embedded DDL from the extension before ApplyAll runs.
        // The existence check avoids executing the five-loop DO block on every
        // clean restart once the upgrade has already been applied.
        if has_extension_owned_duroxide_objects(mgmt_pool, schema_name).await {
            if let Err(e) = release_extension_owned_duroxide_objects(mgmt_pool, schema_name).await {
                log!(
                    "pg_durable: failed to release extension-owned duroxide objects (will retry): {}",
                    e
                );
                tokio::select! {
                    _ = tokio::time::sleep(retry_interval) => {}
                    _ = wait_for_shutdown() => { return None; }
                }
                continue;
            }
        }

        let store = match PostgresProvider::new_with_config(worker_provider_config(
            pg_conn_str,
            schema_name,
        ))
        .await
        {
            Ok(s) => Arc::new(s),
            Err(e) => {
                log!(
                    "pg_durable: failed to create PostgreSQL store (will retry): {}",
                    e
                );
                tokio::select! {
                    _ = tokio::time::sleep(retry_interval) => {}
                    _ = wait_for_shutdown() => { return None; }
                }
                continue;
            }
        };

        // Reuse the management pool for activities (graph loading, status updates).
        // The former dedicated activity pool with its df.in_workflow hook is no
        // longer needed — connect_as_user() sets that flag independently.
        let activities =
            create_activity_registry(Arc::new(mgmt_pool.clone()), user_semaphore.clone());
        let orchestrations = create_orchestration_registry();

        let store_for_client = store.clone();

        let duroxide_runtime =
            runtime::Runtime::start_with_store(store, activities, orchestrations).await;

        log!("pg_durable: duroxide runtime started");
        return Some((duroxide_runtime, store_for_client));
    }
}

/// Write the epoch sentinel after a successful runtime init.
/// Returns the generated epoch_id on success.
async fn write_epoch_sentinel(pool: &sqlx::PgPool) -> Result<String, sqlx::Error> {
    let epoch_id = uuid::Uuid::new_v4().to_string();
    sqlx::query("DELETE FROM df._worker_epoch")
        .execute(pool)
        .await?;
    sqlx::query("INSERT INTO df._worker_epoch (epoch_id, started_at, last_seen_at) VALUES ($1::uuid, now(), now())")
        .bind(&epoch_id)
        .execute(pool)
        .await?;
    Ok(epoch_id)
}

/// Write the worker readiness record to `duroxide._worker_ready` after
/// successful BGW initialization.
///
/// Creates the table if it does not yet exist (first run after fresh install
/// or extension re-create). Writes or updates the row only when the stored
/// `schema_version` differs from `WORKER_SCHEMA_VERSION`; if the row already
/// matches, it is left untouched so `initialized_at` reflects when the current
/// schema version was first established rather than the last BGW restart.
async fn write_worker_ready(
    pool: &sqlx::PgPool,
    schema_name: &str,
    epoch_oid: i64,
) -> Result<(), sqlx::Error> {
    let mut transaction = pool.begin().await?;
    sqlx::query("SET LOCAL lock_timeout = '1500ms'")
        .execute(&mut *transaction)
        .await?;
    sqlx::query("LOCK TABLE df.instances, df.nodes IN ACCESS SHARE MODE")
        .execute(&mut *transaction)
        .await?;
    let current_epoch: Option<i64> = sqlx::query_scalar(
        "SELECT oid::bigint FROM pg_catalog.pg_extension WHERE extname = 'pg_durable'",
    )
    .fetch_optional(&mut *transaction)
    .await?;
    if current_epoch != Some(epoch_oid) {
        return Err(sqlx::Error::Protocol(
            "Control installation changed before readiness publication".to_string(),
        ));
    }
    let schema_name = format!("\"{}\"", schema_name.replace('"', "\"\""));
    sqlx::query(&format!(
        "CREATE TABLE IF NOT EXISTS {schema_name}._origins (
            database_oid BIGINT NOT NULL,
            installation_id UUID NOT NULL,
            PRIMARY KEY (database_oid, installation_id)
        )"
    ))
    .execute(&mut *transaction)
    .await?;
    sqlx::query(&format!("REVOKE ALL ON {schema_name}._origins FROM PUBLIC"))
        .execute(&mut *transaction)
        .await?;

    sqlx::query(&format!(
        "CREATE TABLE IF NOT EXISTS {schema}._worker_ready (
            sentinel        BOOLEAN PRIMARY KEY DEFAULT TRUE,
            CONSTRAINT      only_one_sentinel CHECK (sentinel),
            schema_version  INT NOT NULL,
            initialized_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )",
        schema = schema_name
    ))
    .execute(&mut *transaction)
    .await?;

    // Allow non-superuser sessions to read the readiness record via
    // is_worker_ready() which runs SPI in the caller's security context.
    sqlx::query(&format!(
        "GRANT USAGE ON SCHEMA {schema} TO PUBLIC",
        schema = schema_name
    ))
    .execute(&mut *transaction)
    .await?;
    sqlx::query(&format!(
        "GRANT SELECT ON {schema}._worker_ready TO PUBLIC",
        schema = schema_name
    ))
    .execute(&mut *transaction)
    .await?;

    sqlx::query(&format!(
        "INSERT INTO {schema}._worker_ready (sentinel, schema_version, initialized_at) \
         VALUES (TRUE, $1, now()) \
         ON CONFLICT (sentinel) DO UPDATE SET \
             schema_version = EXCLUDED.schema_version, \
             initialized_at = EXCLUDED.initialized_at \
         WHERE {schema}._worker_ready.schema_version != EXCLUDED.schema_version",
        schema = schema_name
    ))
    .bind(crate::WORKER_SCHEMA_VERSION)
    .execute(&mut *transaction)
    .await?;

    transaction.commit().await?;
    Ok(())
}

pub(crate) async fn register_origin(pool: &sqlx::PgPool, origin: &Origin) -> Result<(), String> {
    let schema = resolve_duroxide_schema_pool(pool).await;
    let schema = format!("\"{}\"", schema.replace('"', "\"\""));
    sqlx::query(&format!(
        "INSERT INTO {schema}._origins (database_oid, installation_id)
         VALUES ($1, $2) ON CONFLICT (database_oid, installation_id) DO NOTHING"
    ))
    .bind(i64::from(origin.database_oid))
    .bind(origin.installation_id)
    .execute(pool)
    .await
    .map_err(|error| format!("register origin: {error}"))?;
    Ok(())
}

/// Check whether our epoch sentinel still exists.
///
/// Returns `true` when the sentinel row is intact (keep running),
/// `false` when it is missing or the query fails (extension dropped
/// or drop+recreated).
async fn check_epoch_sentinel(pool: &sqlx::PgPool, epoch_id: &str) -> bool {
    let result = sqlx::query(
        "UPDATE df._worker_epoch SET last_seen_at = now() WHERE epoch_id = $1::uuid RETURNING epoch_id",
    )
    .bind(epoch_id)
    .fetch_optional(pool)
    .await;

    // Query error (table/schema gone) ⇒ treat as "dropped"
    // None ⇒ row missing (drop+recreated)
    matches!(result, Ok(Some(_)))
}

/// Expired terminal instances: those beyond the newest `max_keep` (a hard cap
/// enforced regardless of age) OR older than `retention_days`. Read-only — the
/// caller retires the engine records before deleting the df rows.
async fn select_expired_instance_ids_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    retention_days: i32,
    max_keep: i64,
    limit: Option<i64>,
) -> Result<Vec<String>, sqlx::Error> {
    let ids: Option<Vec<String>> = sqlx::query_scalar(
        r#"
        WITH terminal_instances AS (
            SELECT
                ranked.id,
                ranked.terminal_at,
                pg_catalog.row_number() OVER (
                    ORDER BY ranked.terminal_at DESC NULLS LAST, ranked.id DESC
                ) AS terminal_rank
            FROM (
                SELECT
                    id,
                    -- Rank/age only by server-controlled timestamps. `updated_at`
                    -- is intentionally excluded: PUBLIC has column-level UPDATE on
                    -- it, and for 'failed'/'cancelled' rows `completed_at` is NULL,
                    -- so including `updated_at` would let a low-privilege user forge
                    -- the removal ordering/age. `completed_at` (set by the worker on
                    -- completion) and `created_at` (insert-time default, not
                    -- grantable) are not user-writable.
                    COALESCE(completed_at, created_at) AS terminal_at
                FROM df.instances
                WHERE status OPERATOR(pg_catalog.=) ANY (ARRAY['completed', 'failed', 'cancelled'])
            ) ranked
        )
        -- Expired when the row is beyond the newest $1 terminal instances (a hard
        -- cap enforced regardless of age) OR older than the retention window ($2
        -- days). Retained rows are thus always within the newest $1 AND younger than
        -- the retention window, so the retained terminal count never exceeds $1.
        SELECT pg_catalog.array_agg(id)
          FROM (
                SELECT id FROM terminal_instances
                WHERE terminal_rank OPERATOR(pg_catalog.>) $1
                    OR terminal_at OPERATOR(pg_catalog.<)
                        (pg_catalog.now() OPERATOR(pg_catalog.-) pg_catalog.make_interval(days => $2::int))
                ORDER BY terminal_rank DESC
                LIMIT $3
          ) expired
        "#,
    )
    .bind(max_keep)
    .bind(retention_days)
    .bind(limit)
    .fetch_one(&mut **tx)
    .await?;
    Ok(ids.unwrap_or_default())
}

/// Delete the df.nodes and df.instances rows for `ids` (nodes first, with the
/// circular same-instance FK deferred). Returns the counts deleted.
async fn delete_expired_instances_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    ids: &[String],
) -> Result<ExpiredDeletion, sqlx::Error> {
    if ids.is_empty() {
        return Ok(ExpiredDeletion {
            instances_deleted: 0,
            nodes_deleted: 0,
            deleted_ids: Vec::new(),
        });
    }
    sqlx::query("SET CONSTRAINTS ALL DEFERRED")
        .execute(&mut **tx)
        .await?;

    let (deleted_ids, nodes_deleted): (Option<Vec<String>>, i64) = sqlx::query_as(
        r#"
        WITH deleted_nodes AS (
            DELETE FROM df.nodes n
            USING pg_catalog.unnest($1::text[]) AS t(id)
            WHERE n.instance_id OPERATOR(pg_catalog.=) t.id
            RETURNING n.instance_id
        ),
        deleted_instances AS (
            DELETE FROM df.instances i
            USING pg_catalog.unnest($1::text[]) AS t(id)
            WHERE i.id OPERATOR(pg_catalog.=) t.id
            RETURNING i.id
        )
        SELECT
            (SELECT pg_catalog.array_agg(id) FROM deleted_instances) AS deleted_ids,
            (SELECT pg_catalog.count(*)::bigint FROM deleted_nodes) AS nodes_deleted
        "#,
    )
    .bind(ids)
    .fetch_one(&mut **tx)
    .await?;

    let deleted_ids = deleted_ids.unwrap_or_default();
    Ok(ExpiredDeletion {
        instances_deleted: deleted_ids.len() as i64,
        nodes_deleted,
        deleted_ids,
    })
}

/// Read the expired terminal instances.
async fn select_expired_instance_ids(
    pool: &sqlx::PgPool,
    retention_days: i32,
    max_keep: i64,
) -> Result<Vec<String>, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let ids = select_expired_instance_ids_tx(&mut tx, retention_days, max_keep, None).await?;
    tx.commit().await?;
    Ok(ids)
}

/// Delete the df rows for the given expired-instance ids.
async fn delete_expired_instances(
    pool: &sqlx::PgPool,
    ids: &[String],
) -> Result<ExpiredDeletion, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let stats = delete_expired_instances_tx(&mut tx, ids).await?;
    tx.commit().await?;
    Ok(stats)
}

/// Select and delete the eligible terminal instances in a single transaction.
/// Used by tests; the background worker instead runs the two halves separately so
/// it can retire the engine records between them (see
/// `run_until_extension_dropped_or_shutdown`).
#[cfg(any(test, feature = "pg_test"))]
pub(crate) async fn delete_expired_instances_transaction(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    retention_days: i32,
    max_keep: i64,
) -> Result<ExpiredDeletion, sqlx::Error> {
    let ids = select_expired_instance_ids_tx(tx, retention_days, max_keep, None).await?;
    delete_expired_instances_tx(tx, &ids).await
}

async fn run_until_extension_dropped_or_shutdown(
    poll_pool: &sqlx::PgPool,
    maintenance_pool: &sqlx::PgPool,
    duroxide_runtime: Arc<runtime::Runtime>,
    duroxide_store: Arc<PostgresProvider>,
    drop_poll_interval: Duration,
    shutdown_check_interval: Duration,
    epoch_id: Option<&str>,
) {
    log!("pg_durable: processing durable functions...");

    let client = Client::new(duroxide_store.clone());
    let router = Router::new(Arc::new(maintenance_pool.clone()));
    let mut origin_cursor = OriginRetentionCursor::default();
    let mut engine_cursor = String::new();

    let mut drop_check = tokio::time::interval(drop_poll_interval);
    drop_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // reconcile_interval=0 disables the sweep; the tick is then gated off, but
    // interval_at still needs a positive period, so fall back to 1h.
    let reconcile_interval = get_reconcile_interval();
    let reconcile_enabled = !reconcile_interval.is_zero();
    let effective_reconcile_interval = if reconcile_interval.is_zero() {
        Duration::from_secs(60 * 60)
    } else {
        reconcile_interval
    };
    let mut reconcile_check = tokio::time::interval_at(
        tokio::time::Instant::now() + effective_reconcile_interval,
        effective_reconcile_interval,
    );
    reconcile_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    'processing: loop {
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
            _ = reconcile_check.tick(), if reconcile_enabled => {
                let maintenance = async {
                let retention_days = get_retention_days();

                // Engine-first: retire the engine record before the df row, so a
                // failed pass only leaves the harmless direction — an engine record
                // with no df row (invisible to df.list_instances, reclaimed below),
                // never the reverse. The stores are thus eventually consistent.
                match select_expired_instance_ids(
                    maintenance_pool,
                    retention_days,
                    TERMINAL_INSTANCE_MAX_KEEP,
                )
                .await
                {
                    Ok(candidates) if !candidates.is_empty() => {
                        // Only delete the df rows once the engine records are gone;
                        // if that fails, leave both in place and retry next pass.
                        if retire_engine_records(&client, &candidates).await {
                            match delete_expired_instances(maintenance_pool, &candidates).await {
                                Ok(stats) => {
                                    if stats.instances_deleted > 0 || stats.nodes_deleted > 0 {
                                        log!(
                                            "pg_durable: removed {} expired instance(s) and {} node row(s)",
                                            stats.instances_deleted,
                                            stats.nodes_deleted
                                        );
                                    }
                                }
                                Err(e) => {
                                    log!("pg_durable: removing expired instances failed: {e}");
                                }
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) => log!("pg_durable: selecting expired instances failed: {e}"),
                }

                let retention = Duration::from_secs(retention_days as u64 * 86_400);
                match reclaim_orphaned_instances(maintenance_pool, &client, retention).await {
                    Ok(reclaimed) if reclaimed > 0 => {
                        log!("pg_durable: reclaimed {reclaimed} orphaned engine record(s)");
                    }
                    Ok(_) => {}
                    Err(e) => log!("pg_durable: reclaiming orphaned engine records failed: {e}"),
                }

                    let schema = resolve_duroxide_schema_pool(maintenance_pool).await;
                    let schema = format!("\"{}\"", schema.replace('"', "\"\""));
                    if let Err(error) = sweep_registered_origins(
                        maintenance_pool, &client, &router, &schema, retention_days, &mut origin_cursor,
                    ).await {
                        log!("pg_durable: origin retention failed: {error}");
                    }
                    if let Err(error) = reclaim_origin_instances(
                        maintenance_pool, &client, &router, &schema, retention, &mut engine_cursor,
                    ).await {
                        log!("pg_durable: origin reconciliation failed: {error}");
                    }
                };
                tokio::pin!(maintenance);
                loop {
                    tokio::select! {
                        _ = &mut maintenance => break,
                        _ = wait_for_shutdown() => break 'processing,
                        _ = drop_check.tick() => {
                            let still_valid = match epoch_id {
                                Some(eid) => check_epoch_sentinel(poll_pool, eid).await,
                                None => check_extension_exists(poll_pool).await,
                            };
                            if !still_valid {
                                log!("pg_durable: control extension removed during maintenance");
                                break 'processing;
                            }
                        }
                    }
                }
            }
        }
    }

    teardown_runtime(duroxide_runtime, duroxide_store).await;
}

const ORIGIN_BATCH: i64 = 8;
const ORIGIN_ENGINE_BATCH: i64 = 100;
const ORIGIN_OPERATION_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Default)]
struct OriginRetentionCursor {
    origin: (i64, uuid::Uuid),
    after_id: Option<String>,
}

impl OriginRetentionCursor {
    fn enter(&mut self, origin: (i64, uuid::Uuid)) {
        if self.origin != origin {
            self.after_id = None;
        }
        self.origin = origin;
    }

    fn resume_after_pass(&mut self, previous_id: Option<String>) -> bool {
        if self.after_id.is_some() && self.after_id != previous_id {
            return true;
        }
        self.after_id = None;
        false
    }
}

#[derive(sqlx::FromRow)]
struct OriginRetentionCandidate {
    id: String,
    terminal_rank: i64,
    expired_by_age: bool,
}

impl OriginRetentionCandidate {
    fn is_expired(&self, max_keep: i64) -> bool {
        self.terminal_rank > max_keep || self.expired_by_age
    }
}

async fn retire_origin_candidates<Retire, Retired>(
    candidates: Vec<OriginRetentionCandidate>,
    after_id: &mut Option<String>,
    max_keep: i64,
    mut retire: Retire,
) -> Result<(), String>
where
    Retire: FnMut(String) -> Retired,
    Retired: std::future::Future<Output = Result<(), String>>,
{
    if candidates.is_empty() {
        *after_id = None;
    }
    for candidate in candidates {
        *after_id = Some(candidate.id.clone());
        if candidate.is_expired(max_keep) {
            retire(candidate.id).await?;
        }
    }
    Ok(())
}

async fn sweep_registered_origins(
    pool: &sqlx::PgPool,
    client: &Client,
    router: &Router,
    schema: &str,
    retention_days: i32,
    cursor: &mut OriginRetentionCursor,
) -> Result<(), String> {
    let origins: Vec<(i64, uuid::Uuid)> = sqlx::query_as(&format!(
        "SELECT database_oid, installation_id FROM {schema}._origins
         WHERE (database_oid, installation_id) > ($1, $2)
            OR ((database_oid, installation_id) = ($1, $2) AND $4)
         ORDER BY database_oid, installation_id LIMIT $3"
    ))
    .bind(cursor.origin.0)
    .bind(cursor.origin.1)
    .bind(ORIGIN_BATCH)
    .bind(cursor.after_id.is_some())
    .fetch_all(pool)
    .await
    .map_err(|error| format!("list registered origins: {error}"))?;
    if origins.is_empty() {
        *cursor = OriginRetentionCursor::default();
    }
    for (database_oid, installation_id) in origins {
        cursor.enter((database_oid, installation_id));
        let origin = Origin {
            database_oid: u32::try_from(database_oid)
                .map_err(|_| "Invalid registered database OID")?,
            installation_id,
        };
        let previous_id = cursor.after_id.clone();
        let result = tokio::time::timeout(ORIGIN_OPERATION_TIMEOUT, async {
            let route = router.connect(&origin).await?;
            let result = retire_origin_instances(
                &route.pool,
                client,
                &origin,
                retention_days,
                &mut cursor.after_id,
            )
            .await;
            route.close().await;
            result
        })
        .await;
        match result {
            Ok(Ok(())) => {}
            Ok(Err(error)) => log!("pg_durable: retention for origin {origin:?} deferred: {error}"),
            Err(_) => log!("pg_durable: retention for origin {origin:?} timed out"),
        }
        if cursor.resume_after_pass(previous_id) {
            break;
        }
    }
    Ok(())
}

async fn retire_origin_instances(
    pool: &sqlx::PgPool,
    client: &Client,
    origin: &Origin,
    retention_days: i32,
    after_id: &mut Option<String>,
) -> Result<(), String> {
    let mut tx = pool.begin().await.map_err(|error| error.to_string())?;
    let candidates: Vec<OriginRetentionCandidate> = sqlx::query_as(
        r#"
        WITH terminal_instances AS (
            SELECT id, COALESCE(completed_at, created_at) AS terminal_at,
                pg_catalog.row_number() OVER (
                    ORDER BY COALESCE(completed_at, created_at) DESC NULLS LAST, id DESC
                ) AS terminal_rank
            FROM df.instances
            WHERE status OPERATOR(pg_catalog.=) ANY (ARRAY['completed', 'failed', 'cancelled'])
        )
        SELECT id, terminal_rank,
            terminal_at OPERATOR(pg_catalog.<)
                (pg_catalog.now() OPERATOR(pg_catalog.-) pg_catalog.make_interval(days => $1::int))
                AS expired_by_age
        FROM terminal_instances
        WHERE $2::text IS NULL OR id OPERATOR(pg_catalog.>) $2
        ORDER BY id LIMIT $3
        "#,
    )
    .bind(retention_days)
    .bind(after_id.as_deref())
    .bind(i64::from(RECLAIM_BATCH))
    .fetch_all(&mut *tx)
    .await
    .map_err(|error| error.to_string())?;
    tx.commit().await.map_err(|error| error.to_string())?;
    retire_origin_candidates(
        candidates,
        after_id,
        TERMINAL_INSTANCE_MAX_KEEP,
        |local_id| async move {
            let engine_id = origin.engine_id(&local_id);
            if origin_local_id(origin, &engine_id).is_none() {
                return Ok(());
            }
            match client.delete_instance(&engine_id, false).await {
                Ok(_) | Err(ClientError::InstanceNotFound { .. }) => {
                    delete_expired_instances(pool, &[local_id])
                        .await
                        .map_err(|error| error.to_string())?;
                }
                Err(ClientError::InstanceStillRunning { .. }) => {}
                Err(error) => return Err(format!("retire origin engine record: {error}")),
            }
            Ok(())
        },
    )
    .await
}

fn origin_local_id<'a>(origin: &Origin, engine_id: &'a str) -> Option<&'a str> {
    if engine_id.contains("::")
        || Origin::from_engine_id(engine_id).ok().flatten().as_ref() != Some(origin)
    {
        return None;
    }
    engine_id.strip_prefix(&origin.engine_id(""))
}

fn select_origin_orphans(
    origin: &Origin,
    failed_ids: Vec<String>,
    present_local_ids: &HashSet<String>,
) -> Vec<String> {
    failed_ids
        .into_iter()
        .filter(|engine_id| {
            origin_local_id(origin, engine_id)
                .is_some_and(|local_id| !present_local_ids.contains(local_id))
        })
        .collect()
}

async fn reclaim_origin_instances(
    pool: &sqlx::PgPool,
    client: &Client,
    router: &Router,
    schema: &str,
    retention: Duration,
    cursor: &mut String,
) -> Result<(), String> {
    let candidates: Vec<(String, String)> = sqlx::query_as(&format!(
        "SELECT i.instance_id, e.status FROM {schema}.instances i
         JOIN {schema}.executions e ON e.instance_id = i.instance_id
             AND e.execution_id = i.current_execution_id
         WHERE i.instance_id > $1 AND i.parent_instance_id IS NULL
             AND i.instance_id NOT LIKE '%::%'
             AND EXISTS (SELECT 1 FROM {schema}._origins o
                 WHERE i.instance_id LIKE 'pgdf-' || o.database_oid::text || '-' ||
                     pg_catalog.replace(o.installation_id::text, '-', '') || '-%')
         ORDER BY i.instance_id LIMIT $2"
    ))
    .bind(cursor.as_str())
    .bind(ORIGIN_ENGINE_BATCH)
    .fetch_all(pool)
    .await
    .map_err(|error| format!("list registered origin engine roots: {error}"))?;
    if let Some((last_id, _)) = candidates.last() {
        *cursor = last_id.clone();
    } else {
        cursor.clear();
    }
    let mut by_origin = BTreeMap::<(u32, uuid::Uuid), Vec<(String, String)>>::new();
    for (engine_id, status) in candidates {
        if let Ok(Some(origin)) = Origin::from_engine_id(&engine_id) {
            by_origin
                .entry((origin.database_oid, origin.installation_id))
                .or_default()
                .push((engine_id, status));
        }
    }
    for ((database_oid, installation_id), records) in by_origin {
        let origin = Origin {
            database_oid,
            installation_id,
        };
        let result = tokio::time::timeout(ORIGIN_OPERATION_TIMEOUT, async {
            match router.connect(&origin).await {
                Ok(route) => {
                    let result =
                        reclaim_existing_origin(&route.pool, client, &origin, records, retention)
                            .await;
                    route.close().await;
                    result
                }
                Err(route_error) => {
                    if origin_is_removed(pool, &origin).await? {
                        reclaim_removed_origin(client, &origin, records, retention).await
                    } else {
                        Err(route_error)
                    }
                }
            }
        })
        .await;
        match result {
            Ok(Ok(reclaimed)) if reclaimed > 0 => {
                log!("pg_durable: reclaimed {reclaimed} engine record(s) for origin {origin:?}");
            }
            Ok(Ok(_)) => {}
            Ok(Err(error)) => {
                log!("pg_durable: reconciliation for origin {origin:?} deferred: {error}")
            }
            Err(_) => log!("pg_durable: reconciliation for origin {origin:?} timed out"),
        }
    }
    Ok(())
}

async fn reclaim_existing_origin(
    pool: &sqlx::PgPool,
    client: &Client,
    origin: &Origin,
    records: Vec<(String, String)>,
    retention: Duration,
) -> Result<u64, String> {
    let failed: Vec<String> = records
        .into_iter()
        .filter(|(_, status)| status == "Failed")
        .map(|(engine_id, _)| engine_id)
        .collect();
    let local_ids: Vec<&str> = failed
        .iter()
        .filter_map(|engine_id| origin_local_id(origin, engine_id))
        .collect();
    if local_ids.is_empty() {
        return Ok(0);
    }
    let present: HashSet<String> =
        sqlx::query_scalar("SELECT id FROM df.instances WHERE id = ANY($1)")
            .bind(&local_ids)
            .fetch_all(pool)
            .await
            .map_err(|error| format!("cross-check origin df.instances: {error}"))?
            .into_iter()
            .collect();
    let orphans = select_origin_orphans(origin, failed, &present);
    if orphans.is_empty() {
        return Ok(0);
    }
    client
        .delete_instance_bulk(InstanceFilter {
            instance_ids: Some(orphans),
            completed_before: Some(retention_cutoff_ms(retention)),
            limit: Some(RECLAIM_BATCH),
        })
        .await
        .map(|result| result.instances_deleted)
        .map_err(|error| format!("delete origin orphans: {error}"))
}

async fn reclaim_removed_origin(
    client: &Client,
    origin: &Origin,
    records: Vec<(String, String)>,
    retention: Duration,
) -> Result<u64, String> {
    let mut roots = Vec::new();
    for (engine_id, status) in records {
        if origin_local_id(origin, &engine_id).is_none() {
            continue;
        }
        if status == "Running" {
            client
                .cancel_instance(&engine_id, "pg_durable origin installation removed")
                .await
                .map_err(|error| format!("cancel removed origin root: {error}"))?;
        }
        roots.push(engine_id);
    }
    if roots.is_empty() {
        return Ok(0);
    }
    client
        .delete_instance_bulk(InstanceFilter {
            instance_ids: Some(roots),
            completed_before: Some(retention_cutoff_ms(retention)),
            limit: Some(RECLAIM_BATCH),
        })
        .await
        .map(|result| result.instances_deleted)
        .map_err(|error| format!("delete removed origin roots: {error}"))
}

async fn origin_is_removed(pool: &sqlx::PgPool, origin: &Origin) -> Result<bool, String> {
    let database: Option<String> = sqlx::query_scalar(
        "SELECT datname FROM pg_catalog.pg_database WHERE oid = $1::bigint::oid",
    )
    .bind(i64::from(origin.database_oid))
    .fetch_optional(pool)
    .await
    .map_err(|error| format!("probe origin database: {error}"))?;
    let Some(database) = database else {
        return Ok(true);
    };
    let _permit = crate::origin::acquire_connections(1).await?;
    let options = sqlx::postgres::PgConnectOptions::from_str(
        &postgres_connection_string_with_application_name(WORKER_MANAGEMENT_APPLICATION_NAME),
    )
    .map_err(|error| error.to_string())?
    .database(&database);
    let mut probe = tokio::time::timeout(
        Duration::from_secs(5),
        sqlx::PgConnection::connect_with(&options),
    )
    .await
    .map_err(|_| "Origin absence connection timed out".to_string())?
    .map_err(|error| format!("connect origin absence probe: {error}"))?;
    let result = probe_origin_installation(&mut probe, origin).await;
    probe
        .close()
        .await
        .map_err(|error| format!("close origin absence probe: {error}"))?;
    result
}

async fn probe_origin_installation(
    connection: &mut sqlx::PgConnection,
    origin: &Origin,
) -> Result<bool, String> {
    let mut tx = connection
        .begin()
        .await
        .map_err(|error| error.to_string())?;
    sqlx::query("SET LOCAL lock_timeout = '1500ms'")
        .execute(&mut *tx)
        .await
        .map_err(|error| error.to_string())?;
    sqlx::query("SET LOCAL statement_timeout = '5s'")
        .execute(&mut *tx)
        .await
        .map_err(|error| error.to_string())?;
    let database_oid: i64 = sqlx::query_scalar(
        "SELECT oid::bigint FROM pg_catalog.pg_database
         WHERE datname = pg_catalog.current_database()",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|error| error.to_string())?;
    if database_oid != i64::from(origin.database_oid) {
        return Err("Origin database changed during absence probe".to_string());
    }
    let owned: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_extension e
         JOIN pg_catalog.pg_depend d ON d.refobjid = e.oid
             AND d.refclassid = 'pg_catalog.pg_extension'::regclass AND d.deptype = 'e'
         JOIN pg_catalog.pg_class c ON c.oid = d.objid
             AND d.classid = 'pg_catalog.pg_class'::regclass
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         WHERE e.extname = 'pg_durable' AND n.nspname = 'df' AND c.relname = '_installation')",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|error| error.to_string())?;
    if !owned {
        return Ok(true);
    }
    sqlx::query("LOCK TABLE df._installation IN ACCESS SHARE MODE")
        .execute(&mut *tx)
        .await
        .map_err(|error| error.to_string())?;
    let present: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM df._installation i
         JOIN pg_catalog.pg_depend d ON d.objid = 'df._installation'::regclass
             AND d.classid = 'pg_catalog.pg_class'::regclass AND d.deptype = 'e'
             AND d.refclassid = 'pg_catalog.pg_extension'::regclass
         JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
         WHERE i.id = $1)",
    )
    .bind(origin.installation_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(|error| error.to_string())?;
    tx.commit().await.map_err(|error| error.to_string())?;
    Ok(!present)
}

/// Shut down a duroxide runtime and close its store pool.
///
/// Two callers, and the branch below distinguishes them by cause rather than by
/// call site. When shutdown was requested, PostgreSQL is terminating this
/// process's backends, so the pool is closed before the runtime is aborted.
/// Otherwise the process stays alive and the runtime is being replaced — after an
/// extension drop/recreate, or after initialization ran against an epoch that has
/// since been replaced — so connections are drained before the pool is closed. In
/// the stale-epoch case the provider's objects may already be gone; the drain and
/// close timeouts bound how long that costs.
async fn teardown_runtime(
    duroxide_runtime: Arc<runtime::Runtime>,
    duroxide_store: Arc<PostgresProvider>,
) {
    log!("pg_durable: initiating duroxide runtime shutdown...");

    if is_shutdown_requested() {
        // Close before aborting — the reverse of the branch below. PostgreSQL is
        // killing this process's backends, so duroxide's dispatcher tasks stay
        // parked on dead sockets and never return their connections; close()
        // can never resolve here. Closing first still marks the pool closed so
        // pending acquisitions fail fast rather than waiting on a server that is
        // going away. In-flight queries see PoolClosed, which is correct: they
        // cannot commit against a stopping server anyway. proc_exit() reclaims
        // whatever is left.
        const POOL_CLOSE_GRACE: Duration = Duration::from_millis(100);
        let _ = tokio::time::timeout(POOL_CLOSE_GRACE, duroxide_store.pool().close()).await;

        // Some(0) is load-bearing on two duroxide internals: a non-zero timeout
        // is an unconditional sleep rather than a deadline, and the zero branch
        // returns without setting duroxide's cooperative shutdown_flag. Leaving
        // that flag unset is only safe because proc_exit() follows immediately.
        // Re-verify both when upgrading duroxide.
        duroxide_runtime.shutdown(Some(0)).await;
    } else {
        // Live process: the runtime is being restarted after an extension drop
        // or recreation, so connections must actually be reclaimed. Drain first,
        // then close, and keep the timeout as a backstop against the same
        // upstream deadlock should the server become unreachable mid-restart.
        duroxide_runtime.shutdown(Some(2_000)).await;

        const POOL_CLOSE_TIMEOUT: Duration = Duration::from_secs(5);
        if tokio::time::timeout(POOL_CLOSE_TIMEOUT, duroxide_store.pool().close())
            .await
            .is_err()
        {
            log!("pg_durable: duroxide store pool close timed out — forcing shutdown");
        }
    }

    log!("pg_durable: duroxide runtime shutdown complete");
}

/// Maximum orphans one reconciliation pass reclaims, bounding a single tick's work.
pub(crate) const RECLAIM_BATCH: u32 = 1000;

/// True for sub-orchestration instance ids, which the engine creates internally
/// or pg_durable names explicitly for composed graph execution. These children
/// legitimately have no df.instances row, so reconciliation must never delete them.
fn is_sub_orchestration(id: &str) -> bool {
    id.starts_with("sub::")
        || id.contains("::sub::")
        || crate::node_status::InstanceLineage::parse(id).is_some_and(|id| id.is_composed())
}

/// Milliseconds-since-epoch cutoff for "older than `retention`". Used as the
/// engine's `completed_before` filter so an orphan younger than the retention
/// window is left alone.
fn retention_cutoff_ms(retention: Duration) -> u64 {
    let since_epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    since_epoch.saturating_sub(retention).as_millis() as u64
}

/// From the engine's `Failed` instance ids and the set that still have a
/// df.instances row, select the orphans to reclaim: those with no df row and that
/// are not sub-orchestrations. Both legacy engine-named children and current
/// explicitly named composed children legitimately have no df row and must be kept.
/// Namespaced IDs require a separate cross-check in their registered origin.
pub(crate) fn select_orphans(
    failed_ids: Vec<String>,
    present: &std::collections::HashSet<String>,
) -> Vec<String> {
    failed_ids
        .into_iter()
        .filter(|id| matches!(crate::origin::Origin::from_engine_id(id), Ok(None)))
        .filter(|id| !is_sub_orchestration(id) && !present.contains(id))
        .collect()
}

/// Delete engine records the engine still holds but pg_durable no longer has a
/// df.instances row for, once they age past the `retention` window. Returns the
/// count reclaimed.
///
/// Only `Failed` engine instances are considered: a rolled-back df.start() leaves
/// its engine instance `Failed` (it can never load its graph), and scanning only
/// `Failed` keeps this cheap — the (potentially large) `Completed` set is retired
/// by reconciliation ahead of removing its df rows instead (see the reconcile
/// branch). Sub-orchestrations are excluded, and the `completed_before` filter
/// enforces the retention window so an instance whose df commit is merely
/// in-flight or just-landed is never touched.
async fn reclaim_orphaned_instances(
    pool: &sqlx::PgPool,
    client: &Client,
    retention: Duration,
) -> Result<u64, String> {
    let candidates: Vec<String> = client
        .list_instances_by_status("Failed")
        .await
        .map_err(|e| format!("list failed instances: {e:?}"))?;
    if candidates.is_empty() {
        return Ok(0);
    }

    // Keep only ids with no df.instances row (orphans). The worker pool bypasses
    // RLS, so this sees every user's rows.
    let present: std::collections::HashSet<String> =
        sqlx::query_scalar("SELECT id FROM df.instances WHERE id = ANY($1)")
            .bind(&candidates)
            .fetch_all(pool)
            .await
            .map_err(|e| format!("cross-check df.instances: {e}"))?
            .into_iter()
            .collect();

    let mut orphans = select_orphans(candidates, &present);
    if orphans.is_empty() {
        return Ok(0);
    }
    orphans.truncate(RECLAIM_BATCH as usize);

    let result = client
        .delete_instance_bulk(InstanceFilter {
            instance_ids: Some(orphans),
            completed_before: Some(retention_cutoff_ms(retention)),
            limit: Some(RECLAIM_BATCH),
        })
        .await
        .map_err(|e| format!("delete_instance_bulk: {e:?}"))?;
    Ok(result.instances_deleted)
}

/// Best-effort deletion of duroxide engine records by id, ahead of deleting the
/// matching df rows. Returns `true` when it is safe to delete those df rows —
/// the engine delete succeeded, or there was nothing to delete. On failure it
/// returns `false` so the caller leaves the df rows in place and retries the
/// whole instance next pass rather than orphaning its engine record.
async fn retire_engine_records(client: &Client, ids: &[String]) -> bool {
    let ids: Vec<String> = ids
        .iter()
        .filter(|id| !is_sub_orchestration(id))
        .cloned()
        .collect();
    if ids.is_empty() {
        return true;
    }
    let limit = ids.len().min(u32::MAX as usize) as u32;
    match client
        .delete_instance_bulk(InstanceFilter {
            instance_ids: Some(ids),
            completed_before: None,
            limit: Some(limit),
        })
        .await
    {
        Ok(result) => {
            if result.instances_deleted > 0 {
                log!(
                    "pg_durable: retired {} engine record(s) ahead of removing the df rows",
                    result.instances_deleted
                );
            }
            true
        }
        Err(e) => {
            log!("pg_durable: failed to retire engine records; deferring df removal: {e:?}");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::origin::Origin;
    use std::collections::HashSet;

    #[test]
    fn worker_origin_retention_advances_past_running_and_undecidable_prefix() {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(async {
                for undecidable_prefix in [false, true] {
                    let mut after_id = None;
                    let mut deleted = Vec::new();
                    let mut attempts = Vec::new();
                    let target = format!("{:08x}", RECLAIM_BATCH + 1);
                    let mut passes = 0;
                    while after_id.as_deref() != Some(target.as_str()) {
                        let candidates: Vec<_> = (u32::from(!undecidable_prefix)
                            ..=RECLAIM_BATCH + 1)
                            .map(|index| OriginRetentionCandidate {
                                id: format!("{index:08x}"),
                                terminal_rank: i64::from(RECLAIM_BATCH + 2 - index),
                                expired_by_age: true,
                            })
                            .filter(|candidate| {
                                after_id.as_ref().is_none_or(|last| candidate.id > *last)
                            })
                            .take(RECLAIM_BATCH as usize)
                            .collect();
                        assert!(candidates.len() <= RECLAIM_BATCH as usize);
                        let _ = retire_origin_candidates(candidates, &mut after_id, 10, |id| {
                            attempts.push(id.clone());
                            let result = if id == "00000000" {
                                Err("engine state undecidable".to_string())
                            } else {
                                if id == target {
                                    deleted.push(id);
                                }
                                Ok(())
                            };
                            std::future::ready(result)
                        })
                        .await;
                        passes += 1;
                        assert!(
                            passes <= 3,
                            "retention must not restart at the skipped prefix"
                        );
                    }
                    assert_eq!(passes, if undecidable_prefix { 3 } else { 2 });
                    assert_eq!(
                        attempts.len(),
                        RECLAIM_BATCH as usize + 1 + usize::from(undecidable_prefix)
                    );
                    assert_eq!(deleted, vec![target]);
                }
            });
    }

    #[test]
    fn worker_origin_retention_timeout_keeps_candidate_progress() {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap()
            .block_on(async {
                let mut after_id = None;
                let candidates = vec![OriginRetentionCandidate {
                    id: "00000001".to_string(),
                    terminal_rank: 1,
                    expired_by_age: true,
                }];
                assert!(tokio::time::timeout(
                    Duration::ZERO,
                    retire_origin_candidates(candidates, &mut after_id, 10, |_| {
                        std::future::pending::<Result<(), String>>()
                    }),
                )
                .await
                .is_err());
                assert_eq!(after_id.as_deref(), Some("00000001"));

                let mut cursor = OriginRetentionCursor {
                    origin: (42, uuid::Uuid::from_u128(7)),
                    after_id,
                };
                assert!(cursor.resume_after_pass(None));
                let mut retired = Vec::new();
                let candidates = ["00000001", "00000002"]
                    .into_iter()
                    .filter(|id| Some(*id) > cursor.after_id.as_deref())
                    .map(|id| OriginRetentionCandidate {
                        id: id.to_string(),
                        terminal_rank: 1,
                        expired_by_age: true,
                    })
                    .collect();
                retire_origin_candidates(candidates, &mut cursor.after_id, 10, |id| {
                    retired.push(id);
                    std::future::ready(Ok(()))
                })
                .await
                .unwrap();
                assert_eq!(retired, vec!["00000002"]);

                retire_origin_candidates(
                    Vec::new(),
                    &mut cursor.after_id,
                    10,
                    |_| -> std::future::Ready<Result<(), String>> {
                        panic!("an exhausted page cannot retire an instance");
                    },
                )
                .await
                .unwrap();
                assert!(!cursor.resume_after_pass(Some("00000002".to_string())));
                assert_eq!(cursor.after_id, None);
                let candidates = vec![OriginRetentionCandidate {
                    id: "00000001".to_string(),
                    terminal_rank: 1,
                    expired_by_age: true,
                }];
                retire_origin_candidates(candidates, &mut cursor.after_id, 10, |id| {
                    retired.push(id);
                    std::future::ready(Ok(()))
                })
                .await
                .unwrap();
                assert_eq!(retired, vec!["00000002", "00000001"]);
            });
    }

    #[test]
    fn worker_origin_retention_preserves_max_keep_and_age() {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(async {
                let candidates = [(1, false), (10, false), (11, false), (2, true), (12, true)]
                    .into_iter()
                    .enumerate()
                    .map(
                        |(index, (terminal_rank, expired_by_age))| OriginRetentionCandidate {
                            id: format!("{index:08x}"),
                            terminal_rank,
                            expired_by_age,
                        },
                    )
                    .collect();
                let mut after_id = None;
                let mut retired = Vec::new();
                retire_origin_candidates(candidates, &mut after_id, 10, |id| {
                    retired.push(id);
                    std::future::ready(Ok(()))
                })
                .await
                .unwrap();
                assert_eq!(retired, vec!["00000002", "00000003", "00000004"]);
                assert_eq!(after_id.as_deref(), Some("00000004"));
            });
    }

    #[test]
    fn worker_origin_retention_cursor_is_scoped_to_installation() {
        let first = (42, uuid::Uuid::from_u128(7));
        let replacement = (42, uuid::Uuid::from_u128(8));
        let mut cursor = OriginRetentionCursor::default();
        cursor.enter(first);
        cursor.after_id = Some("deadbeef".to_string());
        cursor.enter(first);
        assert_eq!(cursor.after_id.as_deref(), Some("deadbeef"));
        cursor.enter(replacement);
        assert_eq!(cursor.after_id, None);
        cursor.after_id = Some("cafebabe".to_string());
        cursor.enter((43, uuid::Uuid::from_u128(8)));
        assert_eq!(cursor.after_id, None);
        cursor.after_id = Some("deadbeef".to_string());
        assert!(!cursor.resume_after_pass(Some("deadbeef".to_string())));
        assert_eq!(cursor.after_id, None);
    }

    #[test]
    fn worker_legacy_orphans_exclude_satellites_and_malformed_namespaces() {
        let origin = Origin {
            database_oid: 42,
            installation_id: uuid::Uuid::from_u128(7),
        };
        let failed = vec![
            "deadbeef".to_string(),
            "cafebabe".to_string(),
            origin.engine_id("deadbeef"),
            format!("{}::2::cafebabe", origin.engine_id("deadbeef")),
            "pgdf-invalid".to_string(),
            "sub::child".to_string(),
            "deadbeef::sub::child".to_string(),
            "deadbeef::2::cafebabe".to_string(),
        ];
        assert_eq!(
            select_orphans(failed, &HashSet::from(["cafebabe".to_string()])),
            vec!["deadbeef".to_string()]
        );
    }

    #[test]
    fn worker_origin_orphans_require_matching_database_and_installation() {
        let origin = Origin {
            database_oid: 42,
            installation_id: uuid::Uuid::from_u128(7),
        };
        let other_database = Origin {
            database_oid: 43,
            ..origin.clone()
        };
        let replacement = Origin {
            installation_id: uuid::Uuid::from_u128(8),
            ..origin.clone()
        };
        let candidates = vec![
            origin.engine_id("deadbeef"),
            origin.engine_id("cafebabe"),
            other_database.engine_id("deadbeef"),
            replacement.engine_id("deadbeef"),
            "deadbeef".to_string(),
            "pgdf-invalid".to_string(),
            format!("{}::2::12345678", origin.engine_id("deadbeef")),
            format!("{}::2::12345678::3::abcdef12", origin.engine_id("deadbeef")),
        ];
        assert_eq!(
            select_origin_orphans(
                &origin,
                candidates,
                &HashSet::from(["cafebabe".to_string()])
            ),
            vec![origin.engine_id("deadbeef")]
        );
    }

    #[test]
    fn worker_origin_local_id_accepts_only_canonical_roots() {
        let origin = Origin {
            database_oid: 42,
            installation_id: uuid::Uuid::from_u128(7),
        };
        let root = origin.engine_id("deadbeef");
        assert_eq!(origin_local_id(&origin, &root), Some("deadbeef"));
        assert_eq!(
            origin_local_id(&origin, &format!("{root}::1::cafebabe")),
            None
        );
        assert_eq!(
            origin_local_id(&origin, &origin.engine_id("invalid!")),
            None
        );
        assert_eq!(origin_local_id(&origin, "deadbeef"), None);
        assert_eq!(
            origin_local_id(&origin, &root.replacen("pgdf-42-", "pgdf-042-", 1)),
            None
        );
    }
}
