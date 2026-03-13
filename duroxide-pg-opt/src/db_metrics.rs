//! Database metrics instrumentation module.
//!
//! This module provides zero-cost instrumentation for database operations.
//! When the `db-metrics` feature is disabled, all metrics calls compile to nothing.
//!
//! # Usage
//!
//! ```rust,ignore
//! use crate::db_metrics::{record_db_call, DbOperation};
//!
//! // Record a stored procedure call
//! record_db_call(DbOperation::StoredProcedure, Some("fetch_orchestration_item"));
//!
//! // Record a SELECT query
//! record_db_call(DbOperation::Select, None);
//!
//! // Record fetch effectiveness
//! record_fetch_attempt(FetchType::Orchestration);
//! record_fetch_success(FetchType::Orchestration, 1); // 1 item fetched
//! ```
//!
//! # Metrics Exported
//!
//! When enabled, the following metrics are recorded:
//!
//! - `duroxide.db.calls` (counter): Total database calls by operation type
//!   - Labels: `operation` (sp_call, select, insert, update, delete, ddl)
//! - `duroxide.db.sp_calls` (counter): Stored procedure calls by name
//!   - Labels: `sp_name`
//! - `duroxide.db.call_duration_ms` (histogram): Duration of database calls
//!   - Labels: `operation`, `sp_name` (optional)
//! - `duroxide.fetch.attempts` (counter): Number of fetch attempts
//!   - Labels: `fetch_type` (orchestration, work_item)
//! - `duroxide.fetch.items` (counter): Number of items successfully fetched
//!   - Labels: `fetch_type` (orchestration, work_item)
//! - `duroxide.fetch.loaded` (counter): Number of fetches that returned items
//!   - Labels: `fetch_type` (orchestration, work_item)
//! - `duroxide.fetch.empty` (counter): Number of fetches that returned no items
//!   - Labels: `fetch_type` (orchestration, work_item)
//! - `duroxide.fetch.loaded_duration_ms` (histogram): Duration of fetches that returned items
//!   - Labels: `fetch_type` (orchestration, work_item)
//! - `duroxide.fetch.empty_duration_ms` (histogram): Duration of fetches that returned no items
//!   - Labels: `fetch_type` (orchestration, work_item)

/// Types of database operations for metrics classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DbOperation {
    /// Stored procedure call (SELECT schema.sp_name(...))
    StoredProcedure,
    /// SELECT query (non-SP)
    Select,
    /// INSERT statement
    Insert,
    /// UPDATE statement
    Update,
    /// DELETE statement
    Delete,
    /// DDL operations (CREATE, DROP, ALTER)
    Ddl,
}

impl DbOperation {
    /// Returns the string label for this operation type.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            DbOperation::StoredProcedure => "sp_call",
            DbOperation::Select => "select",
            DbOperation::Insert => "insert",
            DbOperation::Update => "update",
            DbOperation::Delete => "delete",
            DbOperation::Ddl => "ddl",
        }
    }
}

/// Types of fetch operations for long-poll effectiveness metrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchType {
    /// Orchestration item fetch (orchestrator dispatcher)
    Orchestration,
    /// Work item fetch (activity worker dispatcher)
    WorkItem,
}

impl FetchType {
    /// Returns the string label for this fetch type.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            FetchType::Orchestration => "orchestration",
            FetchType::WorkItem => "work_item",
        }
    }
}

/// Record a database call. Zero-cost when `db-metrics` feature is disabled.
///
/// # Arguments
///
/// * `operation` - The type of database operation
/// * `sp_name` - Optional stored procedure name (only for StoredProcedure operations)
#[cfg(feature = "db-metrics")]
#[inline]
pub fn record_db_call(operation: DbOperation, sp_name: Option<&str>) {
    use metrics::counter;

    // Record the operation counter
    counter!("duroxide.db.calls", "operation" => operation.as_str()).increment(1);

    // If it's a stored procedure, also record by SP name
    if operation == DbOperation::StoredProcedure {
        if let Some(name) = sp_name {
            counter!("duroxide.db.sp_calls", "sp_name" => name.to_string()).increment(1);
        }
    }
}

/// Record a database call. Zero-cost no-op when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
#[inline(always)]
pub fn record_db_call(_operation: DbOperation, _sp_name: Option<&str>) {
    // Compiles to nothing when db-metrics feature is disabled
}

