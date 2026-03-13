use anyhow::Result;
use chrono::{TimeZone, Utc};
use duroxide::providers::{
    DeleteInstanceResult, DispatcherCapabilityFilter, ExecutionInfo,
    ExecutionMetadata, InstanceFilter, InstanceInfo, OrchestrationItem, Provider, ProviderAdmin,
    ProviderError, PruneOptions, PruneResult, QueueDepths, ScheduledActivityIdentifier,
    SessionFetchConfig, SystemMetrics, WorkItem,
};
use duroxide::{Event, EventKind};
use sqlx::{postgres::PgPoolOptions, Error as SqlxError, PgPool};
use std::sync::Arc;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::sleep;
use tracing::{debug, error, info, instrument, warn};

use crate::db_metrics::{record_fetch_result, DbCallTimer, DbOperation, FetchType};
use crate::migrations::MigrationRunner;
use crate::notifier::{LongPollConfig, Notifier};

#[cfg(feature = "test-fault-injection")]
use crate::fault_injection::FaultInjector;

/// Controls how schema migrations are handled during provider initialization.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum MigrationPolicy {
    /// Run all migrations, creating the schema and tables from scratch if needed.
    #[default]
    ApplyAll,

    /// Verify that the schema exists and is at the expected migration version.
    /// Performs no DDL.
    VerifyOnly,
}

/// Configuration for constructing a [`PostgresProvider`].
///
/// Use `Default::default()` and override specific fields.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    /// PostgreSQL schema name. Default: "public".
    pub schema_name: Option<String>,

    /// Long-polling configuration. Default: enabled.
    pub long_poll: LongPollConfig,

    /// Migration policy. Default: [`MigrationPolicy::ApplyAll`].
    pub migration_policy: MigrationPolicy,
}

impl Default for ProviderConfig {
    fn default() -> Self {
        Self {
            schema_name: None,
            long_poll: LongPollConfig::default(),
            migration_policy: MigrationPolicy::default(),
        }
    }
}

fn validate_schema_name(schema_name: &str) -> Result<()> {
    // Identifiers cannot be bound as SQL parameters, so we restrict schema names
    // to a safe subset and interpolate directly.
    //
    // PostgreSQL's full identifier grammar is broader; we intentionally keep
    // this conservative.
    let mut chars = schema_name.chars();
    let Some(first) = chars.next() else {
        anyhow::bail!("schema_name cannot be empty");
    };

    let is_first_ok = first == '_' || first.is_ascii_alphabetic();
    if !is_first_ok {
        anyhow::bail!(
            "Invalid schema_name '{}': must match [A-Za-z_][A-Za-z0-9_]*",
            schema_name
        );
    }

    for ch in chars {
        if !(ch == '_' || ch.is_ascii_alphanumeric()) {
            anyhow::bail!(
                "Invalid schema_name '{}': must match [A-Za-z_][A-Za-z0-9_]*",
                schema_name
            );
        }
    }

    Ok(())
}

/// PostgreSQL-based provider for Duroxide durable orchestrations.
///
/// Implements the [`Provider`] and [`ProviderAdmin`] traits from Duroxide,
/// storing orchestration state, history, and work queues in PostgreSQL.
///
/// # Example
///
/// ```rust,no_run
/// use duroxide_pg_opt::PostgresProvider;
///
/// # async fn example() -> anyhow::Result<()> {
/// // Connect using DATABASE_URL or explicit connection string
/// let provider = PostgresProvider::new("postgres://localhost/mydb").await?;
///
/// // Or use a custom schema for isolation
/// let provider = PostgresProvider::new_with_schema(
///     "postgres://localhost/mydb",
///     Some("my_app"),
/// ).await?;
/// # Ok(())
/// # }
/// ```
pub struct PostgresProvider {
    pool: Arc<PgPool>,
    schema_name: String,

    // Long-poll infrastructure (None if disabled)
    orch_notify: Option<Arc<Notify>>,
    worker_notify: Option<Arc<Notify>>,
    notifier_handle: Option<JoinHandle<()>>,

    // Fault injection (only present when feature is enabled)
    #[cfg(feature = "test-fault-injection")]
    fault_injector: Option<Arc<FaultInjector>>,
}

impl PostgresProvider {
    /// Create a new provider with default settings (long-poll enabled).
    pub async fn new(database_url: &str) -> Result<Self> {
        Self::new_with_config(database_url, ProviderConfig::default()).await
    }

    /// Create a new provider with a custom schema.
    pub async fn new_with_schema(database_url: &str, schema_name: Option<&str>) -> Result<Self> {
        let mut config = ProviderConfig::default();
        config.schema_name = schema_name.map(|s| s.to_string());
        Self::new_with_config(database_url, config).await
    }

    /// Create a new provider with full configuration.
    pub async fn new_with_config(database_url: &str, config: ProviderConfig) -> Result<Self> {
        let max_connections = std::env::var("DUROXIDE_PG_POOL_MAX")
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(10);

        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .min_connections(1)
            .acquire_timeout(std::time::Duration::from_secs(30))
            .connect(database_url)
            .await?;

        let schema_name = config
            .schema_name
            .as_deref()
            .unwrap_or("public")
            .to_string();
        validate_schema_name(&schema_name)?;

        let migration_runner = MigrationRunner::new(Arc::new(pool.clone()), schema_name.clone());
        match config.migration_policy {
            MigrationPolicy::ApplyAll => {
                migration_runner.migrate().await?;
            }
            MigrationPolicy::VerifyOnly => {
                migration_runner.verify().await?;
            }
        }

        // Always reject unknown migrations (schema ahead of code).
        migration_runner.check_no_unknown_migrations().await?;

        // Start notifier thread if long-polling is enabled
        let (orch_notify, worker_notify, notifier_handle) = if config.long_poll.enabled {
            let orch_notify = Arc::new(Notify::new());
            let worker_notify = Arc::new(Notify::new());

            let mut notifier = Notifier::new(
                pool.clone(),
                schema_name.clone(),
                orch_notify.clone(),
                worker_notify.clone(),
                config.long_poll.clone(),
            )
            .await?;

            let handle = tokio::spawn(async move {
                notifier.run().await;
            });

            info!(
                target = "duroxide::providers::postgres",
                schema = %schema_name,
                "Long-polling enabled"
            );

            (Some(orch_notify), Some(worker_notify), Some(handle))
        } else {
            debug!(
                target = "duroxide::providers::postgres",
                schema = %schema_name,
                "Long-polling disabled"
            );
            (None, None, None)
        };

        Ok(Self {
            pool: Arc::new(pool),
            schema_name,
            orch_notify,
            worker_notify,
            notifier_handle,
            #[cfg(feature = "test-fault-injection")]
            fault_injector: None,
        })
    }

    /// Create a new provider with full configuration options.
    pub async fn new_with_options(
        database_url: &str,
        schema_name: Option<&str>,
        config: LongPollConfig,
    ) -> Result<Self> {
        let mut pc = ProviderConfig::default();
        pc.schema_name = schema_name.map(|s| s.to_string());
        pc.long_poll = config;
        Self::new_with_config(database_url, pc).await
    }

    /// Create a new provider with fault injection for testing.
    ///
    /// This constructor allows injecting faults to test resilience scenarios.
    /// The FaultInjector can be used to disable the notifier thread.
    #[cfg(feature = "test-fault-injection")]
    pub async fn new_with_fault_injection(
        database_url: &str,
        schema_name: Option<&str>,
        config: LongPollConfig,
        fault_injector: Arc<FaultInjector>,
    ) -> Result<Self> {
        let max_connections = std::env::var("DUROXIDE_PG_POOL_MAX")
            .ok()
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(10);

        // Check fault injection: if notifier is disabled, skip starting it
        let notifier_disabled = fault_injector.is_notifier_disabled();

        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .min_connections(1)
            .acquire_timeout(std::time::Duration::from_secs(30))
            .connect(database_url)
            .await?;

        let schema_name = schema_name.unwrap_or("public").to_string();
        validate_schema_name(&schema_name)?;

        // Run migrations to initialize schema
        let migration_runner = MigrationRunner::new(Arc::new(pool.clone()), schema_name.clone());
        migration_runner.migrate().await?;

        // Reject unknown migrations (schema ahead of code).
        migration_runner.check_no_unknown_migrations().await?;

        // Start notifier thread if long-polling is enabled AND not disabled by fault injection
        let (orch_notify, worker_notify, notifier_handle, fi) =
            if config.enabled && !notifier_disabled {
                let orch_notify = Arc::new(Notify::new());
                let worker_notify = Arc::new(Notify::new());

                let mut notifier = Notifier::new_with_fault_injection(
                    pool.clone(),
                    schema_name.clone(),
                    orch_notify.clone(),
                    worker_notify.clone(),
                    config.clone(),
                    fault_injector.clone(),
                )
                .await?;

                let handle = tokio::spawn(async move {
                    notifier.run().await;
                });

                info!(
                    target = "duroxide::providers::postgres",
                    schema = %schema_name,
                    "Long-polling enabled"
                );

                (
                    Some(orch_notify),
                    Some(worker_notify),
                    Some(handle),
                    Some(fault_injector),
                )
            } else {
                if notifier_disabled {
                    warn!(
                        target = "duroxide::providers::postgres",
                        schema = %schema_name,
                        "Long-polling disabled by fault injection"
                    );
                } else {
                    debug!(
                        target = "duroxide::providers::postgres",
                        schema = %schema_name,
                        "Long-polling disabled"
                    );
                }
                (None, None, None, Some(fault_injector))
            };

        Ok(Self {
            pool: Arc::new(pool),
            schema_name,
            orch_notify,
            worker_notify,
            notifier_handle,
            fault_injector: fi,
        })
    }

