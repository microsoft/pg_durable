//! # Duroxide PostgreSQL Provider
//!
//! A PostgreSQL-based provider implementation for [Duroxide](https://crates.io/crates/duroxide),
//! a durable task orchestration framework for Rust.
//!
//! ## Usage
//!
//! ```rust,no_run
//! use duroxide_pg_opt::PostgresProvider;
//! use duroxide::runtime::Runtime;
//! use std::sync::Arc;
//!
//! # async fn example() -> anyhow::Result<()> {
//! // Create a provider with the database URL
//! let provider = PostgresProvider::new("postgres://user:password@localhost:5432/mydb").await?;
//!
//! // Use with the Duroxide runtime
//! // let runtime = Runtime::start_with_store(Arc::new(provider), activity_registry, orchestration_registry).await;
//! # Ok(())
//! # }
//! ```
//!
//! ## Custom Schema
//!
//! To isolate data in a specific PostgreSQL schema (useful for multi-tenant deployments):
//!
//! ```rust,no_run
//! use duroxide_pg_opt::PostgresProvider;
//!
//! # async fn example() -> anyhow::Result<()> {
//! let provider = PostgresProvider::new_with_schema(
//!     "postgres://user:password@localhost:5432/mydb",
//!     Some("my_schema"),
//! ).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Configuration
//!
//! | Environment Variable | Description | Default |
//! |---------------------|-------------|---------|
//! | `DUROXIDE_PG_POOL_MAX` | Maximum connection pool size | `10` |
//!
//! ## Long-Polling
//!
//! The provider supports long-polling via PostgreSQL LISTEN/NOTIFY to reduce idle query load:
//!
//! ```rust,no_run
//! use duroxide_pg_opt::{PostgresProvider, LongPollConfig};
//! use std::time::Duration;
//!
//! # async fn example() -> anyhow::Result<()> {
//! let config = LongPollConfig {
//!     enabled: true,
//!     notifier_poll_interval: Duration::from_secs(60),
//!     timer_grace_period: Duration::from_millis(100),
//! };
//!
//! let provider = PostgresProvider::new_with_options(
//!     "postgres://user:password@localhost:5432/mydb",
//!     Some("my_schema"),
//!     config,
//! ).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Configuration with `ProviderConfig`
//!
//! For full control over initialization, use [`ProviderConfig`] with [`PostgresProvider::new_with_config`]:
//!
//! ```rust,no_run
//! use duroxide_pg_opt::{PostgresProvider, ProviderConfig, MigrationPolicy, LongPollConfig};
//! use std::time::Duration;
//!
//! # async fn example() -> anyhow::Result<()> {
//! let mut config = ProviderConfig::default();
//! config.schema_name = Some("my_schema".to_string());
//! config.migration_policy = MigrationPolicy::VerifyOnly;
//! config.long_poll = LongPollConfig {
//!     enabled: false,
//!     ..Default::default()
//! };
//!
//! let provider = PostgresProvider::new_with_config(
//!     "postgres://user:password@localhost:5432/mydb",
//!     config,
//! ).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Features
//!
//! - Automatic schema migration on startup
//! - Connection pooling via sqlx
//! - Custom schema support for multi-tenant isolation
//! - Long-polling via LISTEN/NOTIFY for reduced database load
//! - Full implementation of the Duroxide `Provider` and `ProviderAdmin` traits
//!
//! ## Fault Injection (Testing)
//!
//! For testing resilience scenarios, enable the `test-fault-injection` feature:
//!
//! ```toml
//! [dev-dependencies]
//! duroxide-pg = { version = "0.1", features = ["test-fault-injection"] }
//! ```
pub mod db_metrics;
///
/// ## Database Metrics (Instrumentation)
///
/// For database operation instrumentation, enable the `db-metrics` feature:
///
/// ```toml
/// [dependencies]
/// duroxide-pg = { version = "0.1", features = ["db-metrics"] }
/// ```
///
/// This enables zero-cost metrics collection for all database operations.
/// See the [`db_metrics`] module for details.
#[cfg(feature = "test-fault-injection")]
pub mod fault_injection;
pub mod migrations;
pub mod notifier;
pub mod provider;

#[cfg(feature = "test-fault-injection")]
pub use fault_injection::FaultInjector;
pub use notifier::LongPollConfig;
pub use provider::{MigrationPolicy, PostgresProvider, ProviderConfig};