/// Record a fetch attempt. Zero-cost when `db-metrics` feature is disabled.
///
/// This should be called every time we attempt to fetch work (orchestration or work item),
/// regardless of whether the fetch returns any items.
///
/// # Arguments
///
/// * `fetch_type` - The type of fetch operation (Orchestration or WorkItem)
#[cfg(feature = "db-metrics")]
#[inline]
pub fn record_fetch_attempt(fetch_type: FetchType) {
    use metrics::counter;
    counter!("duroxide.fetch.attempts", "fetch_type" => fetch_type.as_str()).increment(1);
}

/// Record a fetch attempt. Zero-cost no-op when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
#[inline(always)]
pub fn record_fetch_attempt(_fetch_type: FetchType) {
    // Compiles to nothing when db-metrics feature is disabled
}

/// Record successful fetch(es). Zero-cost when `db-metrics` feature is disabled.
///
/// This should be called when a fetch returns actual items. The `count` parameter
/// allows tracking batch fetches where multiple items are returned.
///
/// # Arguments
///
/// * `fetch_type` - The type of fetch operation (Orchestration or WorkItem)
/// * `count` - Number of items successfully fetched (typically 1, but can be > 1 for batches)
#[cfg(feature = "db-metrics")]
#[inline]
pub fn record_fetch_success(fetch_type: FetchType, count: u64) {
    use metrics::counter;
    counter!("duroxide.fetch.items", "fetch_type" => fetch_type.as_str()).increment(count);
}

/// Record successful fetch(es). Zero-cost no-op when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
#[inline(always)]
pub fn record_fetch_success(_fetch_type: FetchType, _count: u64) {
    // Compiles to nothing when db-metrics feature is disabled
}

/// Record a fetch result with timing. Zero-cost when `db-metrics` feature is disabled.
///
/// This is the preferred way to record fetch metrics as it separates "loaded" fetches
/// (which return items) from "empty" fetches (which return nothing). This distinction
/// is important because:
/// - Empty fetches typically execute much faster (no rows to lock/serialize)
/// - Loaded fetches have row locking, serialization, and data transfer overhead
/// - Averaging them together skews performance analysis
///
/// # Arguments
///
/// * `fetch_type` - The type of fetch operation (Orchestration or WorkItem)
/// * `items_fetched` - Number of items returned (0 for empty fetch)
/// * `duration_ms` - Duration of the fetch operation in milliseconds
#[cfg(feature = "db-metrics")]
#[inline]
pub fn record_fetch_result(fetch_type: FetchType, items_fetched: u64, duration_ms: f64) {
    use metrics::{counter, histogram};

    // Always record the attempt
    counter!("duroxide.fetch.attempts", "fetch_type" => fetch_type.as_str()).increment(1);

    if items_fetched > 0 {
        // Loaded fetch - got items
        counter!("duroxide.fetch.items", "fetch_type" => fetch_type.as_str())
            .increment(items_fetched);
        counter!("duroxide.fetch.loaded", "fetch_type" => fetch_type.as_str()).increment(1);
        histogram!("duroxide.fetch.loaded_duration_ms", "fetch_type" => fetch_type.as_str())
            .record(duration_ms);
    } else {
        // Empty fetch - no items
        counter!("duroxide.fetch.empty", "fetch_type" => fetch_type.as_str()).increment(1);
        histogram!("duroxide.fetch.empty_duration_ms", "fetch_type" => fetch_type.as_str())
            .record(duration_ms);
    }
}

/// Record a fetch result with timing. Zero-cost no-op when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
#[inline(always)]
pub fn record_fetch_result(_fetch_type: FetchType, _items_fetched: u64, _duration_ms: f64) {
    // Compiles to nothing when db-metrics feature is disabled
}

/// Record a database call with duration. Zero-cost when `db-metrics` feature is disabled.
///
/// This function records both the call counter and the duration histogram in one call.
/// Use this when you have the duration already computed (e.g., from a manual timer).
///
/// # Arguments
///
/// * `operation` - The type of database operation
/// * `sp_name` - Optional stored procedure name (only for StoredProcedure operations)
/// * `duration_ms` - Duration of the database call in milliseconds
#[cfg(feature = "db-metrics")]
#[inline]
pub fn record_db_call_with_duration(
    operation: DbOperation,
    sp_name: Option<&str>,
    duration_ms: f64,
) {
    use metrics::{counter, histogram};

    // Record the operation counter
    counter!("duroxide.db.calls", "operation" => operation.as_str()).increment(1);

    // If it's a stored procedure, also record by SP name
    if operation == DbOperation::StoredProcedure {
        if let Some(name) = sp_name {
            counter!("duroxide.db.sp_calls", "sp_name" => name.to_string()).increment(1);
            histogram!(
                "duroxide.db.call_duration_ms",
                "operation" => operation.as_str(),
                "sp_name" => name.to_string()
            )
            .record(duration_ms);
        } else {
            histogram!(
                "duroxide.db.call_duration_ms",
                "operation" => operation.as_str()
            )
            .record(duration_ms);
        }
    } else {
        histogram!(
            "duroxide.db.call_duration_ms",
            "operation" => operation.as_str()
        )
        .record(duration_ms);
    }
}