    /// Get current timestamp in milliseconds (Unix epoch) - static version.
    ///
    /// This is the base time calculation without any fault injection adjustments.
    fn now_millis_base() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64
    }

    /// Get current timestamp in milliseconds, with optional clock skew adjustment.
    ///
    /// When fault injection is enabled and a clock skew is configured, the skew
    /// is added to the current time. This allows simulating nodes with clocks
    /// that are ahead (positive skew) or behind (negative skew).
    ///
    /// When fault injection is disabled, this is zero-cost and equivalent to
    /// `now_millis_base()`.
    #[cfg(feature = "test-fault-injection")]
    fn now_millis(&self) -> i64 {
        let base = Self::now_millis_base();
        if let Some(ref fi) = self.fault_injector {
            base + fi.get_clock_skew_ms()
        } else {
            base
        }
    }

    /// Get current timestamp in milliseconds (no fault injection).
    #[cfg(not(feature = "test-fault-injection"))]
    fn now_millis(&self) -> i64 {
        Self::now_millis_base()
    }

    /// Get schema-qualified table name
    fn table_name(&self, table: &str) -> String {
        format!("{}.{}", self.schema_name, table)
    }

    /// Get the database pool (for testing)
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Get the schema name (for testing)
    pub fn schema_name(&self) -> &str {
        &self.schema_name
    }

    /// Convert sqlx::Error to ProviderError with proper classification
    fn sqlx_to_provider_error(operation: &str, e: SqlxError) -> ProviderError {
        match e {
            SqlxError::Database(ref db_err) => {
                // PostgreSQL error codes
                let code_opt = db_err.code();
                let code = code_opt.as_deref();
                if code == Some("40P01") {
                    // Deadlock detected
                    ProviderError::retryable(operation, format!("Deadlock detected: {e}"))
                } else if code == Some("40001") {
                    // Serialization failure - permanent error (transaction conflict, not transient)
                    ProviderError::permanent(operation, format!("Serialization failure: {e}"))
                } else if code == Some("23505") {
                    // Unique constraint violation (duplicate event)
                    ProviderError::permanent(operation, format!("Duplicate detected: {e}"))
                } else if code == Some("23503") {
                    // Foreign key constraint violation
                    ProviderError::permanent(operation, format!("Foreign key violation: {e}"))
                } else {
                    ProviderError::permanent(operation, format!("Database error: {e}"))
                }
            }
            SqlxError::PoolClosed | SqlxError::PoolTimedOut => {
                ProviderError::retryable(operation, format!("Connection pool error: {e}"))
            }
            SqlxError::Io(_) => ProviderError::retryable(operation, format!("I/O error: {e}")),
            _ => ProviderError::permanent(operation, format!("Unexpected error: {e}")),
        }
    }

    /// Clean up schema after tests (drops all tables and optionally the schema)
    ///
    /// **SAFETY**: Never drops the "public" schema itself, only tables within it.
    /// Only drops the schema if it's a custom schema (not "public").
    pub async fn cleanup_schema(&self) -> Result<()> {
        // Call the stored procedure to drop all tables
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("cleanup_schema"));
        sqlx::query(&format!("SELECT {}.cleanup_schema()", self.schema_name))
            .execute(&*self.pool)
            .await?;

        // SAFETY: Never drop the "public" schema - it's a PostgreSQL system schema
        // Only drop custom schemas created for testing
        if self.schema_name != "public" {
            let _timer = DbCallTimer::new(DbOperation::Ddl, None);
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS {} CASCADE",
                self.schema_name
            ))
            .execute(&*self.pool)
            .await?;
        } else {
            // Explicit safeguard: we only drop tables from public schema, never the schema itself
            // This ensures we don't accidentally drop the default PostgreSQL schema
        }

        Ok(())
    }

    /// Internal fetch logic for orchestration items with retries
    async fn do_fetch_orchestration_item(
        &self,
        lock_timeout: Duration,
        filter: Option<&DispatcherCapabilityFilter>,
    ) -> Result<Option<(OrchestrationItem, String, u32)>, ProviderError> {
        let start = std::time::Instant::now();

        const MAX_RETRIES: u32 = 3;
        const RETRY_DELAY_MS: u64 = 50;

        // Convert Duration to milliseconds
        let lock_timeout_ms = lock_timeout.as_millis() as i64;
        let mut _last_error: Option<ProviderError> = None;

        // Extract version filter parameters
        let (min_packed, max_packed): (Option<i64>, Option<i64>) = if let Some(cap_filter) = filter
        {
            match cap_filter.supported_duroxide_versions.first() {
                Some(range) => {
                    let min = range.min.major as i64 * 1_000_000
                        + range.min.minor as i64 * 1_000
                        + range.min.patch as i64;
                    let max = range.max.major as i64 * 1_000_000
                        + range.max.minor as i64 * 1_000
                        + range.max.patch as i64;
                    (Some(min), Some(max))
                }
                None => {
                    // Empty supported_duroxide_versions = "supports nothing" → no candidate.
                    return Ok(None);
                }
            }
        } else {
            (None, None)
        };

        for attempt in 0..=MAX_RETRIES {
            let now_ms = self.now_millis();

            let _timer = DbCallTimer::new(
                DbOperation::StoredProcedure,
                Some("fetch_orchestration_item"),
            );
            #[allow(clippy::type_complexity)]
            let result: Result<
                Option<(
                    String,
                    String,
                    String,
                    i64,
                    serde_json::Value,
                    serde_json::Value,
                    String,
                    i32,
                )>,
                SqlxError,
            > = sqlx::query_as(&format!(
                "SELECT * FROM {}.fetch_orchestration_item($1, $2, $3, $4)",
                self.schema_name
            ))
            .bind(now_ms)
            .bind(lock_timeout_ms)
            .bind(min_packed)
            .bind(max_packed)
            .fetch_optional(&*self.pool)
            .await;

            let row = match result {
                Ok(r) => r,
                Err(e) => {
                    let provider_err = Self::sqlx_to_provider_error("fetch_orchestration_item", e);
                    if provider_err.is_retryable() && attempt < MAX_RETRIES {
                        warn!(
                            target = "duroxide::providers::postgres",
                            operation = "fetch_orchestration_item",
                            attempt = attempt + 1,
                            error = %provider_err,
                            "Retryable error, will retry"
                        );
                        _last_error = Some(provider_err);
                        sleep(std::time::Duration::from_millis(
                            RETRY_DELAY_MS * (attempt as u64 + 1),
                        ))
                        .await;
                        continue;
                    }
                    return Err(provider_err);
                }
            };

            if let Some((
                instance_id,
                orchestration_name,
                orchestration_version,
                execution_id,
                history_json,
                messages_json,
                lock_token,
                attempt_count,
            )) = row
            {
                let (history, history_error) =
                    match serde_json::from_value::<Vec<Event>>(history_json) {
                        Ok(h) => (h, None),
                        Err(e) => {
                            let error_msg = format!("Failed to deserialize history: {e}");
                            tracing::warn!(
                                target = "duroxide::providers::postgres",
                                instance = %instance_id,
                                error = %error_msg,
                                "History deserialization failed, returning item with history_error"
                            );
                            (vec![], Some(error_msg))
                        }
                    };

                let messages: Vec<WorkItem> =
                    serde_json::from_value(messages_json).map_err(|e| {
                        ProviderError::permanent(
                            "fetch_orchestration_item",
                            format!("Failed to deserialize messages: {e}"),
                        )
                    })?;

                let duration_ms = start.elapsed().as_secs_f64() * 1000.0;
                debug!(
                    target = "duroxide::providers::postgres",
                    operation = "fetch_orchestration_item",
                    instance_id = %instance_id,
                    execution_id = execution_id,
                    message_count = messages.len(),
                    history_count = history.len(),
                    attempt_count = attempt_count,
                    duration_ms = duration_ms,
                    attempts = attempt + 1,
                    "Fetched orchestration item via stored procedure"
                );

                // Record loaded fetch with timing
                record_fetch_result(FetchType::Orchestration, 1, duration_ms);

                return Ok(Some((
                    OrchestrationItem {
                        instance: instance_id,
                        orchestration_name,
                        execution_id: execution_id as u64,
                        version: orchestration_version,
                        history,
                        messages,
                        history_error,
                    },
                    lock_token,
                    attempt_count as u32,
                )));
            }

            // Query succeeded but no work found - return immediately
            // (retries are only for error recovery, not for polling)
            break;
        }

        // Record empty fetch with timing
        let duration_ms = start.elapsed().as_secs_f64() * 1000.0;
        record_fetch_result(FetchType::Orchestration, 0, duration_ms);

        Ok(None)
    }

    /// Internal fetch logic for work items
    async fn do_fetch_work_item(
        &self,
        lock_timeout: Duration,
        session: Option<&SessionFetchConfig>,
    ) -> Result<Option<(WorkItem, String, u32)>, ProviderError> {
        let start = std::time::Instant::now();

        // Convert Duration to milliseconds
        let lock_timeout_ms = lock_timeout.as_millis() as i64;

        // Extract session parameters
        let (owner_id, session_lock_timeout_ms): (Option<&str>, Option<i64>) = match session {
            Some(config) => (
                Some(&config.owner_id),
                Some(config.lock_timeout.as_millis() as i64),
            ),
            None => (None, None),
        };

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("fetch_work_item"));
        // Returns: work_item, lock_token, attempt_count
        let row = match sqlx::query_as::<_, (String, String, i32)>(&format!(
            "SELECT * FROM {}.fetch_work_item($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(self.now_millis())
        .bind(lock_timeout_ms)
        .bind(owner_id)
        .bind(session_lock_timeout_ms)
        .fetch_optional(&*self.pool)
        .await
        {
            Ok(row) => row,
            Err(e) => {
                return Err(Self::sqlx_to_provider_error("fetch_work_item", e));
            }
        };

        let (work_item_json, lock_token, attempt_count) = match row {
            Some(row) => row,
            None => {
                // Record empty fetch with timing
                let duration_ms = start.elapsed().as_secs_f64() * 1000.0;
                record_fetch_result(FetchType::WorkItem, 0, duration_ms);
                return Ok(None);
            }
        };

        let work_item: WorkItem = serde_json::from_str(&work_item_json).map_err(|e| {
            ProviderError::permanent(
                "fetch_work_item",
                format!("Failed to deserialize worker item: {e}"),
            )
        })?;

        let duration_ms = start.elapsed().as_secs_f64() * 1000.0;

        // Extract instance for logging - different work item types have different structures
        let instance_id = match &work_item {
            WorkItem::ActivityExecute { instance, .. } => instance.as_str(),
            WorkItem::ActivityCompleted { instance, .. } => instance.as_str(),
            WorkItem::ActivityFailed { instance, .. } => instance.as_str(),
            WorkItem::StartOrchestration { instance, .. } => instance.as_str(),
            WorkItem::TimerFired { instance, .. } => instance.as_str(),
            WorkItem::ExternalRaised { instance, .. } => instance.as_str(),
            WorkItem::CancelInstance { instance, .. } => instance.as_str(),
            WorkItem::ContinueAsNew { instance, .. } => instance.as_str(),
            WorkItem::SubOrchCompleted {
                parent_instance, ..
            } => parent_instance.as_str(),
            WorkItem::SubOrchFailed {
                parent_instance, ..
            } => parent_instance.as_str(),
            WorkItem::QueueMessage { instance, .. } => instance.as_str(),
        };

        debug!(
            target = "duroxide::providers::postgres",
            operation = "fetch_work_item",
            instance_id = %instance_id,
            attempt_count = attempt_count,
            duration_ms = duration_ms,
            "Fetched activity work item via stored procedure"
        );

        // Record loaded fetch with timing
        record_fetch_result(FetchType::WorkItem, 1, duration_ms);

        Ok(Some((work_item, lock_token, attempt_count as u32)))
    }
}

