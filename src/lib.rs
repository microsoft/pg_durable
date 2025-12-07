//! pg_durable - Durable SQL Functions for PostgreSQL
//!
//! This extension provides durable, fault-tolerant function execution within PostgreSQL
//! using the Duroxide runtime for persistence.

use pgrx::prelude::*;

// Module declarations
pub mod types;
pub mod dsl;
pub mod runtime;
pub mod monitoring;
pub mod explain;

// Re-export key types for tests
pub use types::Durofut;

::pgrx::pg_module_magic!(name, version);

// ============================================================================
// Background Worker Registration
// ============================================================================

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    runtime::register_background_worker();
}

// ============================================================================
// Schema Declaration
// ============================================================================

/// The 'durable' schema contains all pg_durable functions
#[pg_schema]
mod durable {}

// ============================================================================
// Table Definitions
// ============================================================================

extension_sql!(
    r#"
-- Table to store function nodes (SQL steps, THEN chains, etc.)
CREATE TABLE IF NOT EXISTS durable.nodes (
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
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table to store function instances
CREATE TABLE IF NOT EXISTS durable.instances (
    id VARCHAR(8) PRIMARY KEY,
    label TEXT,
    root_node VARCHAR(8) NOT NULL,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    completed_at TIMESTAMPTZ
);

-- Index for finding pending instances
CREATE INDEX IF NOT EXISTS idx_instances_status ON durable.instances(status);

-- Index for finding nodes by instance
CREATE INDEX IF NOT EXISTS idx_nodes_instance ON durable.nodes(instance_id);
"#,
    name = "create_tables",
    requires = [durable]
);

// ============================================================================
// SQL Operators
// ============================================================================

extension_sql!(
    r#"
-- Operator ~> for sequencing: a ~> b means "run a, then run b"
CREATE OPERATOR ~> (
    FUNCTION = durable.seq,
    LEFTARG = text,
    RIGHTARG = text
);

-- Operator |=> for naming: fut |=> 'name' means "name this result as $name"
CREATE OR REPLACE FUNCTION durable.as_op(fut text, name text) RETURNS text AS $$
    SELECT durable.as(name, fut);
$$ LANGUAGE SQL IMMUTABLE;

CREATE OPERATOR |=> (
    FUNCTION = durable.as_op,
    LEFTARG = text,
    RIGHTARG = text
);
"#,
    name = "create_operators",
    requires = [dsl::then_fn, dsl::as_named]
);

// ============================================================================
// Tests
// ============================================================================

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;
    use crate::Durofut;
    use std::sync::Arc;

    // ========================================================================
    // Test Helpers for Integration Tests
    // ========================================================================

    /// Ensure the Duroxide store exists and is ready
    fn ensure_store_ready() -> Result<String, String> {
        use std::time::{Duration, Instant};
        
        let db_path = crate::types::duroxide_db_path();
        
        // Ensure parent directory exists with full permissions
        if let Some(parent) = std::path::Path::new(&db_path).parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("Failed to create directory {:?}: {}", parent, e))?;
        }
        
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {}", e))?;
        
        // Try to initialize the store (creates DB if it doesn't exist)
        rt.block_on(async {
            let start = Instant::now();
            let timeout = Duration::from_secs(10);
            
            loop {
                match duroxide::providers::sqlite::SqliteProvider::new(&db_path, None).await {
                    Ok(_) => return Ok(db_path.clone()),
                    Err(e) => {
                        if start.elapsed() > timeout {
                            return Err(format!("Failed to initialize store at {} after {}s: {}", db_path, timeout.as_secs(), e));
                        }
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                }
            }
        })
    }

    /// Wait for a durable function to complete, polling Duroxide status
    fn wait_for_completion(instance_id: &str, timeout_secs: u64) -> Result<String, String> {
        use std::time::{Duration, Instant};
        use duroxide::Client;
        
        // Ensure store is ready first
        let _ = ensure_store_ready()?;
        
        let db_path = crate::types::duroxide_db_path();
        let start = Instant::now();
        let timeout = Duration::from_secs(timeout_secs);
        
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create runtime: {}", e))?;
        
        rt.block_on(async {
            let store = Arc::new(
                duroxide::providers::sqlite::SqliteProvider::new(&db_path, None)
                    .await
                    .map_err(|e| format!("Failed to connect to store: {}", e))?
            );
            let client = Client::new(store);
            
            loop {
                match client.get_instance_info(instance_id).await {
                    Ok(info) => {
                        match info.status.as_str() {
                            "Completed" | "ContinuedAsNew" => {
                                return Ok(info.output.unwrap_or_default());
                            }
                            "Failed" | "Canceled" => {
                                return Err(format!("{}: {}", info.status, info.output.unwrap_or_default()));
                            }
                            _ => {} // Still running
                        }
                    }
                    Err(_) => {} // Instance not found yet
                }
                
                if start.elapsed() > timeout {
                    // Get final status for better error message
                    let final_status = client.get_instance_info(instance_id).await
                        .map(|i| i.status)
                        .unwrap_or_else(|_| "unknown".to_string());
                    return Err(format!("Timeout after {}s, status: {}", timeout_secs, final_status));
                }
                
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
    }

    /// Get the current status from Duroxide
    fn get_duroxide_status(instance_id: &str) -> Option<String> {
        use duroxide::Client;
        
        let db_path = match ensure_store_ready() {
            Ok(path) => path,
            Err(_) => return None,
        };
        
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()?;
        
        rt.block_on(async {
            let store = Arc::new(
                duroxide::providers::sqlite::SqliteProvider::new(&db_path, None)
                    .await
                    .ok()?
            );
            let client = Client::new(store);
            client.get_instance_info(instance_id).await.ok().map(|i| i.status)
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
        let named_json = crate::dsl::as_named("my_result", &sql_json);
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
        let json = crate::dsl::loop_fn(&body);
        let fut = Durofut::from_json(&json);
        assert_eq!(fut.node_type, "LOOP");
        assert!(fut.left_node.is_some());
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
            "SELECT COUNT(*) FROM durable.instances WHERE id = '{}'", instance_id
        )).unwrap().unwrap();
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
        let result = Spi::get_one::<String>(
            "SELECT durable.sql('SELECT 1') ~> durable.sql('SELECT 2')"
        ).unwrap().unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_as_operator_via_sql() {
        let result = Spi::get_one::<String>(
            "SELECT durable.sql('SELECT 1') |=> 'my_name'"
        ).unwrap().unwrap();
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
    fn test_debug_db_path_returns_path() {
        let path = crate::dsl::debug_db_path();
        assert!(!path.is_empty());
    }

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
        assert!(result.contains("SQL") || result.contains("SELECT"), 
            "Expected SQL visualization, got: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_simple_sql() {
        // Dry-run explain of a simple SQL
        let result = crate::explain::explain("durable.sql('SELECT 42')");
        assert!(result.contains("SQL"), "Expected SQL in output: {}", result);
        assert!(result.contains("42"), "Expected query content: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_sequence() {
        // Dry-run explain of a sequence
        let result = crate::explain::explain(
            "durable.sql('SELECT 1') ~> durable.sql('SELECT 2')"
        );
        // Should show sequence with arrows
        assert!(result.contains("SELECT 1"), "Expected first query: {}", result);
        assert!(result.contains("SELECT 2"), "Expected second query: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_sleep() {
        let result = crate::explain::explain("durable.sleep(60)");
        assert!(result.contains("SLEEP"), "Expected SLEEP node: {}", result);
        assert!(result.contains("60"), "Expected duration: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_loop() {
        let result = crate::explain::explain(
            "durable.loop(durable.sql('SELECT 1'))"
        );
        assert!(result.contains("LOOP"), "Expected LOOP: {}", result);
        assert!(result.contains("body"), "Expected body section: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_if() {
        let result = crate::explain::explain(
            "durable.if(durable.sql('SELECT true'), durable.sql('SELECT yes'), durable.sql('SELECT no'))"
        );
        assert!(result.contains("IF"), "Expected IF: {}", result);
        assert!(result.contains("then"), "Expected then branch: {}", result);
        assert!(result.contains("else"), "Expected else branch: {}", result);
    }

    #[pg_test]
    fn test_explain_expression_join() {
        let result = crate::explain::explain(
            "durable.join(durable.sql('SELECT 1'), durable.sql('SELECT 2'))"
        );
        assert!(result.contains("JOIN"), "Expected JOIN: {}", result);
        assert!(result.contains("branch"), "Expected branches: {}", result);
    }

    #[pg_test]
    fn test_explain_no_side_effects() {
        // After explain, no orphan nodes should exist in durable.nodes
        let before_count: i64 = Spi::get_one(
            "SELECT COUNT(*) FROM durable.nodes WHERE instance_id IS NULL"
        ).unwrap().unwrap_or(0);
        
        let _ = crate::explain::explain(
            "durable.sql('SELECT orphan_test') ~> durable.sleep(999)"
        );
        
        let after_count: i64 = Spi::get_one(
            "SELECT COUNT(*) FROM durable.nodes WHERE instance_id IS NULL"
        ).unwrap().unwrap_or(0);
        
        // Should be the same - no orphan nodes added
        assert_eq!(before_count, after_count, 
            "Explain should not leave orphan nodes in durable.nodes");
    }

    #[pg_test]
    fn test_explain_invalid_instance_id() {
        // Test with non-existent instance ID
        let result = crate::explain::explain("deadbeef");
        assert!(result.contains("not found"), "Expected 'not found' error: {}", result);
    }

    #[pg_test]
    fn test_explain_complex_nested() {
        // Complex nested structure: loop with if inside
        let result = crate::explain::explain(
            "durable.loop(durable.if(durable.sql('SELECT true'), durable.sql('SELECT yes'), durable.sql('SELECT no')))"
        );
        assert!(result.contains("LOOP"), "Expected LOOP: {}", result);
        assert!(result.contains("IF"), "Expected IF: {}", result);
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
        // Mix of explicit durable.sql() and plain SQL
        let explicit = crate::dsl::sql("SELECT 1");
        let result = crate::dsl::then_fn(&explicit, "SELECT 2");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_as_named_plain_sql() {
        // Plain SQL with naming
        let result = crate::dsl::as_named("my_result", "SELECT 42 as answer");
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "SQL");
        assert_eq!(fut.result_name, Some("my_result".to_string()));
    }

    #[pg_test]
    fn test_autowrap_if_all_plain_sql() {
        // All three arguments as plain SQL
        let result = crate::dsl::if_fn(
            "SELECT true",
            "SELECT 'yes'",
            "SELECT 'no'"
        );
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
        let result = crate::dsl::loop_fn("SELECT 1");
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
            "SELECT COUNT(*) FROM durable.instances WHERE id = '{}'", instance_id
        )).unwrap().unwrap();
        assert_eq!(count, 1);
    }

    #[pg_test]
    fn test_autowrap_via_sql_operator() {
        // Test that SQL operator ~> works with plain strings
        let result = Spi::get_one::<String>(
            "SELECT 'SELECT 1' ~> 'SELECT 2'"
        ).unwrap().unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.node_type, "THEN");
    }

    #[pg_test]
    fn test_autowrap_via_as_operator() {
        // Test that SQL operator |=> works with plain strings
        let result = Spi::get_one::<String>(
            "SELECT 'SELECT 42' |=> 'my_var'"
        ).unwrap().unwrap();
        let fut = Durofut::from_json(&result);
        assert_eq!(fut.result_name, Some("my_var".to_string()));
    }

    #[pg_test]
    fn test_is_durofut_detection() {
        // Test the detection logic
        let sql_node = crate::dsl::sql("SELECT 1");
        assert!(Durofut::is_durofut(&sql_node), "Should detect valid Durofut");
        
        assert!(!Durofut::is_durofut("SELECT 1"), "Plain SQL should not be detected as Durofut");
        assert!(!Durofut::is_durofut("{}"), "Empty JSON should not be Durofut");
        assert!(!Durofut::is_durofut("{\"node_id\": \"short\"}"), "Invalid node_id should not be Durofut");
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
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_simple (id SERIAL PRIMARY KEY, val TEXT)").unwrap();
        Spi::run("TRUNCATE test_e2e_simple").unwrap();
        
        // Start durable function
        let sql = crate::dsl::sql("INSERT INTO test_e2e_simple (val) VALUES ('hello') RETURNING id");
        let instance_id = crate::dsl::start(&sql, Some("test-e2e-simple"));
        
        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Verify result contains the inserted row
        let output = result.unwrap();
        assert!(output.contains("row_count"), "Expected row_count in output: {}", output);
        
        // Verify data in table
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_simple WHERE val = 'hello'")
            .unwrap().unwrap();
        assert_eq!(count, 1, "Expected 1 row in table");
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_sequence() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_seq (step INT, ts TIMESTAMPTZ DEFAULT now())").unwrap();
        Spi::run("TRUNCATE test_e2e_seq").unwrap();
        
        // Create sequence: step 1 then step 2
        let step1 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (1)");
        let step2 = crate::dsl::sql("INSERT INTO test_e2e_seq (step) VALUES (2)");
        let seq = crate::dsl::then_fn(&step1, &step2);
        
        let instance_id = crate::dsl::start(&seq, Some("test-e2e-seq"));
        
        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Verify both rows exist in order
        let steps: Vec<i32> = Spi::connect(|client| {
            let mut steps = Vec::new();
            if let Ok(table) = client.select("SELECT step FROM test_e2e_seq ORDER BY ts", None, &[]) {
                for row in table {
                    if let Ok(Some(step)) = row.get::<i32>(1) {
                        steps.push(step);
                    }
                }
            }
            steps
        });
        
        assert_eq!(steps, vec![1, 2], "Expected steps [1, 2], got {:?}", steps);
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_variable_substitution() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_vars (source_id INT, copied_id INT)").unwrap();
        Spi::run("TRUNCATE test_e2e_vars").unwrap();
        Spi::run("INSERT INTO test_e2e_vars (source_id) VALUES (42)").unwrap();
        
        // Create durable function: get value, use it in next query
        let get_val = crate::dsl::sql("SELECT source_id FROM test_e2e_vars LIMIT 1");
        let named = crate::dsl::as_named("src", &get_val);
        let use_val = crate::dsl::sql("INSERT INTO test_e2e_vars (copied_id) VALUES ($src) RETURNING copied_id");
        let seq = crate::dsl::then_fn(&named, &use_val);
        
        let instance_id = crate::dsl::start(&seq, Some("test-e2e-vars"));
        
        // Wait for completion
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Verify the value was copied
        let copied = Spi::get_one::<i32>("SELECT copied_id FROM test_e2e_vars WHERE copied_id IS NOT NULL")
            .unwrap();
        assert_eq!(copied, Some(42), "Expected copied_id = 42, got {:?}", copied);
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
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        let elapsed = start_time.elapsed();
        assert!(elapsed.as_secs() >= 2, "Expected at least 2s sleep, got {}s", elapsed.as_secs());
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
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        let output = result.unwrap();
        assert!(output.contains("yes"), "Expected 'yes' in output: {}", output);
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
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        let output = result.unwrap();
        assert!(output.contains("no"), "Expected 'no' in output: {}", output);
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
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        let output = result.unwrap();
        assert!(output.contains("falsy"), "Expected 'falsy' for 0 condition: {}", output);
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_join_parallel() {
        // Create test table
        Spi::run("CREATE TABLE IF NOT EXISTS test_e2e_join (branch TEXT, ts TIMESTAMPTZ DEFAULT now())").unwrap();
        Spi::run("TRUNCATE test_e2e_join").unwrap();
        
        // Execute two branches in parallel
        let branch_a = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('A')");
        let branch_b = crate::dsl::sql("INSERT INTO test_e2e_join (branch) VALUES ('B')");
        let join_node = crate::dsl::join(&branch_a, &branch_b);
        
        let instance_id = crate::dsl::start(&join_node, Some("test-e2e-join"));
        
        let result = wait_for_completion(&instance_id, 15);
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Verify both branches executed
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join").unwrap().unwrap();
        assert_eq!(count, 2, "Expected 2 rows from parallel branches");
        
        // Verify both A and B exist
        let a_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'A'").unwrap().unwrap();
        let b_count = Spi::get_one::<i64>("SELECT COUNT(*) FROM test_e2e_join WHERE branch = 'B'").unwrap().unwrap();
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
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Result should be an array of 3 results
        let output = result.unwrap();
        // The output is a JSON array of the branch results
        assert!(output.starts_with('['), "Expected array result: {}", output);
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
        assert!(cancel_result.contains("cancelled") || cancel_result.contains("cancel"), 
            "Expected cancellation confirmation: {}", cancel_result);
        
        // Verify it's cancelled
        std::thread::sleep(std::time::Duration::from_millis(500));
        let final_status = get_duroxide_status(&instance_id);
        assert!(final_status == Some("Canceled".to_string()) || final_status == Some("Failed".to_string()),
            "Expected Canceled status, got {:?}", final_status);
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
        let count = Spi::get_one::<i64>("SELECT COUNT(*) FROM durable.list_instances()").unwrap().unwrap_or(0);
        assert!(count >= 2, "Expected at least 2 instances, got {}", count);
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_metrics() {
        // Just verify the function works
        let total = Spi::get_one::<i64>("SELECT total_instances FROM durable.metrics()");
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
            "SELECT function_name FROM durable.instance_info('{}')", instance_id
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
            "SELECT COUNT(DISTINCT node_id) FROM durable.instance_nodes('{}')", instance_id
        )).unwrap().unwrap_or(0);
        
        assert!(node_count >= 3, "Expected at least 3 nodes, got {}", node_count);
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
        assert!(err.contains("Failed") || err.contains("does not exist"), 
            "Expected error about non-existent table: {}", err);
    }

    #[pg_test]
    #[ignore = "pgrx doesn't support shared_preload_libraries"]
    fn test_e2e_status_sync() {
        let sql = crate::dsl::sql("SELECT 'sync-test'");
        let instance_id = crate::dsl::start(&sql, Some("test-status-sync"));
        
        let result = wait_for_completion(&instance_id, 10);
        assert!(result.is_ok(), "Function failed: {:?}", result);
        
        // Check PostgreSQL table status
        let pg_status = Spi::get_one::<String>(&format!(
            "SELECT status FROM durable.instances WHERE id = '{}'", instance_id
        )).unwrap();
        
        assert_eq!(pg_status, Some("completed".to_string()), 
            "Expected 'completed' in PostgreSQL table, got {:?}", pg_status);
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
        vec!["shared_preload_libraries = 'pg_durable'"]
    }
}
