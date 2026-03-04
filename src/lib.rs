//! pg_durable - Durable SQL Functions for PostgreSQL
//!
//! This extension provides durable, fault-tolerant function execution within PostgreSQL
//! using the Duroxide runtime for persistence.

use pgrx::guc::*;
use pgrx::prelude::*;
use std::ffi::CString;

// ============================================================================
// GUC Definitions
// ============================================================================

pub static WORKER_ROLE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"azuresu"));

// Module declarations
pub mod activities;
pub mod client;
pub mod dsl;
pub mod explain;
pub mod monitoring;
pub mod orchestrations;
pub mod registry;
pub mod types;
pub mod worker;

// Re-export key types for tests
pub use types::Durofut;

::pgrx::pg_module_magic!(name, version);

// ============================================================================
// Background Worker Registration
// ============================================================================

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    if unsafe { !pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
        pgrx::error!(
            "pg_durable must be loaded via shared_preload_libraries.\n\nHINT: Add 'pg_durable' to shared_preload_libraries in postgresql.conf and restart the server."
        );
    }
    GucRegistry::define_string_guc(
        c"pg_durable.worker_role",
        c"PostgreSQL role used by the pg_durable background worker",
        c"",
        &WORKER_ROLE,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    worker::register_background_worker();
}

// ============================================================================
// Schema Declaration
// ============================================================================

/// The 'df' schema contains all pg_durable functions (df = durable functions)
#[pg_schema]
mod df {}

// ============================================================================
// Table Definitions
// ============================================================================