impl Drop for PostgresProvider {
    fn drop(&mut self) {
        // Abort the notifier thread when the provider is dropped
        if let Some(handle) = self.notifier_handle.take() {
            handle.abort();
        }
    }
}

#[async_trait::async_trait]
impl Provider for PostgresProvider {
    fn name(&self) -> &str {
        env!("CARGO_PKG_NAME")
    }

    fn version(&self) -> &str {
        env!("CARGO_PKG_VERSION")
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn fetch_orchestration_item(
        &self,
        lock_timeout: Duration,
        poll_timeout: Duration,
        filter: Option<&DispatcherCapabilityFilter>,
    ) -> Result<Option<(OrchestrationItem, String, u32)>, ProviderError> {
        // Fast path: Duration::ZERO means "do not wait".
        // Avoid long-poll notifier bookkeeping to keep behavior deterministic
        // and reduce contention/overhead on hot paths.
        if poll_timeout.is_zero() {
            return self
                .do_fetch_orchestration_item(lock_timeout, filter)
                .await;
        }

        // Long-poll pattern: register interest BEFORE checking to avoid race
        if let Some(notify) = &self.orch_notify {
            // Step 1: Create the notification future and enable it
            // enable() registers interest immediately, so any notify_one()
            // after this point will wake us up (or store a permit if we're not waiting yet).
            let notified = notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            // Step 2: Try to fetch
            let result = self
                .do_fetch_orchestration_item(lock_timeout, filter)
                .await?;
            if result.is_some() {
                return Ok(result);
            }

            // Step 3: No work - wait for wake signal or timeout
            // Because we called enable() BEFORE checking, any notify_one()
            // that happened after step 1 will still wake us up.
            tokio::select! {
                _ = &mut notified => {
                    // Woken by notifier (NOTIFY or timer) - fetch now
                    return self.do_fetch_orchestration_item(lock_timeout, filter).await;
                }
                _ = tokio::time::sleep(poll_timeout) => {
                    // Timeout - return None, let runtime handle idle sleep
                    return Ok(None);
                }
            }
        }

        // Long-poll disabled - try once and return immediately (old behavior)
        self.do_fetch_orchestration_item(lock_timeout, filter).await
    }

    #[instrument(skip(self), fields(lock_token = %lock_token, execution_id = execution_id), target = "duroxide::providers::postgres")]
    async fn ack_orchestration_item(
        &self,
        lock_token: &str,
        execution_id: u64,
        history_delta: Vec<Event>,
        worker_items: Vec<WorkItem>,
        orchestrator_items: Vec<WorkItem>,
        metadata: ExecutionMetadata,
        cancelled_activities: Vec<ScheduledActivityIdentifier>,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();

        const MAX_RETRIES: u32 = 3;
        const RETRY_DELAY_MS: u64 = 50;

        let mut history_delta_payload = Vec::with_capacity(history_delta.len());
        for event in &history_delta {
            if event.event_id() == 0 {
                return Err(ProviderError::permanent(
                    "ack_orchestration_item",
                    "event_id must be set by runtime",
                ));
            }

            let event_json = serde_json::to_string(event).map_err(|e| {
                ProviderError::permanent(
                    "ack_orchestration_item",
                    format!("Failed to serialize event: {e}"),
                )
            })?;

            let event_type = format!("{event:?}")
                .split('{')
                .next()
                .unwrap_or("Unknown")
                .trim()
                .to_string();

            history_delta_payload.push(serde_json::json!({
                "event_id": event.event_id(),
                "event_type": event_type,
                "event_data": event_json,
            }));
        }

        let history_delta_json = serde_json::Value::Array(history_delta_payload);

        let worker_items_json = serde_json::to_value(&worker_items).map_err(|e| {
            ProviderError::permanent(
                "ack_orchestration_item",
                format!("Failed to serialize worker items: {e}"),
            )
        })?;

        let orchestrator_items_json = serde_json::to_value(&orchestrator_items).map_err(|e| {
            ProviderError::permanent(
                "ack_orchestration_item",
                format!("Failed to serialize orchestrator items: {e}"),
            )
        })?;

        // Scan history_delta for the last CustomStatusUpdated event
        let (custom_status_action, custom_status_value): (Option<&str>, Option<&str>) = {
            let mut last_status: Option<&Option<String>> = None;
            for event in &history_delta {
                if let EventKind::CustomStatusUpdated { ref status } = event.kind {
                    last_status = Some(status);
                }
            }
            match last_status {
                Some(Some(s)) => (Some("set"), Some(s.as_str())),
                Some(None) => (Some("clear"), None),
                None => (None, None),
            }
        };

        let metadata_json = serde_json::json!({
            "orchestration_name": metadata.orchestration_name,
            "orchestration_version": metadata.orchestration_version,
            "status": metadata.status,
            "output": metadata.output,
            "parent_instance_id": metadata.parent_instance_id,
            "pinned_duroxide_version": metadata.pinned_duroxide_version.as_ref().map(|v| {
                serde_json::json!({
                    "major": v.major,
                    "minor": v.minor,
                    "patch": v.patch,
                })
            }),
            "custom_status_action": custom_status_action,
            "custom_status_value": custom_status_value,
        });

        // Serialize cancelled_activities for lock-stealing cancellation
        // Each entry needs execution_id and activity_id. The instance_id is constrained
        // by v_instance_id (derived from lock_token in the stored procedure).
        //
        // Note: We intentionally allow cancelled_activities with different execution_ids
        // than the current p_execution_id. The DELETE will simply be a no-op for
        // non-matching entries, making the operation idempotent.
        let cancelled_activities_json = serde_json::Value::Array(
            cancelled_activities
                .iter()
                .map(|sa| {
                    serde_json::json!({
                        "execution_id": sa.execution_id,
                        "activity_id": sa.activity_id
                    })
                })
                .collect(),
        );

        let now_ms = self.now_millis();

        for attempt in 0..=MAX_RETRIES {
            let _timer =
                DbCallTimer::new(DbOperation::StoredProcedure, Some("ack_orchestration_item"));
            let result = sqlx::query(&format!(
                "SELECT {}.ack_orchestration_item($1, $2, $3, $4, $5, $6, $7, $8)",
                self.schema_name
            ))
            .bind(lock_token)
            .bind(now_ms)
            .bind(execution_id as i64)
            .bind(&history_delta_json)
            .bind(&worker_items_json)
            .bind(&orchestrator_items_json)
            .bind(&metadata_json)
            .bind(&cancelled_activities_json)
            .execute(&*self.pool)
            .await;

            match result {
                Ok(_) => {
                    let duration_ms = start.elapsed().as_millis() as u64;
                    debug!(
                        target = "duroxide::providers::postgres",
                        operation = "ack_orchestration_item",
                        execution_id = execution_id,
                        history_count = history_delta.len(),
                        worker_items_count = worker_items.len(),
                        orchestrator_items_count = orchestrator_items.len(),
                        duration_ms = duration_ms,
                        attempts = attempt + 1,
                        "Acknowledged orchestration item via stored procedure"
                    );
                    return Ok(());
                }
                Err(e) => {
                    // Check for permanent errors first
                    if let SqlxError::Database(db_err) = &e {
                        if db_err.message().contains("Invalid lock token") {
                            return Err(ProviderError::permanent(
                                "ack_orchestration_item",
                                "Invalid lock token",
                            ));
                        }
                    } else if e.to_string().contains("Invalid lock token") {
                        return Err(ProviderError::permanent(
                            "ack_orchestration_item",
                            "Invalid lock token",
                        ));
                    }

                    let provider_err = Self::sqlx_to_provider_error("ack_orchestration_item", e);
                    if provider_err.is_retryable() && attempt < MAX_RETRIES {
                        warn!(
                            target = "duroxide::providers::postgres",
                            operation = "ack_orchestration_item",
                            attempt = attempt + 1,
                            error = %provider_err,
                            "Retryable error, will retry"
                        );
                        sleep(std::time::Duration::from_millis(
                            RETRY_DELAY_MS * (attempt as u64 + 1),
                        ))
                        .await;
                        continue;
                    }
                    return Err(provider_err);
                }
            }
        }

        // Should never reach here, but just in case
        Ok(())
    }
    #[instrument(skip(self), fields(lock_token = %lock_token), target = "duroxide::providers::postgres")]
    async fn abandon_orchestration_item(
        &self,
        lock_token: &str,
        delay: Option<Duration>,
        ignore_attempt: bool,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();
        let now_ms = self.now_millis();
        let delay_param: Option<i64> = delay.map(|d| d.as_millis() as i64);

        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("abandon_orchestration_item"),
        );
        let instance_id = match sqlx::query_scalar::<_, String>(&format!(
            "SELECT {}.abandon_orchestration_item($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(lock_token)
        .bind(now_ms)
        .bind(delay_param)
        .bind(ignore_attempt)
        .fetch_one(&*self.pool)
        .await
        {
            Ok(instance_id) => instance_id,
            Err(e) => {
                if let SqlxError::Database(db_err) = &e {
                    if db_err.message().contains("Invalid lock token") {
                        return Err(ProviderError::permanent(
                            "abandon_orchestration_item",
                            "Invalid lock token",
                        ));
                    }
                } else if e.to_string().contains("Invalid lock token") {
                    return Err(ProviderError::permanent(
                        "abandon_orchestration_item",
                        "Invalid lock token",
                    ));
                }

                return Err(Self::sqlx_to_provider_error(
                    "abandon_orchestration_item",
                    e,
                ));
            }
        };

        let duration_ms = start.elapsed().as_millis() as u64;
        debug!(
            target = "duroxide::providers::postgres",
            operation = "abandon_orchestration_item",
            instance_id = %instance_id,
            delay_ms = delay.map(|d| d.as_millis() as u64),
            ignore_attempt = ignore_attempt,
            duration_ms = duration_ms,
            "Abandoned orchestration item via stored procedure"
        );

        Ok(())
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn read(&self, instance: &str) -> Result<Vec<Event>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("fetch_history"));
        let event_data_rows: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT out_event_data FROM {}.fetch_history($1)",
            self.schema_name
        ))
        .bind(instance)
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("read", e))?;

        Ok(event_data_rows
            .into_iter()
            .filter_map(|event_data| serde_json::from_str::<Event>(&event_data).ok())
            .collect())
    }

    #[instrument(skip(self), fields(instance = %instance, execution_id = execution_id), target = "duroxide::providers::postgres")]
    async fn append_with_execution(
        &self,
        instance: &str,
        execution_id: u64,
        new_events: Vec<Event>,
    ) -> Result<(), ProviderError> {
        if new_events.is_empty() {
            return Ok(());
        }

        let mut events_payload = Vec::with_capacity(new_events.len());
        for event in &new_events {
            if event.event_id() == 0 {
                error!(
                    target = "duroxide::providers::postgres",
                    operation = "append_with_execution",
                    error_type = "validation_error",
                    instance_id = %instance,
                    execution_id = execution_id,
                    "event_id must be set by runtime"
                );
                return Err(ProviderError::permanent(
                    "append_with_execution",
                    "event_id must be set by runtime",
                ));
            }

            let event_json = serde_json::to_string(event).map_err(|e| {
                ProviderError::permanent(
                    "append_with_execution",
                    format!("Failed to serialize event: {e}"),
                )
            })?;

            let event_type = format!("{event:?}")
                .split('{')
                .next()
                .unwrap_or("Unknown")
                .trim()
                .to_string();

            events_payload.push(serde_json::json!({
                "event_id": event.event_id(),
                "event_type": event_type,
                "event_data": event_json,
            }));
        }

        let events_json = serde_json::Value::Array(events_payload);
        let now_ms = self.now_millis();

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("append_history"));
        sqlx::query(&format!(
            "SELECT {}.append_history($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(instance)
        .bind(execution_id as i64)
        .bind(events_json)
        .bind(now_ms)
        .execute(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("append_with_execution", e))?;

        debug!(
            target = "duroxide::providers::postgres",
            operation = "append_with_execution",
            instance_id = %instance,
            execution_id = execution_id,
            event_count = new_events.len(),
            "Appended history events via stored procedure"
        );

        Ok(())
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn enqueue_for_worker(&self, item: WorkItem) -> Result<(), ProviderError> {
        let work_item = serde_json::to_string(&item).map_err(|e| {
            ProviderError::permanent(
                "enqueue_worker_work",
                format!("Failed to serialize work item: {e}"),
            )
        })?;

        let now_ms = self.now_millis();

        // Extract session_id for ActivityExecute items
        let session_id = match &item {
            WorkItem::ActivityExecute { session_id, .. } => session_id.clone(),
            _ => None,
        };

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("enqueue_worker_work"));
        sqlx::query(&format!(
            "SELECT {}.enqueue_worker_work($1, $2, $3)",
            self.schema_name
        ))
        .bind(work_item)
        .bind(now_ms)
        .bind(&session_id)
        .execute(&*self.pool)
        .await
        .map_err(|e| {
            error!(
                target = "duroxide::providers::postgres",
                operation = "enqueue_worker_work",
                error_type = "database_error",
                error = %e,
                "Failed to enqueue worker work"
            );
            Self::sqlx_to_provider_error("enqueue_worker_work", e)
        })?;

        Ok(())
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn fetch_work_item(
        &self,
        lock_timeout: Duration,
        poll_timeout: Duration,
        session: Option<&SessionFetchConfig>,
    ) -> Result<Option<(WorkItem, String, u32)>, ProviderError> {
        // Fast path: Duration::ZERO means "do not wait".
        // Avoid long-poll notifier bookkeeping to keep behavior deterministic
        // and reduce contention/overhead on hot paths.
        if poll_timeout.is_zero() {
            return self.do_fetch_work_item(lock_timeout, session).await;
        }

        // Long-poll pattern: register interest BEFORE checking to avoid race
        if let Some(notify) = &self.worker_notify {
            // Step 1: Create the notification future and enable it
            let notified = notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();

            // Step 2: Try to fetch
            let result = self.do_fetch_work_item(lock_timeout, session).await?;
            if result.is_some() {
                return Ok(result);
            }

            // Step 3: No work - wait for wake signal or timeout
            tokio::select! {
                _ = &mut notified => {
                    // Woken by notifier (NOTIFY or timer) - fetch now
                    return self.do_fetch_work_item(lock_timeout, session).await;
                }
                _ = tokio::time::sleep(poll_timeout) => {
                    // Timeout - return None, let runtime handle idle sleep
                    return Ok(None);
                }
            }
        }

        // Long-poll disabled - try once and return immediately (old behavior)
        self.do_fetch_work_item(lock_timeout, session).await
    }

    #[instrument(skip(self), fields(token = %token), target = "duroxide::providers::postgres")]
    async fn ack_work_item(
        &self,
        token: &str,
        completion: Option<WorkItem>,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();

        // Extract instance ID and serialize completion if provided
        let (instance_id, completion_json): (Option<String>, Option<String>) = match &completion {
            Some(WorkItem::ActivityCompleted { instance, .. })
            | Some(WorkItem::ActivityFailed { instance, .. }) => {
                let json = serde_json::to_string(&completion).map_err(|e| {
                    ProviderError::permanent(
                        "ack_worker",
                        format!("Failed to serialize completion: {e}"),
                    )
                })?;
                (Some(instance.clone()), Some(json))
            }
            Some(_) => {
                error!(
                    target = "duroxide::providers::postgres",
                    operation = "ack_worker",
                    error_type = "invalid_completion_type",
                    "Invalid completion work item type"
                );
                return Err(ProviderError::permanent(
                    "ack_worker",
                    "Invalid completion work item type",
                ));
            }
            None => (None, None), // Orchestration terminal/missing - just delete, don't enqueue
        };

        let now_ms = self.now_millis();

        // Call stored procedure to atomically delete worker item and optionally enqueue completion
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("ack_worker"));
        sqlx::query(&format!(
            "SELECT {}.ack_worker($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(token)
        .bind(&instance_id)
        .bind(&completion_json)
        .bind(now_ms)
        .execute(&*self.pool)
        .await
        .map_err(|e| {
            if e.to_string().contains("Worker queue item not found") {
                error!(
                    target = "duroxide::providers::postgres",
                    operation = "ack_worker",
                    error_type = "worker_item_not_found",
                    token = %token,
                    "Worker queue item not found or already processed"
                );
                ProviderError::permanent(
                    "ack_worker",
                    "Worker queue item not found or already processed",
                )
            } else {
                Self::sqlx_to_provider_error("ack_worker", e)
            }
        })?;

        let duration_ms = start.elapsed().as_millis() as u64;
        debug!(
            target = "duroxide::providers::postgres",
            operation = "ack_worker",
            instance_id = ?instance_id,
            completion_provided = completion.is_some(),
            duration_ms = duration_ms,
            "Acknowledged worker item"
        );

        Ok(())
    }

    #[instrument(skip(self), fields(token = %token), target = "duroxide::providers::postgres")]
    async fn renew_work_item_lock(
        &self,
        token: &str,
        extend_for: Duration,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();

        // Get current time from application for consistent time reference
        let now_ms = self.now_millis();

        // Convert Duration to milliseconds for the stored procedure to avoid truncation
        let extend_ms = extend_for.as_millis() as i64;

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("renew_work_item_lock"));
        // In duroxide 0.1.8, renew returns () and fails if entry missing (lock stolen)
        // The stored procedure will raise an exception if the lock token is invalid or entry deleted
        match sqlx::query(&format!(
            "SELECT {}.renew_work_item_lock($1, $2, $3)",
            self.schema_name
        ))
        .bind(token)
        .bind(now_ms)
        .bind(extend_ms)
        .execute(&*self.pool)
        .await
        {
            Ok(_) => {
                let duration_ms = start.elapsed().as_millis() as u64;
                debug!(
                    target = "duroxide::providers::postgres",
                    operation = "renew_work_item_lock",
                    token = %token,
                    extend_for_ms = extend_ms,
                    duration_ms = duration_ms,
                    "Renew work item lock completed successfully"
                );
                Ok(())
            }
            Err(e) => {
                if let SqlxError::Database(db_err) = &e {
                    if db_err.message().contains("Lock token invalid") {
                        return Err(ProviderError::permanent(
                            "renew_work_item_lock",
                            "Lock token invalid, expired, or already acked",
                        ));
                    }
                } else if e.to_string().contains("Lock token invalid") {
                    return Err(ProviderError::permanent(
                        "renew_work_item_lock",
                        "Lock token invalid, expired, or already acked",
                    ));
                }

                Err(Self::sqlx_to_provider_error("renew_work_item_lock", e))
            }
        }
    }

    #[instrument(skip(self), fields(token = %token), target = "duroxide::providers::postgres")]
    async fn abandon_work_item(
        &self,
        token: &str,
        delay: Option<Duration>,
        ignore_attempt: bool,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();
        let now_ms = self.now_millis();
        let delay_param: Option<i64> = delay.map(|d| d.as_millis() as i64);

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("abandon_work_item"));
        match sqlx::query(&format!(
            "SELECT {}.abandon_work_item($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(token)
        .bind(now_ms)
        .bind(delay_param)
        .bind(ignore_attempt)
        .execute(&*self.pool)
        .await
        {
            Ok(_) => {
                let duration_ms = start.elapsed().as_millis() as u64;
                debug!(
                    target = "duroxide::providers::postgres",
                    operation = "abandon_work_item",
                    token = %token,
                    delay_ms = delay.map(|d| d.as_millis() as u64),
                    ignore_attempt = ignore_attempt,
                    duration_ms = duration_ms,
                    "Abandoned work item via stored procedure"
                );
                Ok(())
            }
            Err(e) => {
                if let SqlxError::Database(db_err) = &e {
                    if db_err.message().contains("Invalid lock token")
                        || db_err.message().contains("already acked")
                    {
                        return Err(ProviderError::permanent(
                            "abandon_work_item",
                            "Invalid lock token or already acked",
                        ));
                    }
                } else if e.to_string().contains("Invalid lock token")
                    || e.to_string().contains("already acked")
                {
                    return Err(ProviderError::permanent(
                        "abandon_work_item",
                        "Invalid lock token or already acked",
                    ));
                }

                Err(Self::sqlx_to_provider_error("abandon_work_item", e))
            }
        }
    }

    #[instrument(skip(self), fields(token = %token), target = "duroxide::providers::postgres")]
    async fn renew_orchestration_item_lock(
        &self,
        token: &str,
        extend_for: Duration,
    ) -> Result<(), ProviderError> {
        let start = std::time::Instant::now();

        // Get current time from application for consistent time reference
        let now_ms = self.now_millis();

        // Convert Duration to milliseconds for the stored procedure to avoid truncation
        let extend_ms = extend_for.as_millis() as i64;

        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("renew_orchestration_item_lock"),
        );
        match sqlx::query(&format!(
            "SELECT {}.renew_orchestration_item_lock($1, $2, $3)",
            self.schema_name
        ))
        .bind(token)
        .bind(now_ms)
        .bind(extend_ms)
        .execute(&*self.pool)
        .await
        {
            Ok(_) => {
                let duration_ms = start.elapsed().as_millis() as u64;
                debug!(
                    target = "duroxide::providers::postgres",
                    operation = "renew_orchestration_item_lock",
                    token = %token,
                extend_for_ms = extend_ms,
                    duration_ms = duration_ms,
                    "Orchestration item lock renewed successfully"
                );
                Ok(())
            }
            Err(e) => {
                if let SqlxError::Database(db_err) = &e {
                    if db_err.message().contains("Lock token invalid")
                        || db_err.message().contains("expired")
                        || db_err.message().contains("already released")
                    {
                        return Err(ProviderError::permanent(
                            "renew_orchestration_item_lock",
                            "Lock token invalid, expired, or already released",
                        ));
                    }
                } else if e.to_string().contains("Lock token invalid")
                    || e.to_string().contains("expired")
                    || e.to_string().contains("already released")
                {
                    return Err(ProviderError::permanent(
                        "renew_orchestration_item_lock",
                        "Lock token invalid, expired, or already released",
                    ));
                }

                Err(Self::sqlx_to_provider_error(
                    "renew_orchestration_item_lock",
                    e,
                ))
            }
        }
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn enqueue_for_orchestrator(
        &self,
        item: WorkItem,
        delay: Option<Duration>,
    ) -> Result<(), ProviderError> {
        let work_item = serde_json::to_string(&item).map_err(|e| {
            ProviderError::permanent(
                "enqueue_orchestrator_work",
                format!("Failed to serialize work item: {e}"),
            )
        })?;

        // Extract instance ID from WorkItem enum
        let instance_id = match &item {
            WorkItem::StartOrchestration { instance, .. }
            | WorkItem::ActivityCompleted { instance, .. }
            | WorkItem::ActivityFailed { instance, .. }
            | WorkItem::TimerFired { instance, .. }
            | WorkItem::ExternalRaised { instance, .. }
            | WorkItem::CancelInstance { instance, .. }
            | WorkItem::ContinueAsNew { instance, .. }
            | WorkItem::QueueMessage { instance, .. } => instance,
            WorkItem::SubOrchCompleted {
                parent_instance, ..
            }
            | WorkItem::SubOrchFailed {
                parent_instance, ..
            } => parent_instance,
            WorkItem::ActivityExecute { .. } => {
                return Err(ProviderError::permanent(
                    "enqueue_orchestrator_work",
                    "ActivityExecute should go to worker queue, not orchestrator queue",
                ));
            }
        };

        // Determine visible_at: use max of fire_at_ms (for TimerFired) and delay
        let now_ms = self.now_millis();

        let visible_at_ms = if let WorkItem::TimerFired { fire_at_ms, .. } = &item {
            if *fire_at_ms > 0 {
                // Take max of fire_at_ms and delay (if provided)
                if let Some(delay) = delay {
                    std::cmp::max(*fire_at_ms, now_ms as u64 + delay.as_millis() as u64)
                } else {
                    *fire_at_ms
                }
            } else {
                // fire_at_ms is 0, use delay or NOW()
                delay
                    .map(|d| now_ms as u64 + d.as_millis() as u64)
                    .unwrap_or(now_ms as u64)
            }
        } else {
            // Non-timer item: use delay or NOW()
            delay
                .map(|d| now_ms as u64 + d.as_millis() as u64)
                .unwrap_or(now_ms as u64)
        };

        let visible_at = Utc
            .timestamp_millis_opt(visible_at_ms as i64)
            .single()
            .ok_or_else(|| {
                ProviderError::permanent(
                    "enqueue_orchestrator_work",
                    "Invalid visible_at timestamp",
                )
            })?;

        // ⚠️ CRITICAL: DO NOT extract orchestration metadata - instance creation happens via ack_orchestration_item metadata
        // Pass NULL for orchestration_name, orchestration_version, execution_id parameters

        // Call stored procedure to enqueue work
        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("enqueue_orchestrator_work"),
        );
        sqlx::query(&format!(
            "SELECT {}.enqueue_orchestrator_work($1, $2, $3, $4, $5, $6, $7)",
            self.schema_name
        ))
        .bind(instance_id)
        .bind(&work_item)
        .bind(visible_at)
        .bind(now_ms) // p_now_ms - for created_at
        .bind::<Option<String>>(None) // orchestration_name - NULL
        .bind::<Option<String>>(None) // orchestration_version - NULL
        .bind::<Option<i64>>(None) // execution_id - NULL
        .execute(&*self.pool)
        .await
        .map_err(|e| {
            error!(
                target = "duroxide::providers::postgres",
                operation = "enqueue_orchestrator_work",
                error_type = "database_error",
                error = %e,
                instance_id = %instance_id,
                "Failed to enqueue orchestrator work"
            );
            Self::sqlx_to_provider_error("enqueue_orchestrator_work", e)
        })?;

        debug!(
            target = "duroxide::providers::postgres",
            operation = "enqueue_orchestrator_work",
            instance_id = %instance_id,
            delay_ms = delay.map(|d| d.as_millis() as u64),
            "Enqueued orchestrator work"
        );

        Ok(())
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn read_with_execution(
        &self,
        instance: &str,
        execution_id: u64,
    ) -> Result<Vec<Event>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::Select, None);
        let event_data_rows: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT event_data FROM {} WHERE instance_id = $1 AND execution_id = $2 ORDER BY event_id",
            self.table_name("history")
        ))
        .bind(instance)
        .bind(execution_id as i64)
        .fetch_all(&*self.pool)
        .await
        .ok()
        .unwrap_or_default();

        Ok(event_data_rows
            .into_iter()
            .filter_map(|event_data| serde_json::from_str::<Event>(&event_data).ok())
            .collect())
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn renew_session_lock(
        &self,
        owner_ids: &[&str],
        extend_for: Duration,
        idle_timeout: Duration,
    ) -> Result<usize, ProviderError> {
        if owner_ids.is_empty() {
            return Ok(0);
        }

        let now_ms = self.now_millis();
        let extend_ms = extend_for.as_millis() as i64;
        let idle_timeout_ms = idle_timeout.as_millis() as i64;
        let owner_ids_vec: Vec<&str> = owner_ids.to_vec();

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("renew_session_lock"));
        let result = sqlx::query_scalar::<_, i64>(&format!(
            "SELECT {}.renew_session_lock($1, $2, $3, $4)",
            self.schema_name
        ))
        .bind(&owner_ids_vec)
        .bind(now_ms)
        .bind(extend_ms)
        .bind(idle_timeout_ms)
        .fetch_one(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("renew_session_lock", e))?;

        debug!(
            target = "duroxide::providers::postgres",
            operation = "renew_session_lock",
            owner_count = owner_ids.len(),
            sessions_renewed = result,
            "Session locks renewed"
        );

        Ok(result as usize)
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn cleanup_orphaned_sessions(
        &self,
        _idle_timeout: Duration,
    ) -> Result<usize, ProviderError> {
        let now_ms = self.now_millis();

        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("cleanup_orphaned_sessions"),
        );
        let result = sqlx::query_scalar::<_, i64>(&format!(
            "SELECT {}.cleanup_orphaned_sessions($1)",
            self.schema_name
        ))
        .bind(now_ms)
        .fetch_one(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("cleanup_orphaned_sessions", e))?;

        debug!(
            target = "duroxide::providers::postgres",
            operation = "cleanup_orphaned_sessions",
            sessions_cleaned = result,
            "Orphaned sessions cleaned up"
        );

        Ok(result as usize)
    }

    fn as_management_capability(&self) -> Option<&dyn ProviderAdmin> {
        Some(self)
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn get_custom_status(
        &self,
        instance: &str,
        last_seen_version: u64,
    ) -> Result<Option<(Option<String>, u64)>, ProviderError> {
        let row = sqlx::query_as::<_, (Option<String>, i64)>(&format!(
            "SELECT * FROM {}.get_custom_status($1, $2)",
            self.schema_name
        ))
        .bind(instance)
        .bind(last_seen_version as i64)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("get_custom_status", e))?;

        match row {
            Some((custom_status, version)) => Ok(Some((custom_status, version as u64))),
            None => Ok(None),
        }
    }
}

