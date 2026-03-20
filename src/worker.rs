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
    const INIT_RETRY_INTERVAL: Duration = Duration::from_secs(1);
    const SHUTDOWN_CHECK_INTERVAL: Duration = Duration::from_secs(1);

    let pg_conn_str = postgres_connection_string();
    log!(
        "pg_durable: background worker connected to PostgreSQL at {} (schema: {})",
        pg_conn_str,
        DUROXIDE_SCHEMA
    );

    // Single-connection pool reused for all extension-existence polling, avoiding
    // the overhead of opening/closing a TCP connection on every check.
    // Retry in a loop so the worker survives the target database not yet existing
    // (e.g. pg_regress creates `contrib_regression` after PostgreSQL starts).
    let poll_pool = loop {
        if is_shutdown_requested() {
            log!("pg_durable: shutdown requested before poll pool created, exiting");
            return;
        }
        match sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .connect(&pg_conn_str)
            .await
        {
            Ok(pool) => break pool,
            Err(e) => {
                log!(
                    "pg_durable: failed to create polling pool (will retry in 5s): {}",
                    e
                );
                tokio::time::sleep(Duration::from_secs(5)).await;
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

        let Some(duroxide_runtime) =
            initialize_duroxide_runtime(&pg_conn_str, INIT_RETRY_INTERVAL, &poll_pool).await
        else {
            // Shutdown requested or extension dropped while initializing.
            continue;
        };

        // Write the worker readiness record so backend sessions know the
        // duroxide schema is fully initialized for this schema version.
        // Skipped if the row already has the current WORKER_SCHEMA_VERSION.
        if let Err(e) = write_worker_ready(&poll_pool).await {
            log!("pg_durable: failed to write worker readiness record: {}", e);
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

/// Returns true if the `duroxide` schema exists AND is owned by the `pg_durable`
/// extension (dependency type 'e' in pg_depend).
///
/// This prevents the BGW from running ApplyAll into an attacker-crafted schema
/// that happens to be named "duroxide" but was not created by CREATE EXTENSION.
async fn check_duroxide_schema_owned(pool: &sqlx::PgPool) -> bool {
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
            WHERE n.nspname = 'duroxide'
        )",
    )
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
async fn release_extension_owned_duroxide_objects(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    sqlx::query(
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
        WHERE n.nspname = 'duroxide'
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
        WHERE n.nspname = 'duroxide'
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
        WHERE n.nspname = 'duroxide' AND c.relkind = 'r'
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
        WHERE n.nspname = 'duroxide' AND c.relkind = 'i'
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
        WHERE n.nspname = 'duroxide' AND c.relkind = 'S'
    LOOP
        EXECUTE 'ALTER EXTENSION pg_durable DROP SEQUENCE ' || r.name;
    END LOOP;
END $$"#,
    )
    .execute(pool)
    .await?;
    Ok(())
}

/// Returns true if any object inside the `duroxide` schema (other than the
/// schema namespace entry itself) is still registered as an extension member.
/// Used to short-circuit `release_extension_owned_duroxide_objects` on the
/// common path (fresh 0.2.0 installs and all restarts after the first upgrade).
async fn has_extension_owned_duroxide_objects(pool: &sqlx::PgPool) -> bool {
    let result: Result<(bool,), sqlx::Error> = sqlx::query_as(
        "SELECT EXISTS (
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_class c     ON c.oid = d.objid
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'duroxide'
            WHERE d.classid = 'pg_class'::regclass AND d.deptype = 'e'
            UNION ALL
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_proc p      ON p.oid = d.objid
            JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'duroxide'
            WHERE d.classid = 'pg_proc'::regclass AND d.deptype = 'e'
            UNION ALL
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_durable'
            JOIN pg_trigger t   ON t.oid = d.objid
            JOIN pg_class c     ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'duroxide'
            WHERE d.classid = 'pg_trigger'::regclass AND d.deptype = 'e'
        )",
    )
    .fetch_one(pool)
    .await;
    result.map(|(b,)| b).unwrap_or(false)
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

        if !check_duroxide_schema_owned(poll_pool).await {
            log!(
                "pg_durable: duroxide schema missing or not extension-owned \
                 (CREATE EXTENSION may still be in progress) — will retry"
            );
            tokio::time::sleep(retry_interval).await;
            continue;
        }

        // Release any duroxide objects still owned by the extension so migration
        // scripts (which use DROP/CREATE FUNCTION) can run freely.  This is a
        // no-op on fresh installs; on upgrades from ≤0.1.1 it de-registers the
        // embedded DDL from the extension before ApplyAll runs.
        // The existence check avoids executing the five-loop DO block on every
        // clean restart once the upgrade has already been applied.
        if has_extension_owned_duroxide_objects(poll_pool).await {
            if let Err(e) = release_extension_owned_duroxide_objects(poll_pool).await {
                log!(
                    "pg_durable: failed to release extension-owned duroxide objects (will retry): {}",
                    e
                );
                tokio::time::sleep(retry_interval).await;
                continue;
            }
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
async fn write_worker_ready(pool: &sqlx::PgPool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS duroxide._worker_ready (
            sentinel        BOOLEAN PRIMARY KEY DEFAULT TRUE,
            CONSTRAINT      only_one_sentinel CHECK (sentinel),
            schema_version  INT NOT NULL,
            initialized_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )",
    )
    .execute(pool)
    .await?;

    // Allow non-superuser sessions to read the readiness record via
    // is_worker_ready() which runs SPI in the caller's security context.
    sqlx::query("GRANT USAGE ON SCHEMA duroxide TO PUBLIC")
        .execute(pool)
        .await?;
    sqlx::query("GRANT SELECT ON duroxide._worker_ready TO PUBLIC")
        .execute(pool)
        .await?;

    sqlx::query(
        "INSERT INTO duroxide._worker_ready (sentinel, schema_version, initialized_at) \
         VALUES (TRUE, $1, now()) \
         ON CONFLICT (sentinel) DO UPDATE SET \
             schema_version = EXCLUDED.schema_version, \
             initialized_at = EXCLUDED.initialized_at \
         WHERE duroxide._worker_ready.schema_version != EXCLUDED.schema_version",
    )
    .bind(crate::WORKER_SCHEMA_VERSION)
    .execute(pool)
    .await?;

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