extension_sql!(
    r#"
-- Table to store function nodes (SQL steps, THEN chains, etc.)
CREATE TABLE IF NOT EXISTS df.nodes (
    id VARCHAR(8) PRIMARY KEY,
    instance_id VARCHAR(8),
    node_type TEXT NOT NULL,
    query TEXT,
    result_name TEXT,
    left_node VARCHAR(8),
    right_node VARCHAR(8),
    status TEXT DEFAULT 'pending',
    result JSONB,
    error TEXT,
    submitted_by REGROLE,
    login_role   REGROLE,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON COLUMN df.nodes.submitted_by IS
    'Effective role (outer user) for privilege isolation. Set by df.start() when node is linked to an instance.';
COMMENT ON COLUMN df.nodes.login_role IS
    'Authenticated role (session user) for connection authentication. Set by df.start() when node is linked to an instance.';

-- Table to store function instances
CREATE TABLE IF NOT EXISTS df.instances (
    id VARCHAR(8) PRIMARY KEY,
    label TEXT,
    root_node VARCHAR(8) NOT NULL,
    status TEXT DEFAULT 'pending',
    submitted_by REGROLE NOT NULL,
    login_role   REGROLE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

COMMENT ON COLUMN df.instances.submitted_by IS
    'Effective role (outer user) when df.start() was called - used for SET ROLE during execution';
COMMENT ON COLUMN df.instances.login_role IS
    'Authenticated role (session user) when df.start() was called - used for connection authentication';

-- Index for finding pending instances
CREATE INDEX IF NOT EXISTS idx_instances_status ON df.instances(status);

-- Index for finding nodes by instance
CREATE INDEX IF NOT EXISTS idx_nodes_instance ON df.nodes(instance_id);

-- Table to store workflow variables (captured at df.start())
CREATE TABLE IF NOT EXISTS df.vars (
    name TEXT PRIMARY KEY,
    value TEXT
);

-- Sentinel table: the background worker writes its epoch_id here after
-- initialising.  If the extension is DROP-ed and re-CREATEd between
-- two poll ticks the epoch row disappears, so the worker detects the
-- recreation even though the extension is always "present" in pg_extension.
CREATE TABLE IF NOT EXISTS df._worker_epoch (
    epoch_id UUID PRIMARY KEY,
    started_at TIMESTAMPTZ DEFAULT now()
);
"#,
    name = "create_tables",
    requires = [df]
);

// ============================================================================
// Extension Validation (must run before duroxide schema creation)
// ============================================================================

// In production builds, validate that the extension is created in the database
// the background worker will connect to.  In pgrx test builds the test database
// name is chosen by pgrx and won't match the worker's target database, so we
// skip the check (unit tests don't need the background worker).

#[cfg(not(any(test, feature = "pg_test")))]
extension_sql!(
    r#"
-- Validate that CREATE EXTENSION is run in the correct database
-- The background worker connects to one specific database (determined by
-- POSTGRES_DB or PGDATABASE environment variable). The extension must be
-- created in that database for workflows to execute.
DO $$
DECLARE
    current_db TEXT;
    target_db TEXT;
BEGIN
    -- Get the current database
    SELECT current_database() INTO current_db;
    
    -- Get the target database that the background worker will connect to
    SELECT df.target_database() INTO target_db;
    
    IF current_db != target_db THEN
        RAISE EXCEPTION 'pg_durable extension must be created in database "%" (currently in "%"). The background worker only processes functions in the database specified by POSTGRES_DB or PGDATABASE environment variable (defaults to "postgres").', target_db, current_db
            USING HINT = 'Connect to the correct database and run: CREATE EXTENSION pg_durable;';
    END IF;
END $$;
"#,
    name = "validate_database",
    requires = [df, target_database]
);

#[cfg(any(test, feature = "pg_test"))]
extension_sql!(
    r#"
-- Test build: skip database validation.
-- pgrx creates a test database whose name differs from the background worker's
-- target database.  The worker won't run in the test database; unit tests that
-- exercise duroxide use direct tokio runtimes instead.
DO $$
BEGIN
    RAISE NOTICE 'pg_durable: database validation skipped (test build)';
END $$;
"#,
    name = "validate_database",
    requires = [df]
);

// ============================================================================
// Duroxide Schema (experimental hand-over)
// ============================================================================

extension_sql_file!(
    "../sql/duroxide_install.sql",
    name = "duroxide_migrations_install",
    requires = ["validate_database"]
);

// ============================================================================
// SQL Operators
// ============================================================================

extension_sql!(
    r#"
-- Operator ~> for sequencing: a ~> b means "run a, then run b"
CREATE OPERATOR ~> (
    FUNCTION = df.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator |=> for naming: fut |=> 'name' means "name this result as $name"
CREATE OR REPLACE FUNCTION df.as_op(fut text, name text) RETURNS text AS $$
    SELECT df.as(fut, name);
$$ LANGUAGE SQL IMMUTABLE;

CREATE OPERATOR |=> (
    FUNCTION = df.as_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator & for parallel join: a & b means "run a and b in parallel, wait for both"
CREATE OPERATOR & (
    FUNCTION = df.join,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator | for race: a | b means "run a and b in parallel, first wins"
CREATE OPERATOR | (
    FUNCTION = df.race,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operators ?> and !> for if-then-else: cond ?> then_branch !> else_branch
-- We need helper functions to build the if node incrementally

-- Helper: cond ?> then creates a partial if (stores condition and then branch)
CREATE OR REPLACE FUNCTION df.if_then_op(condition text, then_branch text) RETURNS text AS $$
DECLARE
    cond_fut jsonb;
    then_fut jsonb;
    result_obj jsonb;
BEGIN
    -- Ensure both are durofuts
    cond_fut := df.ensure_durofut(condition)::jsonb;
    then_fut := df.ensure_durofut(then_branch)::jsonb;
    
    -- Return a special marker object for the partial if
    result_obj := jsonb_build_object(
        '_partial_if', true,
        'condition', cond_fut,
        'then_branch', then_fut
    );
    RETURN result_obj::text;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Helper: partial_if !> else completes the if node
CREATE OR REPLACE FUNCTION df.if_else_op(partial_if text, else_branch text) RETURNS text AS $$
DECLARE
    partial jsonb;
    else_fut text;
    cond_text text;
    then_text text;
BEGIN
    partial := partial_if::jsonb;
    
    -- Check if it's a partial if
    IF partial->>'_partial_if' IS NULL THEN
        RAISE EXCEPTION 'Invalid if-then-else: left side of !> must be a ?> expression';
    END IF;
    
    cond_text := partial->'condition'::text;
    then_text := partial->'then_branch'::text;
    else_fut := df.ensure_durofut(else_branch);
    
    -- Now call the real df.if function
    RETURN df.if(cond_text, then_text, else_fut);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Helper to ensure a value is a durofut (returns JSON string)
CREATE OR REPLACE FUNCTION df.ensure_durofut(val text) RETURNS text AS $$
BEGIN
    -- Try to parse as JSON to check if it's already a durofut
    BEGIN
        IF (val::jsonb)->>'node_id' IS NOT NULL THEN
            RETURN val;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Not valid JSON, treat as SQL
        NULL;
    END;
    
    -- It's plain SQL, wrap it
    RETURN df.sql(val);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OPERATOR ?> (
    FUNCTION = df.if_then_op,
    LEFTARG = text,
    RIGHTARG = text
);

CREATE OPERATOR !> (
    FUNCTION = df.if_else_op,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator @> for loop: @> body means "repeat body forever"
-- This is a PREFIX operator with lowest precedence
CREATE OR REPLACE FUNCTION df.loop_prefix_op(body text) RETURNS text AS $$
    SELECT df.loop(body);
$$ LANGUAGE SQL IMMUTABLE;

CREATE OPERATOR @> (
    FUNCTION = df.loop_prefix_op,
    RIGHTARG = text
);
"#,
    name = "create_operators",
    requires = [
        dsl::then_fn,
        dsl::as_named,
        dsl::join,
        dsl::race,
        dsl::if_fn,
        dsl::loop_fn
    ]
);

// ============================================================================
// Tests
// ============================================================================

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use crate::Durofut;
    use pgrx::prelude::*;
    use std::sync::Arc;

    // ========================================================================
    // Test Helpers for Integration Tests
    // ========================================================================

    /// Ensure the Duroxide store exists and is ready
    fn ensure_store_ready() -> Result<String, String> {
        use crate::types::{backend_provider_config, postgres_connection_string, DUROXIDE_SCHEMA};
        use duroxide_pg_opt::PostgresProvider;
        use std::time::{Duration, Instant};

        let pg_conn_str = postgres_connection_string();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {e}"))?;

        // Try to initialize the store (creates schema if it doesn't exist)
        rt.block_on(async {
            let start = Instant::now();
            let timeout = Duration::from_secs(10);

            let config = backend_provider_config();

            loop {
                match PostgresProvider::new_with_config(&pg_conn_str, config.clone()).await {
                    Ok(_) => return Ok(format!("{pg_conn_str} (schema: {DUROXIDE_SCHEMA})")),
                    Err(e) => {
                        if start.elapsed() > timeout {
                            return Err(format!(
                                "Failed to initialize store after {}s: {}",
                                timeout.as_secs(),
                                e
                            ));
                        }
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        })
    }

    /// Wait for a durable function to complete, polling Duroxide status
    fn wait_for_completion(instance_id: &str, timeout_secs: u64) -> Result<String, String> {
        use crate::types::{backend_provider_config, postgres_connection_string};
        use duroxide::Client;
        use duroxide_pg_opt::PostgresProvider;
        use std::time::{Duration, Instant};

        // Ensure store is ready first
        let _ = ensure_store_ready()?;

        let pg_conn_str = postgres_connection_string();
        let start = Instant::now();
        let timeout = Duration::from_secs(timeout_secs);

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {e}"))?;

        rt.block_on(async {
            let store = Arc::new(
                PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
                    .await
                    .map_err(|e| format!("Failed to connect to store: {e}"))?,
            );
            let client = Client::new(store);

            loop {
                if let Ok(info) = client.get_instance_info(instance_id).await {
                    match info.status.as_str() {
                        "Completed" | "ContinuedAsNew" => {
                            return Ok(info.output.unwrap_or_default());
                        }
                        "Failed" | "Canceled" => {
                            return Err(format!(
                                "{}: {}",
                                info.status,
                                info.output.unwrap_or_default()
                            ));
                        }
                        _ => {} // Still running
                    }
                }
                // Instance not found yet - continue polling

                if start.elapsed() > timeout {
                    // Get final status for better error message
                    let final_status = client
                        .get_instance_info(instance_id)
                        .await
                        .map(|i| i.status)
                        .unwrap_or_else(|_| "unknown".to_string());
                    return Err(format!(
                        "Timeout after {timeout_secs}s, status: {final_status}"
                    ));
                }

                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
    }

    /// Get the current status from Duroxide
    fn get_duroxide_status(instance_id: &str) -> Option<String> {
        use crate::types::{backend_provider_config, postgres_connection_string};
        use duroxide::Client;
        use duroxide_pg_opt::PostgresProvider;

        let _ = ensure_store_ready().ok()?;
        let pg_conn_str = postgres_connection_string();

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()?;

        rt.block_on(async {
            let store = Arc::new(
                PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
                    .await
                    .ok()?,
            );
            let client = Client::new(store);
            client
                .get_instance_info(instance_id)
                .await
                .ok()
                .map(|i| i.status)
        })
    }

    // ========================================================================
    // Unit Tests - DSL Node Creation
    // ========================================================================

    #[pg_test]
    fn test_sql_creates_valid_durofut() {
        let json = crate::dsl::sql("SELECT 1");
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SQL");
        assert!(!fut.node_id.is_empty());
    }

    #[pg_test]
    fn test_seq_creates_then_node() {
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let then_json = crate::dsl::then_fn(&a, &b);
        let then_fut = Durofut::from_json(&then_json);
        assert_eq!(then_fut.node_type, "THEN");
        assert!(then_fut.left_node.is_some());
        assert!(then_fut.right_node.is_some());
    }

    #[pg_test]
    fn test_as_named_sets_result_name() {
        let sql_json = crate::dsl::sql("SELECT 1");
        let named_json = crate::dsl::as_named(&sql_json, "my_result");
        let named_fut = Durofut::from_json(&named_json);
        assert_eq!(named_fut.result_name, Some("my_result".to_string()));
    }

    #[pg_test]
    fn test_sleep_creates_valid_node() {
        let json = crate::dsl::sleep(60);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SLEEP");
        assert_eq!(fut.query, Some("60".to_string()));
    }

    #[pg_test]
    fn test_wait_for_schedule_valid_cron() {
        let json = crate::dsl::wait_for_schedule("*/5 * * * *");
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "WAIT_SCHEDULE");
    }

    #[pg_test]
    fn test_loop_creates_loop_node() {
        let body = crate::dsl::sql("SELECT 1");
        let json = crate::dsl::loop_fn(&body, None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "LOOP");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_none()); // No condition = infinite loop
    }

    #[pg_test]
    fn test_loop_with_condition_creates_while_loop() {
        let body = crate::dsl::sql("SELECT 1");
        let condition = crate::dsl::sql("SELECT count(*) > 0 FROM queue");
        let json = crate::dsl::loop_fn(&body, Some(&condition));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "LOOP");
        assert!(fut.left_node.is_some()); // body
        assert!(fut.right_node.is_some()); // condition
        assert!(fut.query.is_some()); // has config with condition_node
    }

    #[pg_test]
    fn test_break_creates_break_node() {
        let json = crate::dsl::break_fn(None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "BREAK");
    }

    #[pg_test]
    fn test_break_with_value() {
        let json = crate::dsl::break_fn(Some(r#"{"status": "done"}"#));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "BREAK");
        assert!(fut.query.is_some());
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(
            config["break_value"].as_str().unwrap(),
            r#"{"status": "done"}"#
        );
    }

    #[pg_test]
    fn test_if_creates_if_node() {
        let condition = crate::dsl::sql("SELECT true");
        let then_branch = crate::dsl::sql("SELECT 'yes'");
        let else_branch = crate::dsl::sql("SELECT 'no'");
        let json = crate::dsl::if_fn(&condition, &then_branch, &else_branch);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "IF");
    }

    #[pg_test]
    fn test_join_creates_join_node() {
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let json = crate::dsl::join(&a, &b);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "JOIN");
    }

    // ========================================================================
    // Unit Tests - HTTP Node Creation
    // ========================================================================

    #[pg_test]
    fn test_http_creates_valid_node() {
        let json = crate::dsl::http("https://example.com/api", "GET", None, None, 30);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "HTTP");
        assert!(!fut.node_id.is_empty());
    }

    #[pg_test]
    fn test_http_post_with_body() {
        let json = crate::dsl::http(
            "https://api.example.com/data",
            "POST",
            Some(r#"{"key": "value"}"#),
            None,
            30,
        );
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "HTTP");

        // Parse config to verify body is stored
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["method"], "POST");
        assert_eq!(config["body"], r#"{"key": "value"}"#);
    }

    #[pg_test]
    fn test_http_with_headers() {
        let headers = pgrx::JsonB(serde_json::json!({
            "Authorization": "Bearer token123",
            "Content-Type": "application/json"
        }));
        let json = crate::dsl::http(
            "https://api.example.com/secure",
            "POST",
            Some(r#"{"data": "test"}"#),
            Some(headers),
            60,
        );
        let fut = Durofut::from_json(&json);

        // Parse config to verify headers are stored
        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["headers"]["Authorization"], "Bearer token123");
        assert_eq!(config["timeout_seconds"], 60);
    }

    #[pg_test]
    fn test_http_config_parsing() {
        use crate::types::HttpConfig;

        let json = crate::dsl::http(
            "https://httpbin.org/post",
            "POST",
            Some(r#"{"test": true}"#),
            None,
            45,
        );
        let fut = Durofut::from_json(&json);
        let config: HttpConfig = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();

        assert_eq!(config.url, "https://httpbin.org/post");
        assert_eq!(config.method, "POST");
        assert_eq!(config.body, Some(r#"{"test": true}"#.to_string()));
        assert_eq!(config.timeout_seconds, 45);
    }

    #[pg_test]
    fn test_http_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.http('https://example.com', 'GET')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "HTTP");
    }

    #[pg_test]
    fn test_http_in_sequence() {
        let http_node = crate::dsl::http("https://api.example.com/data", "GET", None, None, 30);
        let sql_node = crate::dsl::sql("SELECT 1");
        let seq = crate::dsl::then_fn(&http_node, &sql_node);
        let fut = Durofut::from_json(&seq);
        assert_eq!(fut.node_type, "THEN");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[pg_test]
    fn test_http_with_name() {
        let http_node = crate::dsl::http("https://api.example.com", "GET", None, None, 30);
        let named = crate::dsl::as_named(&http_node, "api_response");
        let fut = Durofut::from_json(&named);
        assert_eq!(fut.result_name, Some("api_response".to_string()));
    }

    #[pg_test]
    fn test_http_methods() {
        // Test all supported methods
        for method in &["GET", "POST", "PUT", "DELETE", "PATCH"] {
            let json = crate::dsl::http("https://example.com", method, None, None, 30);
            let fut = Durofut::from_json(&json);
            let config: serde_json::Value =
                serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
            assert_eq!(config["method"], *method);
        }
    }

    // ========================================================================
    // Unit Tests - Signals
    // ========================================================================

    #[pg_test]
    fn test_wait_for_signal_creates_valid_node() {
        let json = crate::dsl::wait_for_signal("approval", None);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SIGNAL");
        assert!(!fut.node_id.is_empty());

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "approval");
        assert!(config["timeout_seconds"].is_null());
    }

    #[pg_test]
    fn test_wait_for_signal_with_timeout() {
        let json = crate::dsl::wait_for_signal("approval", Some(3600));
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "SIGNAL");

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "approval");
        assert_eq!(config["timeout_seconds"], 3600);
    }

    #[pg_test]
    fn test_wait_for_signal_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.wait_for_signal('test_signal')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "SIGNAL");

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "test_signal");
    }

    #[pg_test]
    fn test_wait_for_signal_with_timeout_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.wait_for_signal('test_signal', 60)")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);

        let config: serde_json::Value = serde_json::from_str(fut.query.as_ref().unwrap()).unwrap();
        assert_eq!(config["signal_name"], "test_signal");
        assert_eq!(config["timeout_seconds"], 60);
    }

    #[pg_test]
    fn test_wait_for_signal_in_sequence() {
        let sql_node = crate::dsl::sql("SELECT 1");
        let signal_node = crate::dsl::wait_for_signal("go", None);
        let seq = crate::dsl::then_fn(&sql_node, &signal_node);
        let fut = Durofut::from_json(&seq);
        assert_eq!(fut.node_type, "THEN");
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[pg_test]
    fn test_wait_for_signal_with_name() {
        let signal_node = crate::dsl::wait_for_signal("approval", None);
        let named = crate::dsl::as_named(&signal_node, "sig");
        let fut = Durofut::from_json(&named);
        assert_eq!(fut.result_name, Some("sig".to_string()));
    }

    // ========================================================================
    // Unit Tests - Instance Management
    // ========================================================================

    #[pg_test]
    fn test_start_returns_instance_id() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None);
        assert_eq!(instance_id.len(), 8);
        assert!(instance_id.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[pg_test]
    fn test_start_with_label() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, Some("my-test-function"));
        assert_eq!(instance_id.len(), 8);
    }

    #[pg_test]
    fn test_start_creates_instance_row() {
        let fut = crate::dsl::sql("SELECT 42");
        let instance_id = crate::dsl::start(&fut, Some("test-instance-row"));
        let count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(*) FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(count, 1);
    }

    #[pg_test]
    fn test_status_returns_pending_for_new() {
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None);
        let status = crate::dsl::status(&instance_id);
        assert_eq!(status, Some("pending".to_string()));
    }

    // ========================================================================
    // Unit Tests - SQL Operators
    // ========================================================================

    #[pg_test]
    fn test_seq_operator_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2')")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_as_operator_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.sql('SELECT 1') |=> 'my_name'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.result_name, Some("my_name".to_string()));
    }

    #[pg_test]
    fn test_multiple_starts_different_ids() {
        let fut = crate::dsl::sql("SELECT 1");
        let id1 = crate::dsl::start(&fut, None);
        let id2 = crate::dsl::start(&fut, None);
        assert_ne!(id1, id2);
    }

    #[pg_test]
    fn test_debug_connection_returns_info() {
        let conn_info = crate::dsl::debug_connection();
        assert!(!conn_info.is_empty());
        assert!(conn_info.contains("duroxide")); // Should contain schema name
    }

    // ========================================================================
    // Unit Tests - Workflow Variables
    // ========================================================================

    #[pg_test]
    fn test_setvar_returns_ok() {
        let result = crate::dsl::setvar("test_var", "test_value");
        assert_eq!(result, "OK");
    }

    #[pg_test]
    fn test_getvar_returns_value() {
        crate::dsl::setvar("my_var", "hello");
        let value = crate::dsl::getvar("my_var");
        assert_eq!(value, Some("hello".to_string()));
    }

    #[pg_test]
    fn test_getvar_returns_none_for_missing() {
        let value = crate::dsl::getvar("nonexistent_var_xyz");
        assert_eq!(value, None);
    }

    #[pg_test]
    fn test_unsetvar_removes_var() {
        crate::dsl::setvar("to_remove", "value");
        assert!(crate::dsl::getvar("to_remove").is_some());
        crate::dsl::unsetvar("to_remove");
        assert!(crate::dsl::getvar("to_remove").is_none());
    }

    #[pg_test]
    fn test_clearvars_removes_all() {
        crate::dsl::setvar("var1", "a");
        crate::dsl::setvar("var2", "b");
        crate::dsl::clearvars();
        assert!(crate::dsl::getvar("var1").is_none());
        assert!(crate::dsl::getvar("var2").is_none());
    }

    #[pg_test]
    fn test_setvar_via_sql() {
        let result = Spi::get_one::<String>("SELECT df.setvar('sql_var', 'sql_value')")
            .unwrap()
            .unwrap();
        assert_eq!(result, "OK");

        let value = Spi::get_one::<String>("SELECT df.getvar('sql_var')").unwrap();
        assert_eq!(value, Some("sql_value".to_string()));
    }

    #[pg_test]
    fn test_setvar_overwrites() {
        crate::dsl::setvar("overwrite_var", "first");
        crate::dsl::setvar("overwrite_var", "second");
        let value = crate::dsl::getvar("overwrite_var");
        assert_eq!(value, Some("second".to_string()));
    }

    #[pg_test]
    fn test_vars_with_special_chars() {
        crate::dsl::setvar("special_var", "it's a \"test\"");
        let value = crate::dsl::getvar("special_var");
        assert_eq!(value, Some("it's a \"test\"".to_string()));
    }

    #[pg_test]
    fn test_setvar_works_in_user_session() {
        // In a normal user session, df.in_workflow is not set
        // so setvar should work
        let result = crate::dsl::setvar("user_session_var", "works");
        assert_eq!(result, "OK");

        // Verify the value was set
        let value = crate::dsl::getvar("user_session_var");
        assert_eq!(value, Some("works".to_string()));
    }

    #[pg_test]
    fn test_setvar_after_start_works() {
        // df.start() should not affect subsequent setvar calls
        let fut = crate::dsl::sql("SELECT 1");
        let _ = crate::dsl::start(&fut, None);

        // setvar should work fine after start returns
        let result = crate::dsl::setvar("after_start_var", "works");
        assert_eq!(result, "OK");
    }

    // Note: Testing that setvar fails in workflow context requires E2E test
    // because it depends on the background worker setting df.in_workflow='true'
    // on its connections. See tests/e2e/sql/20_vars.sql for E2E coverage.

    // ========================================================================
    // Unit Tests - Explain Functionality
    // ========================================================================

    #[pg_test]
    fn test_explain_detects_instance_id() {
        // Create an instance first
        let fut = crate::dsl::sql("SELECT 1");
        let instance_id = crate::dsl::start(&fut, None);

        // Explain should recognize it as an instance ID
        let result = crate::explain::explain(&instance_id);
        // Should contain SQL node info, not an error
        assert!(
            result.contains("SQL") || result.contains("SELECT"),
            "Expected SQL visualization, got: {result}"
        );
    }

    #[pg_test]
    fn test_explain_expression_simple_sql() {
        // Dry-run explain of a simple SQL
        let result = crate::explain::explain("df.sql('SELECT 42')");
        assert!(result.contains("SQL"), "Expected SQL in output: {result}");
        assert!(result.contains("42"), "Expected query content: {result}");
    }

    #[pg_test]
    fn test_explain_expression_sequence() {
        // Dry-run explain of a sequence
        let result = crate::explain::explain("df.sql('SELECT 1') ~> df.sql('SELECT 2')");
        // Should show sequence with arrows
        assert!(
            result.contains("SELECT 1"),
            "Expected first query: {result}"
        );
        assert!(
            result.contains("SELECT 2"),
            "Expected second query: {result}"
        );
    }

    #[pg_test]
    fn test_explain_expression_sleep() {
        let result = crate::explain::explain("df.sleep(60)");
        assert!(result.contains("SLEEP"), "Expected SLEEP node: {result}");
        assert!(result.contains("60"), "Expected duration: {result}");
    }

    #[pg_test]
    fn test_explain_expression_loop() {
        let result = crate::explain::explain("df.loop(df.sql('SELECT 1'))");
        assert!(result.contains("LOOP"), "Expected LOOP: {result}");
        assert!(result.contains("body"), "Expected body section: {result}");
    }

    #[pg_test]
    fn test_explain_expression_if() {
        let result = crate::explain::explain(
            "df.if(df.sql('SELECT true'), df.sql('SELECT yes'), df.sql('SELECT no'))",
        );
        assert!(result.contains("IF"), "Expected IF: {result}");
        assert!(result.contains("then"), "Expected then branch: {result}");
        assert!(result.contains("else"), "Expected else branch: {result}");
    }

    #[pg_test]
    fn test_explain_expression_join() {
        let result = crate::explain::explain("df.join(df.sql('SELECT 1'), df.sql('SELECT 2'))");
        assert!(result.contains("JOIN"), "Expected JOIN: {result}");
        assert!(result.contains("branch"), "Expected branches: {result}");
    }

    #[pg_test]
    fn test_explain_no_side_effects() {
        // After explain, no orphan nodes should exist in df.nodes
        let before_count: i64 =
            Spi::get_one("SELECT COUNT(*) FROM df.nodes WHERE instance_id IS NULL")
                .unwrap()
                .unwrap_or(0);

        let _ = crate::explain::explain("df.sql('SELECT orphan_test') ~> df.sleep(999)");

        let after_count: i64 =
            Spi::get_one("SELECT COUNT(*) FROM df.nodes WHERE instance_id IS NULL")
                .unwrap()
                .unwrap_or(0);

        // Should be the same - no orphan nodes added
        assert_eq!(
            before_count, after_count,
            "Explain should not leave orphan nodes in df.nodes"
        );
    }

    #[pg_test]
    fn test_explain_invalid_instance_id() {
        // Test with non-existent instance ID
        let result = crate::explain::explain("deadbeef");
        assert!(
            result.contains("not found"),
            "Expected 'not found' error: {result}"
        );
    }

    #[pg_test]
    fn test_explain_complex_nested() {
        // Complex nested structure: loop with if inside
        let result = crate::explain::explain(
            "df.loop(df.if(df.sql('SELECT true'), df.sql('SELECT yes'), df.sql('SELECT no')))",
        );
        assert!(result.contains("LOOP"), "Expected LOOP: {result}");
        assert!(result.contains("IF"), "Expected IF: {result}");
    }

    // ========================================================================
    // Unit Tests - Auto-Wrap SQL Strings
    // ========================================================================

    #[pg_test]
    fn test_autowrap_sequence_plain_sql() {
        // Plain SQL strings should be auto-wrapped
        let result = crate::dsl::then_fn("SELECT 1", "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
        // Both children should exist as SQL nodes
        assert!(fut.left_node.is_some());
        assert!(fut.right_node.is_some());
    }

    #[pg_test]
    fn test_autowrap_sequence_mixed() {
        // Mix of explicit df.sql() and plain SQL
        let explicit = crate::dsl::sql("SELECT 1");
        let result = crate::dsl::then_fn(&explicit, "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_as_named_plain_sql() {
        // Plain SQL with naming
        let result = crate::dsl::as_named("SELECT 42 as answer", "my_result");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "SQL");
        assert_eq!(fut.result_name, Some("my_result".to_string()));
    }

    #[pg_test]
    fn test_autowrap_if_all_plain_sql() {
        // All three arguments as plain SQL
        let result = crate::dsl::if_fn("SELECT true", "SELECT 'yes'", "SELECT 'no'");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "IF");
    }

    #[pg_test]
    fn test_autowrap_join_plain_sql() {
        // Both branches as plain SQL
        let result = crate::dsl::join("SELECT 1", "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "JOIN");
    }

    #[pg_test]
    fn test_autowrap_loop_plain_sql() {
        // Loop body as plain SQL
        let result = crate::dsl::loop_fn("SELECT 1", None);
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "LOOP");
    }

    #[pg_test]
    fn test_autowrap_start_plain_sql() {
        // Start with plain SQL - simplest possible durable function
        let instance_id = crate::dsl::start("SELECT 42", Some("autowrap-test"));
        assert_eq!(instance_id.len(), 8);

        // Verify instance was created
        let count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(*) FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap()
        .unwrap();
        assert_eq!(count, 1);
    }

    #[pg_test]
    fn test_autowrap_via_sql_operator() {
        // Test that SQL operator ~> works with plain strings
        let result = Spi::get_one::<String>("SELECT 'SELECT 1' ~> 'SELECT 2'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_via_as_operator() {
        // Test that SQL operator |=> works with plain strings
        let result = Spi::get_one::<String>("SELECT 'SELECT 42' |=> 'my_var'")
            .unwrap()
            .unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.result_name, Some("my_var".to_string()));
    }

    #[pg_test]
    fn test_is_durofut_detection() {
        // Test the detection logic
        let sql_node = crate::dsl::sql("SELECT 1");
        assert!(
            Durofut::is_durofut(&sql_node),
            "Should detect valid Durofut"
        );

        assert!(
            !Durofut::is_durofut("SELECT 1"),
            "Plain SQL should not be detected as Durofut"
        );
        assert!(
            !Durofut::is_durofut("{}"),
            "Empty JSON should not be Durofut"
        );
        assert!(
            !Durofut::is_durofut("{\"node_id\": \"short\"}"),
            "Invalid node_id should not be Durofut"
        );
    }

    // ========================================================================
    // Integration Tests - P0: Critical Path
    //
    // LIMITATION: pgrx test framework doesn't apply shared_preload_libraries,
    // so the background worker never starts. These tests timeout waiting for
    // functions that never get processed.
    //
    // To run E2E tests:
    //   1. cargo pgrx run pg17
    //   2. In psql, run the test SQL from USER_GUIDE.md
    //   3. Or use Docker: docker compose up -d && docker exec -it ...
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries - no background worker"]
    fn test_e2e_simple_sql() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_simple (id SERIAL PRIMARY KEY, val TEXT)")
            .unwrap();
        Spi::run("TRUNCATE test_e2e_simple").unwrap();

        // Start durable function
        let sql =
            crate::dsl::sql("INSERT INTO test_e2e_simple (val) VALUES ('hello') RETURNING id");
        let instance_id = crate::dsl::start(&sql, Some("test-e2e-simple"));

        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify result contains the inserted row
        let output = result.unwrap();
        assert!(
            output.contains("row_count"),
            "Expected row_count in output: {output}"
        );

        // Verify data in table
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_simple WHERE val = 'hello'")
            .unwrap()
            .unwrap();
        assert_eq!(count, 1, "Expected 1 row in table");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sequence() {
        // Create test table
        Spi::run(
            "CREATE TABLE IF NOT EXISTS test_e2e_seq (step INT, ts TIMESTAMPTZ DEFAULT now())",
        )
        .unwrap();
        Spi::run("TRUNCATE test_e2e_seq").unwrap();

        // Create sequence: step 1 then step 2
        let step1 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (1)");
        let step2 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (2)");
        let seq = crate::dsl::then_fn(&step1, &step2);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-seq"));

        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify both rows exist in order
        let steps: Vec<i32> = Spi::connect(|client| {
            let mut steps = Vec::new();
            if let Ok(table) = client.select("SELECT step FROM test_e2e_seq ORDER BY ts", None, &[])
            {
                for row in table {
                    if let Ok(Some(step)) = row.get::<i32>(1) {
                        steps.push(step);
                    }
                }
            }
            steps
        });

        assert_eq!(steps, vec![1, 2], "Expected steps [1, 2], got {steps:?}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_variable_substitution() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_vars (source_id INT, copied_id INT)")
            .unwrap();
        Spi::run("TRUNCATE test_e2e_vars").unwrap();
        Spi::run("INSERT INTO test_e2e_vars (source_id) VALUES (42)").unwrap();

        // Create durable function: get value, use it in next query
        let get_val = crate::dsl::sql("SELECT source_id FROM test_e2e_vars LIMIT 1");
        let named = crate::dsl::as_named(&get_val, "src");
        let use_val = crate::dsl::sql(
            "INSERT INTO test_e2e_vars (copied_id) VALUES ($src) RETURNING copied_id",
        );
        let seq = crate::dsl::then_fn(&named, &use_val);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-vars"));

        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify the value was copied
        let copied =
            Spi::get_one::<i32>("SELECT copied_id FROM test_e2e_vars WHERE copied_id IS NOT NULL")
                .unwrap();
        assert_eq!(copied, Some(42), "Expected copied_id = 42, got {copied:?}");
    }

    // ========================================================================
    // Integration Tests - P1: Important Features
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sleep() {
        let start_time = std::time::Instant::now();

        // Sleep for 2 seconds then select
        let sleep_node = crate::dsl::sleep(2);
        let sql_node = crate::dsl::sql("SELECT 'done'");
        let seq = crate::dsl::then_fn(&sleep_node, &sql_node);

        let instance_id = crate::dsl::start(&seq, Some("test-e2e-sleep"));

        // Wait for completion (with extra time for sleep)
        let result = wait_for_completion(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let elapsed = start_time.elapsed();
        assert!(
            elapsed.as_secs() >= 2,
            "Expected at least 2s sleep, got {}s",
            elapsed.as_secs()
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_true_branch() {
        let condition = crate::dsl::sql("SELECT true");
        let then_branch = crate::dsl::sql("SELECT 'yes' as result");
        let else_branch = crate::dsl::sql("SELECT 'no' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-true"));

        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(output.contains("yes"), "Expected 'yes' in output: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_false_branch() {
        let condition = crate::dsl::sql("SELECT false");
        let then_branch = crate::dsl::sql("SELECT 'yes' as result");
        let else_branch = crate::dsl::sql("SELECT 'no' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-false"));

        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(output.contains("no"), "Expected 'no' in output: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_if_numeric_condition() {
        // 0 should be falsy
        let condition = crate::dsl::sql("SELECT 0");
        let then_branch = crate::dsl::sql("SELECT 'truthy' as result");
        let else_branch = crate::dsl::sql("SELECT 'falsy' as result");
        let if_node = crate::dsl::if_fn(&condition, &then_branch, &else_branch);

        let instance_id = crate::dsl::start(&if_node, Some("test-e2e-if-zero"));

        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        let output = result.unwrap();
        assert!(
            output.contains("falsy"),
            "Expected 'falsy' for 0 condition: {output}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_join_parallel() {
        // Create test table
        Spi::run(
            "CREATE TABLE IF NOT EXISTS test_e2e_join (branch TEXT, ts TIMESTAMPTZ DEFAULT now())",
        )
        .unwrap();
        Spi::run("TRUNCATE test_e2e_join").unwrap();

        // Execute two branches in parallel
        let branch_a = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('A')");
        let branch_b = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('B')");
        let join_node = crate::dsl::join(&branch_a, &branch_b);

        let instance_id = crate::dsl::start(&join_node, Some("test-e2e-join"));

        let result = wait_for_completion(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Verify both branches executed
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join")
            .unwrap()
            .unwrap();
        assert_eq!(count, 2, "Expected 2 rows from parallel branches");

        // Verify both A and B exist
        let a_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'A'")
            .unwrap()
            .unwrap();
        let b_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'B'")
            .unwrap()
            .unwrap();
        assert_eq!(a_count, 1, "Expected branch A");
        assert_eq!(b_count, 1, "Expected branch B");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_join3() {
        let a = crate::dsl::sql("SELECT 1 as val");
        let b = crate::dsl::sql("SELECT 2 as val");
        let c = crate::dsl::sql("SELECT 3 as val");
        let join_node = crate::dsl::join3(&a, &b, &c);

        let instance_id = crate::dsl::start(&join_node, Some("test-e2e-join3"));

        let result = wait_for_completion(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Result should be an array of 3 results
        let output = result.unwrap();
        // The output is a JSON array of the branch results
        assert!(output.starts_with('['), "Expected array result: {output}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_cancel_running() {
        // Start a long-running sleep
        let sleep_node = crate::dsl::sleep(300); // 5 minutes
        let instance_id = crate::dsl::start(&sleep_node, Some("test-e2e-cancel"));

        // Give it a moment to start
        std::thread::sleep(std::time::Duration::from_millis(500));

        // Check it's running
        let _status = get_duroxide_status(&instance_id);
        // Status might be Running or still pending

        // Cancel it
        let cancel_result = crate::dsl::cancel(&instance_id, "test cancellation");
        assert!(
            cancel_result.contains("cancelled") || cancel_result.contains("cancel"),
            "Expected cancellation confirmation: {cancel_result}"
        );

        // Verify it's cancelled
        std::thread::sleep(std::time::Duration::from_millis(500));
        let final_status = get_duroxide_status(&instance_id);
        assert!(
            final_status == Some("Canceled".to_string())
                || final_status == Some("Failed".to_string()),
            "Expected Canceled status, got {final_status:?}"
        );
    }

    // ========================================================================
    // Integration Tests - P2: Monitoring & Error Handling
    // ========================================================================

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_list_instances() {
        // Start a few durable functions
        let sql1 = crate::dsl::sql("SELECT 1");
        let sql2 = crate::dsl::sql("SELECT 2");
        let id1 = crate::dsl::start(&sql1, Some("test-list-1"));
        let id2 = crate::dsl::start(&sql2, Some("test-list-2"));

        // Wait for both to complete
        let _ = wait_for_completion(&id1, 10);
        let _ = wait_for_completion(&id2, 10);

        // Query list_instances
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM df.list_instances()")
            .unwrap()
            .unwrap_or(0);
        assert!(count >= 2, "Expected at least 2 instances, got {count}");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_metrics() {
        // Just verify the function works
        let total = Spi::get_one::<i64>("SELECT total_instances FROM df.metrics()");
        assert!(total.is_ok(), "metrics() should be callable");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_instance_info() {
        let sql = crate::dsl::sql("SELECT 'info-test'");
        let instance_id = crate::dsl::start(&sql, Some("test-info-label"));

        let _ = wait_for_completion(&instance_id, 10);

        // Query instance_info
        let orch_name = Spi::get_one::<String>(&format!(
            "SELECT function_name FROM df.instance_info('{instance_id}')"
        ));

        assert!(orch_name.is_ok(), "instance_info should be callable");
        if let Ok(Some(name)) = orch_name {
            assert_eq!(name, "ExecuteWorkflow", "Expected ExecuteWorkflow function");
        }
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_instance_nodes() {
        // Create a sequence with 2 SQL nodes
        let a = crate::dsl::sql("SELECT 1");
        let b = crate::dsl::sql("SELECT 2");
        let seq = crate::dsl::then_fn(&a, &b);
        let instance_id = crate::dsl::start(&seq, None);

        let _ = wait_for_completion(&instance_id, 10);

        // Query instance_nodes - should have 3 nodes (2 SQL + 1 THEN)
        let node_count = Spi::get_one::<i64>(&format!(
            "SELECT COUNT(DISTINCT node_id) FROM df.instance_nodes('{instance_id}')"
        ))
        .unwrap()
        .unwrap_or(0);

        assert!(
            node_count >= 3,
            "Expected at least 3 nodes, got {node_count}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sql_error() {
        // Try to select from a non-existent table
        let sql = crate::dsl::sql("SELECT * FROM nonexistent_table_xyz_12345");
        let instance_id = crate::dsl::start(&sql, Some("test-sql-error"));

        let result = wait_for_completion(&instance_id, 10);

        // Should fail
        assert!(result.is_err(), "Expected function to fail");
        let err = result.unwrap_err();
        assert!(
            err.contains("Failed") || err.contains("does not exist"),
            "Expected error about non-existent table: {err}"
        );
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_status_sync() {
        let sql = crate::dsl::sql("SELECT 'sync-test'");
        let instance_id = crate::dsl::start(&sql, Some("test-status-sync"));

        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {result:?}");

        // Check PostgreSQL table status
        let pg_status = Spi::get_one::<String>(&format!(
            "SELECT status FROM df.instances WHERE id = '{instance_id}'"
        ))
        .unwrap();

        assert_eq!(
            pg_status,
            Some("completed".to_string()),
            "Expected 'completed' in PostgreSQL table, got {pg_status:?}"
        );
    }
}

/// Required by `cargo pgrx test`
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {
        // Note: Cannot use pgrx SPI here as we're outside PostgreSQL
    }

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![
            "shared_preload_libraries = 'pg_durable'",
            "pg_durable.worker_role = 'postgres'",
        ]
    }
}