#[async_trait::async_trait]
impl ProviderAdmin for PostgresProvider {
    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn list_instances(&self) -> Result<Vec<String>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("list_instances"));
        sqlx::query_scalar(&format!(
            "SELECT instance_id FROM {}.list_instances()",
            self.schema_name
        ))
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("list_instances", e))
    }

    #[instrument(skip(self), fields(status = %status), target = "duroxide::providers::postgres")]
    async fn list_instances_by_status(&self, status: &str) -> Result<Vec<String>, ProviderError> {
        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("list_instances_by_status"),
        );
        sqlx::query_scalar(&format!(
            "SELECT instance_id FROM {}.list_instances_by_status($1)",
            self.schema_name
        ))
        .bind(status)
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("list_instances_by_status", e))
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn list_executions(&self, instance: &str) -> Result<Vec<u64>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("list_executions"));
        let execution_ids: Vec<i64> = sqlx::query_scalar(&format!(
            "SELECT execution_id FROM {}.list_executions($1)",
            self.schema_name
        ))
        .bind(instance)
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("list_executions", e))?;

        Ok(execution_ids.into_iter().map(|id| id as u64).collect())
    }

    #[instrument(skip(self), fields(instance = %instance, execution_id = execution_id), target = "duroxide::providers::postgres")]
    async fn read_history_with_execution_id(
        &self,
        instance: &str,
        execution_id: u64,
    ) -> Result<Vec<Event>, ProviderError> {
        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("fetch_history_with_execution"),
        );
        let event_data_rows: Vec<String> = sqlx::query_scalar(&format!(
            "SELECT out_event_data FROM {}.fetch_history_with_execution($1, $2)",
            self.schema_name
        ))
        .bind(instance)
        .bind(execution_id as i64)
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("read_execution", e))?;

        event_data_rows
            .into_iter()
            .filter_map(|event_data| serde_json::from_str::<Event>(&event_data).ok())
            .collect::<Vec<Event>>()
            .into_iter()
            .map(Ok)
            .collect()
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn read_history(&self, instance: &str) -> Result<Vec<Event>, ProviderError> {
        let execution_id = self.latest_execution_id(instance).await?;
        self.read_history_with_execution_id(instance, execution_id)
            .await
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn latest_execution_id(&self, instance: &str) -> Result<u64, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("latest_execution_id"));
        sqlx::query_scalar(&format!(
            "SELECT {}.latest_execution_id($1)",
            self.schema_name
        ))
        .bind(instance)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("latest_execution_id", e))?
        .map(|id: i64| id as u64)
        .ok_or_else(|| ProviderError::permanent("latest_execution_id", "Instance not found"))
    }

    #[instrument(skip(self), fields(instance = %instance), target = "duroxide::providers::postgres")]
    async fn get_instance_info(&self, instance: &str) -> Result<InstanceInfo, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("get_instance_info"));
        let row: Option<(
            String,
            String,
            String,
            i64,
            chrono::DateTime<Utc>,
            Option<chrono::DateTime<Utc>>,
            Option<String>,
            Option<String>,
            Option<String>,
        )> = sqlx::query_as(&format!(
            "SELECT * FROM {}.get_instance_info($1)",
            self.schema_name
        ))
        .bind(instance)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("get_instance_info", e))?;

        let (
            instance_id,
            orchestration_name,
            orchestration_version,
            current_execution_id,
            created_at,
            updated_at,
            status,
            output,
            parent_instance_id,
        ) =
            row.ok_or_else(|| ProviderError::permanent("get_instance_info", "Instance not found"))?;

        Ok(InstanceInfo {
            instance_id,
            orchestration_name,
            orchestration_version,
            current_execution_id: current_execution_id as u64,
            status: status.unwrap_or_else(|| "Running".to_string()),
            output,
            created_at: created_at.timestamp_millis() as u64,
            updated_at: updated_at
                .map(|dt| dt.timestamp_millis() as u64)
                .unwrap_or(created_at.timestamp_millis() as u64),
            parent_instance_id,
        })
    }

    #[instrument(skip(self), fields(instance = %instance, execution_id = execution_id), target = "duroxide::providers::postgres")]
    async fn get_execution_info(
        &self,
        instance: &str,
        execution_id: u64,
    ) -> Result<ExecutionInfo, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("get_execution_info"));
        let row: Option<(
            i64,
            String,
            Option<String>,
            chrono::DateTime<Utc>,
            Option<chrono::DateTime<Utc>>,
            i64,
        )> = sqlx::query_as(&format!(
            "SELECT * FROM {}.get_execution_info($1, $2)",
            self.schema_name
        ))
        .bind(instance)
        .bind(execution_id as i64)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("get_execution_info", e))?;

        let (exec_id, status, output, started_at, completed_at, event_count) = row
            .ok_or_else(|| ProviderError::permanent("get_execution_info", "Execution not found"))?;

        Ok(ExecutionInfo {
            execution_id: exec_id as u64,
            status,
            output,
            started_at: started_at.timestamp_millis() as u64,
            completed_at: completed_at.map(|dt| dt.timestamp_millis() as u64),
            event_count: event_count as usize,
        })
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn get_system_metrics(&self) -> Result<SystemMetrics, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("get_system_metrics"));
        let row: Option<(i64, i64, i64, i64, i64, i64)> = sqlx::query_as(&format!(
            "SELECT * FROM {}.get_system_metrics()",
            self.schema_name
        ))
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("get_system_metrics", e))?;

        let (
            total_instances,
            total_executions,
            running_instances,
            completed_instances,
            failed_instances,
            total_events,
        ) = row.ok_or_else(|| {
            ProviderError::permanent("get_system_metrics", "Failed to get system metrics")
        })?;

        Ok(SystemMetrics {
            total_instances: total_instances as u64,
            total_executions: total_executions as u64,
            running_instances: running_instances as u64,
            completed_instances: completed_instances as u64,
            failed_instances: failed_instances as u64,
            total_events: total_events as u64,
        })
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn get_queue_depths(&self) -> Result<QueueDepths, ProviderError> {
        let now_ms = self.now_millis();

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("get_queue_depths"));
        let row: Option<(i64, i64)> = sqlx::query_as(&format!(
            "SELECT * FROM {}.get_queue_depths($1)",
            self.schema_name
        ))
        .bind(now_ms)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("get_queue_depths", e))?;

        let (orchestrator_queue, worker_queue) = row.ok_or_else(|| {
            ProviderError::permanent("get_queue_depths", "Failed to get queue depths")
        })?;

        Ok(QueueDepths {
            orchestrator_queue: orchestrator_queue as usize,
            worker_queue: worker_queue as usize,
            timer_queue: 0, // Timers are in orchestrator queue with delayed visibility
        })
    }

    // ===== Hierarchy Primitives =====

    #[instrument(skip(self), fields(instance = %instance_id), target = "duroxide::providers::postgres")]
    async fn list_children(&self, instance_id: &str) -> Result<Vec<String>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("list_children"));
        sqlx::query_scalar(&format!(
            "SELECT child_instance_id FROM {}.list_children($1)",
            self.schema_name
        ))
        .bind(instance_id)
        .fetch_all(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("list_children", e))
    }

    #[instrument(skip(self), fields(instance = %instance_id), target = "duroxide::providers::postgres")]
    async fn get_parent_id(&self, instance_id: &str) -> Result<Option<String>, ProviderError> {
        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("get_parent_id"));
        let result: Result<Option<String>, _> =
            sqlx::query_scalar(&format!("SELECT {}.get_parent_id($1)", self.schema_name))
                .bind(instance_id)
                .fetch_one(&*self.pool)
                .await;

        match result {
            Ok(parent_id) => Ok(parent_id),
            Err(e) => {
                let err_str = e.to_string();
                if err_str.contains("Instance not found") {
                    Err(ProviderError::permanent(
                        "get_parent_id",
                        format!("Instance not found: {instance_id}"),
                    ))
                } else {
                    Err(Self::sqlx_to_provider_error("get_parent_id", e))
                }
            }
        }
    }

    // ===== Deletion Operations =====

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn delete_instances_atomic(
        &self,
        ids: &[String],
        force: bool,
    ) -> Result<DeleteInstanceResult, ProviderError> {
        if ids.is_empty() {
            return Ok(DeleteInstanceResult::default());
        }

        let _timer = DbCallTimer::new(
            DbOperation::StoredProcedure,
            Some("delete_instances_atomic"),
        );
        let row: Option<(i64, i64, i64, i64)> = sqlx::query_as(&format!(
            "SELECT * FROM {}.delete_instances_atomic($1, $2)",
            self.schema_name
        ))
        .bind(ids)
        .bind(force)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| {
            let err_str = e.to_string();
            if err_str.contains("is Running") || err_str.contains("Orphan detected") {
                ProviderError::permanent("delete_instances_atomic", err_str)
            } else {
                Self::sqlx_to_provider_error("delete_instances_atomic", e)
            }
        })?;

        let (instances_deleted, executions_deleted, events_deleted, queue_messages_deleted) =
            row.unwrap_or((0, 0, 0, 0));

        debug!(
            target = "duroxide::providers::postgres",
            operation = "delete_instances_atomic",
            instances_deleted = instances_deleted,
            executions_deleted = executions_deleted,
            events_deleted = events_deleted,
            queue_messages_deleted = queue_messages_deleted,
            "Deleted instances atomically"
        );

        Ok(DeleteInstanceResult {
            instances_deleted: instances_deleted as u64,
            executions_deleted: executions_deleted as u64,
            events_deleted: events_deleted as u64,
            queue_messages_deleted: queue_messages_deleted as u64,
        })
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn delete_instance_bulk(
        &self,
        filter: InstanceFilter,
    ) -> Result<DeleteInstanceResult, ProviderError> {
        // Build query to find matching root instances in terminal states
        let mut sql = format!(
            r#"
            SELECT i.instance_id
            FROM {}.instances i
            LEFT JOIN {}.executions e ON i.instance_id = e.instance_id 
              AND i.current_execution_id = e.execution_id
            WHERE i.parent_instance_id IS NULL
              AND e.status IN ('Completed', 'Failed', 'ContinuedAsNew')
            "#,
            self.schema_name, self.schema_name
        );

        // Add instance_ids filter if provided
        if let Some(ref ids) = filter.instance_ids {
            if ids.is_empty() {
                return Ok(DeleteInstanceResult::default());
            }
            let placeholders: Vec<String> = (1..=ids.len()).map(|i| format!("${i}")).collect();
            sql.push_str(&format!(
                " AND i.instance_id IN ({})",
                placeholders.join(", ")
            ));
        }

        // Add completed_before filter if provided
        if filter.completed_before.is_some() {
            let param_num = filter
                .instance_ids
                .as_ref()
                .map(|ids| ids.len())
                .unwrap_or(0)
                + 1;
            sql.push_str(&format!(
                " AND e.completed_at < TO_TIMESTAMP(${param_num} / 1000.0)"
            ));
        }

        // Add limit
        let limit = filter.limit.unwrap_or(1000);
        let limit_param_num = filter
            .instance_ids
            .as_ref()
            .map(|ids| ids.len())
            .unwrap_or(0)
            + if filter.completed_before.is_some() {
                1
            } else {
                0
            }
            + 1;
        sql.push_str(&format!(" LIMIT ${limit_param_num}"));

        // Build and execute query
        let _timer = DbCallTimer::new(DbOperation::Select, None);
        let mut query = sqlx::query_scalar::<_, String>(&sql);
        if let Some(ref ids) = filter.instance_ids {
            for id in ids {
                query = query.bind(id);
            }
        }
        if let Some(completed_before) = filter.completed_before {
            query = query.bind(completed_before as i64);
        }
        query = query.bind(limit as i64);

        let instance_ids: Vec<String> = query
            .fetch_all(&*self.pool)
            .await
            .map_err(|e| Self::sqlx_to_provider_error("delete_instance_bulk", e))?;

        if instance_ids.is_empty() {
            return Ok(DeleteInstanceResult::default());
        }

        // Delete each instance with cascade
        let mut result = DeleteInstanceResult::default();

        for instance_id in &instance_ids {
            // Get full tree for this root (uses default impl from ProviderAdmin trait)
            let tree = self.get_instance_tree(instance_id).await?;

            // Atomic delete (tree.all_ids is already in deletion order: children first)
            let delete_result = self.delete_instances_atomic(&tree.all_ids, true).await?;
            result.instances_deleted += delete_result.instances_deleted;
            result.executions_deleted += delete_result.executions_deleted;
            result.events_deleted += delete_result.events_deleted;
            result.queue_messages_deleted += delete_result.queue_messages_deleted;
        }

        debug!(
            target = "duroxide::providers::postgres",
            operation = "delete_instance_bulk",
            instances_deleted = result.instances_deleted,
            executions_deleted = result.executions_deleted,
            events_deleted = result.events_deleted,
            queue_messages_deleted = result.queue_messages_deleted,
            "Bulk deleted instances"
        );

        Ok(result)
    }

    // ===== Pruning Operations =====

    #[instrument(skip(self), fields(instance = %instance_id), target = "duroxide::providers::postgres")]
    async fn prune_executions(
        &self,
        instance_id: &str,
        options: PruneOptions,
    ) -> Result<PruneResult, ProviderError> {
        let keep_last: Option<i32> = options.keep_last.map(|v| v as i32);
        let completed_before_ms: Option<i64> = options.completed_before.map(|v| v as i64);

        let _timer = DbCallTimer::new(DbOperation::StoredProcedure, Some("prune_executions"));
        let row: Option<(i64, i64, i64)> = sqlx::query_as(&format!(
            "SELECT * FROM {}.prune_executions($1, $2, $3)",
            self.schema_name
        ))
        .bind(instance_id)
        .bind(keep_last)
        .bind(completed_before_ms)
        .fetch_optional(&*self.pool)
        .await
        .map_err(|e| Self::sqlx_to_provider_error("prune_executions", e))?;

        let (instances_processed, executions_deleted, events_deleted) = row.unwrap_or((0, 0, 0));

        debug!(
            target = "duroxide::providers::postgres",
            operation = "prune_executions",
            instance_id = %instance_id,
            instances_processed = instances_processed,
            executions_deleted = executions_deleted,
            events_deleted = events_deleted,
            "Pruned executions"
        );

        Ok(PruneResult {
            instances_processed: instances_processed as u64,
            executions_deleted: executions_deleted as u64,
            events_deleted: events_deleted as u64,
        })
    }

    #[instrument(skip(self), target = "duroxide::providers::postgres")]
    async fn prune_executions_bulk(
        &self,
        filter: InstanceFilter,
        options: PruneOptions,
    ) -> Result<PruneResult, ProviderError> {
        // Build query to find matching instances (all statuses)
        // Note: We include Running instances because long-running orchestrations (e.g., with
        // ContinueAsNew) may have old executions that need pruning. The underlying prune_executions
        // stored procedure safely skips the current execution regardless of its status.
        let mut sql = format!(
            r#"
            SELECT i.instance_id
            FROM {}.instances i
            LEFT JOIN {}.executions e ON i.instance_id = e.instance_id 
              AND i.current_execution_id = e.execution_id
            WHERE 1=1
            "#,
            self.schema_name, self.schema_name
        );

        // Add instance_ids filter if provided
        if let Some(ref ids) = filter.instance_ids {
            if ids.is_empty() {
                return Ok(PruneResult::default());
            }
            let placeholders: Vec<String> = (1..=ids.len()).map(|i| format!("${i}")).collect();
            sql.push_str(&format!(
                " AND i.instance_id IN ({})",
                placeholders.join(", ")
            ));
        }

        // Add completed_before filter if provided
        if filter.completed_before.is_some() {
            let param_num = filter
                .instance_ids
                .as_ref()
                .map(|ids| ids.len())
                .unwrap_or(0)
                + 1;
            sql.push_str(&format!(
                " AND e.completed_at < TO_TIMESTAMP(${param_num} / 1000.0)"
            ));
        }

        // Add limit
        let limit = filter.limit.unwrap_or(1000);
        let limit_param_num = filter
            .instance_ids
            .as_ref()
            .map(|ids| ids.len())
            .unwrap_or(0)
            + if filter.completed_before.is_some() {
                1
            } else {
                0
            }
            + 1;
        sql.push_str(&format!(" LIMIT ${limit_param_num}"));

        // Build and execute query
        let _timer = DbCallTimer::new(DbOperation::Select, None);
        let mut query = sqlx::query_scalar::<_, String>(&sql);
        if let Some(ref ids) = filter.instance_ids {
            for id in ids {
                query = query.bind(id);
            }
        }
        if let Some(completed_before) = filter.completed_before {
            query = query.bind(completed_before as i64);
        }
        query = query.bind(limit as i64);

        let instance_ids: Vec<String> = query
            .fetch_all(&*self.pool)
            .await
            .map_err(|e| Self::sqlx_to_provider_error("prune_executions_bulk", e))?;

        // Prune each instance
        let mut result = PruneResult::default();

        for instance_id in &instance_ids {
            let single_result = self.prune_executions(instance_id, options.clone()).await?;
            result.instances_processed += single_result.instances_processed;
            result.executions_deleted += single_result.executions_deleted;
            result.events_deleted += single_result.events_deleted;
        }

        debug!(
            target = "duroxide::providers::postgres",
            operation = "prune_executions_bulk",
            instances_processed = result.instances_processed,
            executions_deleted = result.executions_deleted,
            events_deleted = result.events_deleted,
            "Bulk pruned executions"
        );

        Ok(result)
    }
}
