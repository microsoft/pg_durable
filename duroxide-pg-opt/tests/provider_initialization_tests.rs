mod common;

use duroxide_pg_opt::{LongPollConfig, MigrationPolicy, PostgresProvider, ProviderConfig};
use std::time::Duration;

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

fn next_schema_name(prefix: &str) -> String {
    let guid = uuid::Uuid::new_v4().to_string();
    let suffix = &guid[guid.len() - 8..];
    format!("{prefix}_{suffix}")
}

#[tokio::test]
async fn verify_only_succeeds_after_apply_all_initialization() {
    let database_url = get_database_url();
    let schema = next_schema_name("init_verify");

    // Initialize schema using the normal provider path (ApplyAll).
    // This simulates “schema provisioned externally” for VerifyOnly.
    let mut init_cfg = ProviderConfig::default();
    init_cfg.schema_name = Some(schema.clone());
    init_cfg.migration_policy = MigrationPolicy::ApplyAll;
    init_cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let init_provider = PostgresProvider::new_with_config(&database_url, init_cfg)
        .await
        .expect("ApplyAll provider should construct successfully");
    drop(init_provider);

    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::VerifyOnly;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_config(&database_url, cfg)
        .await
        .expect("VerifyOnly provider should construct successfully");

    provider.cleanup_schema().await.expect("cleanup_schema failed");
}

#[tokio::test]
async fn verify_only_errors_when_schema_missing() {
    let database_url = get_database_url();
    let schema = next_schema_name("missing_schema");

    // Ensure it's not present.
    common::cleanup_schema(&schema).await;

    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::VerifyOnly;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg).await {
        Ok(_) => panic!("VerifyOnly should fail when schema is missing"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(
                msg.contains("does not exist"),
                "Expected missing-schema error, got: {msg}"
            );
        }
    }
}

#[tokio::test]
async fn rejects_unknown_migrations_by_default() {
    let database_url = get_database_url();
    let schema = next_schema_name("unknown_mig");

    // Create the schema normally.
    let mut base_cfg = ProviderConfig::default();
    base_cfg.schema_name = Some(schema.clone());
    base_cfg.migration_policy = MigrationPolicy::ApplyAll;
    base_cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_config(&database_url, base_cfg)
        .await
        .expect("ApplyAll provider should construct");

    // Insert an "unknown" migration version.
    sqlx::query(&format!(
        "INSERT INTO {schema}._duroxide_migrations (version, name) VALUES ($1, $2)"
    ))
    .bind(9999_i64)
    .bind("9999_unknown.sql")
    .execute(provider.pool())
    .await
    .expect("Failed to insert unknown migration row");

    drop(provider);

    // Unknown migrations should be rejected (schema ahead of code).
    let mut cfg_reject = ProviderConfig::default();
    cfg_reject.schema_name = Some(schema.clone());
    cfg_reject.migration_policy = MigrationPolicy::VerifyOnly;
    cfg_reject.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg_reject).await {
        Ok(_) => panic!("Expected failure due to unknown migrations"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(msg.contains("not recognized"), "Unexpected error: {msg}");
        }
    }

    // Cleanup schema (cannot use provider cleanup here because initialization
    // will reject the inserted unknown migration).
    common::cleanup_schema(&schema).await;
}

#[tokio::test]
async fn schema_name_validation_rejects_unsafe_identifiers() {
    let database_url = get_database_url();

    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some("bad-name".to_string());
    cfg.migration_policy = MigrationPolicy::ApplyAll;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg).await {
        Ok(_) => panic!("Expected schema name validation to fail"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(msg.contains("Invalid schema_name"), "Unexpected error: {msg}");
        }
    }
}

// This is a compile-only sanity check that the public API stays ergonomic.
#[allow(dead_code)]
fn _config_compile_example() {
    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some("public".to_string());
    cfg.migration_policy = MigrationPolicy::VerifyOnly;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        notifier_poll_interval: Duration::from_secs(60),
        timer_grace_period: Duration::from_millis(100),
    };
}

// =========================================================================
// §4a: VerifyOnly with tracking table absent but schema exists
// =========================================================================

