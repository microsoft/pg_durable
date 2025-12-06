//! pg_durable - Durable PostgreSQL workflows
//!
//! This extension provides durable, fault-tolerant workflow execution within PostgreSQL
//! using the Duroxide runtime for orchestration persistence.

use pgrx::prelude::*;

// Module declarations
pub mod types;
pub mod dsl;
pub mod runtime;
pub mod monitoring;

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
-- Table to store workflow nodes (SQL steps, THEN chains, etc.)
CREATE TABLE IF NOT EXISTS durable.nodes (
    id UUID PRIMARY KEY,
    instance_id VARCHAR(8),
    node_type TEXT NOT NULL,
    query TEXT,
    result_name TEXT,
    left_node UUID,
    right_node UUID,
    status TEXT DEFAULT 'pending',
    result JSONB,
    error TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table to store workflow instances
CREATE TABLE IF NOT EXISTS durable.instances (
    id VARCHAR(8) PRIMARY KEY,
    label TEXT,
    root_node UUID NOT NULL,
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

    // DSL Node Creation Tests
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

    // Instance Management Tests
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
        let instance_id = crate::dsl::start(&fut, Some("my-test-workflow"));
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

    // SQL Operator Tests
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

    // Edge Cases
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
}

/// Required by `cargo pgrx test`
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec!["shared_preload_libraries = 'pg_durable'"]
    }
}