/// Record a database call with duration. Zero-cost no-op when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
#[inline(always)]
pub fn record_db_call_with_duration(
    _operation: DbOperation,
    _sp_name: Option<&str>,
    _duration_ms: f64,
) {
    // Compiles to nothing when db-metrics feature is disabled
}

/// Guard for timing database operations. Zero-cost when `db-metrics` feature is disabled.
///
/// Usage:
/// ```rust,ignore
/// let _guard = DbCallTimer::new(DbOperation::StoredProcedure, Some("fetch_work_item"));
/// // ... execute query ...
/// // Timer automatically records duration when dropped
/// ```
#[cfg(feature = "db-metrics")]
pub struct DbCallTimer {
    operation: DbOperation,
    sp_name: Option<&'static str>,
    start: std::time::Instant,
}

#[cfg(feature = "db-metrics")]
impl DbCallTimer {
    /// Create a new timer for a database operation.
    #[inline]
    pub fn new(operation: DbOperation, sp_name: Option<&'static str>) -> Self {
        Self {
            operation,
            sp_name,
            start: std::time::Instant::now(),
        }
    }
}

#[cfg(feature = "db-metrics")]
impl Drop for DbCallTimer {
    fn drop(&mut self) {
        let duration_ms = self.start.elapsed().as_secs_f64() * 1000.0;
        // Use record_db_call_with_duration to record both counter and histogram
        record_db_call_with_duration(self.operation, self.sp_name, duration_ms);
    }
}

/// Zero-cost timer stub when `db-metrics` feature is disabled.
#[cfg(not(feature = "db-metrics"))]
pub struct DbCallTimer;

#[cfg(not(feature = "db-metrics"))]
impl DbCallTimer {
    /// Create a no-op timer (compiles to nothing).
    #[inline(always)]
    pub fn new(_operation: DbOperation, _sp_name: Option<&'static str>) -> Self {
        Self
    }
}

/// Macro for convenient instrumentation of a database call block.
/// Zero-cost when `db-metrics` feature is disabled.
///
/// # Example
///
/// ```rust,ignore
/// let result = instrument_db_call!(StoredProcedure, "fetch_work_item", {
///     sqlx::query("SELECT schema.fetch_work_item($1)")
///         .bind(worker_id)
///         .fetch_optional(&*self.pool)
///         .await
/// });
/// ```
#[macro_export]
macro_rules! instrument_db_call {
    ($op:ident, $sp_name:expr, $body:expr) => {{
        #[cfg(feature = "db-metrics")]
        {
            let _timer = $crate::db_metrics::DbCallTimer::new(
                $crate::db_metrics::DbOperation::$op,
                Some($sp_name),
            );
            $crate::db_metrics::record_db_call(
                $crate::db_metrics::DbOperation::$op,
                Some($sp_name),
            );
            $body
        }
        #[cfg(not(feature = "db-metrics"))]
        {
            $body
        }
    }};
    ($op:ident, $body:expr) => {{
        #[cfg(feature = "db-metrics")]
        {
            let _timer =
                $crate::db_metrics::DbCallTimer::new($crate::db_metrics::DbOperation::$op, None);
            $crate::db_metrics::record_db_call($crate::db_metrics::DbOperation::$op, None);
            $body
        }
        #[cfg(not(feature = "db-metrics"))]
        {
            $body
        }
    }};
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_db_operation_as_str() {
        assert_eq!(DbOperation::StoredProcedure.as_str(), "sp_call");
        assert_eq!(DbOperation::Select.as_str(), "select");
        assert_eq!(DbOperation::Insert.as_str(), "insert");
        assert_eq!(DbOperation::Update.as_str(), "update");
        assert_eq!(DbOperation::Delete.as_str(), "delete");
        assert_eq!(DbOperation::Ddl.as_str(), "ddl");
    }

    #[test]
    fn test_record_db_call_compiles() {
        // This test just ensures the functions compile and can be called
        record_db_call(DbOperation::StoredProcedure, Some("test_sp"));
        record_db_call(DbOperation::Select, None);
    }

    #[test]
    fn test_timer_compiles() {
        let _timer = DbCallTimer::new(DbOperation::Select, None);
        let _timer2 = DbCallTimer::new(DbOperation::StoredProcedure, Some("test_sp"));
    }
}