#[tokio::test]
async fn verify_only_errors_when_tracking_table_missing() {
    let database_url = get_database_url();
    let schema = next_schema_name("no_tracking");

    // Create the schema without running migrations (bare schema, no tables).
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&database_url)
        .await
        .expect("Failed to connect");

    sqlx::query(&format!("CREATE SCHEMA IF NOT EXISTS {schema}"))
        .execute(&pool)
        .await
        .expect("Failed to create schema");

    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::VerifyOnly;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg).await {
        Ok(_) => panic!("VerifyOnly should fail when tracking table is missing"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(
                msg.contains("Migration tracking table does not exist"),
                "Expected tracking-table-missing error, got: {msg}"
            );
        }
    }

    common::cleanup_schema(&schema).await;
}

// =========================================================================
// §4b: VerifyOnly with partially-applied migrations
// =========================================================================

#[tokio::test]
async fn verify_only_errors_when_migrations_behind() {
    let database_url = get_database_url();
    let schema = next_schema_name("partial_mig");

    // First, fully initialize to get the schema + tracking table.
    let mut init_cfg = ProviderConfig::default();
    init_cfg.schema_name = Some(schema.clone());
    init_cfg.migration_policy = MigrationPolicy::ApplyAll;
    init_cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_config(&database_url, init_cfg)
        .await
        .expect("ApplyAll should succeed");

    // Remove all but the first migration record to simulate a partial state.
    sqlx::query(&format!(
        "DELETE FROM {schema}._duroxide_migrations WHERE version > 1"
    ))
    .execute(provider.pool())
    .await
    .expect("Failed to delete migration rows");

    drop(provider);

    // VerifyOnly should now report missing migrations.
    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::VerifyOnly;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg).await {
        Ok(_) => panic!("VerifyOnly should fail when migrations are behind"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(
                msg.contains("behind") || msg.contains("Missing migrations"),
                "Expected behind-schema error, got: {msg}"
            );
        }
    }

    common::cleanup_schema(&schema).await;
}

// =========================================================================
// §4d: ApplyAll rejects unknown migrations
// =========================================================================

#[tokio::test]
async fn apply_all_rejects_unknown_migrations() {
    let database_url = get_database_url();
    let schema = next_schema_name("unknown_aa");

    // Create the schema normally.
    let mut base_cfg = ProviderConfig::default();
    base_cfg.schema_name = Some(schema.clone());
    base_cfg.migration_policy = MigrationPolicy::ApplyAll;
    base_cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_config(&database_url, base_cfg)
        .await
        .expect("ApplyAll provider should construct");

    // Insert an "unknown" migration version (schema ahead of code).
    sqlx::query(&format!(
        "INSERT INTO {schema}._duroxide_migrations (version, name) VALUES ($1, $2)"
    ))
    .bind(9999_i64)
    .bind("9999_unknown.sql")
    .execute(provider.pool())
    .await
    .expect("Failed to insert unknown migration row");

    drop(provider);

    // ApplyAll should also reject unknown migrations.
    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::ApplyAll;
    cfg.long_poll = LongPollConfig {
        enabled: false,
        ..Default::default()
    };

    match PostgresProvider::new_with_config(&database_url, cfg).await {
        Ok(_) => panic!("Expected failure due to unknown migrations"),
        Err(err) => {
            let msg = format!("{err:#}");
            assert!(msg.contains("not recognized"), "Unexpected error: {msg}");
        }
    }

    common::cleanup_schema(&schema).await;
}

// =========================================================================
// §4f: new_with_config with long-poll enabled
// =========================================================================

#[tokio::test]
async fn new_with_config_long_poll_enabled() {
    let database_url = get_database_url();
    let schema = next_schema_name("lp_enabled");

    let mut cfg = ProviderConfig::default();
    cfg.schema_name = Some(schema.clone());
    cfg.migration_policy = MigrationPolicy::ApplyAll;
    // long_poll defaults to enabled; be explicit for clarity
    cfg.long_poll = LongPollConfig {
        enabled: true,
        ..Default::default()
    };

    let provider = PostgresProvider::new_with_config(&database_url, cfg)
        .await
        .expect("new_with_config with long-poll enabled should succeed");

    provider.cleanup_schema().await.expect("cleanup_schema failed");
}
