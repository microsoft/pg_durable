//! Tests for PostgreSQL LISTEN/NOTIFY with sqlx PgListener.
//!
//! These tests verify that PgListener works correctly with connection pools
//! and database triggers. They were created to debug the long-polling feature.
//!
//! Key findings:
//! - `current_schema()` in a trigger returns the first schema in the session's
//!   search_path, NOT the schema of the table being modified.
//! - Use `TG_TABLE_SCHEMA` in triggers to get the correct schema name.
use sqlx::postgres::{PgListener, PgPoolOptions};
use tokio::time::{timeout, Duration};

fn get_database_url() -> String {
    dotenvy::dotenv().ok();
    std::env::var("DATABASE_URL").expect("DATABASE_URL must be set")
}

/// Test that PgListener receives NOTIFY from the same pool
#[tokio::test]
async fn test_pg_listener_basic() {
    let database_url = get_database_url();

    // Create pool
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect to database");

    // Create PgListener from pool (same as notifier does)
    let mut listener = PgListener::connect_with(&pool)
        .await
        .expect("Failed to create listener");

    // Subscribe to test channel
    listener
        .listen("test_channel")
        .await
        .expect("Failed to listen");
    eprintln!("[TEST] Subscribed to test_channel");

    // Spawn a task that sends NOTIFY after a short delay
    let pool2 = pool.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        eprintln!("[TEST] Sending NOTIFY...");
        sqlx::query("SELECT pg_notify('test_channel', 'hello from test')")
            .execute(&pool2)
            .await
            .expect("Failed to send NOTIFY");
        eprintln!("[TEST] NOTIFY sent!");
    });

    // Wait for notification
    eprintln!("[TEST] Waiting for notification...");
    match timeout(Duration::from_secs(5), listener.recv()).await {
        Ok(Ok(notification)) => {
            eprintln!(
                "[TEST] ✅ Received notification: channel={}, payload={}",
                notification.channel(),
                notification.payload()
            );
            assert_eq!(notification.channel(), "test_channel");
            assert_eq!(notification.payload(), "hello from test");
        }
        Ok(Err(e)) => {
            panic!("❌ Error receiving notification: {e}");
        }
        Err(_) => {
            panic!("❌ Timeout waiting for notification");
        }
    }
}

/// Test that PgListener receives NOTIFY from a trigger on a table (simulating our actual setup)
#[tokio::test]
async fn test_pg_listener_with_trigger() {
    let database_url = get_database_url();

    // Create pool
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .expect("Failed to connect to database");

    // Create a test schema
    let schema_name = format!(
        "test_notify_{}",
        uuid::Uuid::new_v4().to_string().replace("-", "")[..8].to_lowercase()
    );
    eprintln!("[TEST] Creating test schema: {schema_name}");

    // Create schema with table and trigger
    sqlx::query(&format!("CREATE SCHEMA IF NOT EXISTS {schema_name}"))
        .execute(&pool)
        .await
        .expect("Failed to create schema");

    sqlx::query(&format!(
        "CREATE TABLE {schema_name}.test_queue (id SERIAL PRIMARY KEY, data TEXT)"
    ))
    .execute(&pool)
    .await
    .expect("Failed to create table");

    // Create trigger function using TG_TABLE_SCHEMA (NOT current_schema!)
    // current_schema() returns the first schema in the session's search_path,
    // which is NOT necessarily the schema of the table being modified.
    // TG_TABLE_SCHEMA is the correct way to get the table's schema in a trigger.
    sqlx::query(&format!(
        r#"
        CREATE OR REPLACE FUNCTION {schema_name}.notify_test_queue()
        RETURNS TRIGGER AS $$
        BEGIN
            PERFORM pg_notify(TG_TABLE_SCHEMA || '_test_channel', NEW.id::TEXT);
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
    "#
    ))
    .execute(&pool)
    .await
    .expect("Failed to create trigger function");

    // Create trigger
    sqlx::query(&format!(
        r#"
        CREATE TRIGGER trg_test_notify
        AFTER INSERT ON {schema_name}.test_queue
        FOR EACH ROW
        EXECUTE FUNCTION {schema_name}.notify_test_queue()
    "#
    ))
    .execute(&pool)
    .await
    .expect("Failed to create trigger");

    // Create PgListener and subscribe
    let mut listener = PgListener::connect_with(&pool)
        .await
        .expect("Failed to create listener");
    let channel = format!("{schema_name}_test_channel");
    eprintln!("[TEST] Subscribing to channel: {channel}");
    listener.listen(&channel).await.expect("Failed to listen");
    eprintln!("[TEST] Subscribed successfully");

    // Spawn a task that inserts into the table after a short delay
    let pool2 = pool.clone();
    let schema_clone = schema_name.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        eprintln!("[TEST] Inserting into table...");

        // With TG_TABLE_SCHEMA, we don't need to set search_path - the trigger
        // will correctly use the schema of the table regardless of search_path
        sqlx::query(&format!(
            "INSERT INTO {schema_clone}.test_queue (data) VALUES ('test data')"
        ))
        .execute(&pool2)
        .await
        .expect("Failed to insert");
        eprintln!("[TEST] Insert completed!");
    });

    // Wait for notification from trigger
    eprintln!("[TEST] Waiting for notification from trigger...");
    match timeout(Duration::from_secs(5), listener.recv()).await {
        Ok(Ok(notification)) => {
            eprintln!(
                "[TEST] ✅ Received notification: channel={}, payload={}",
                notification.channel(),
                notification.payload()
            );
            assert_eq!(notification.channel(), channel);
        }
        Ok(Err(e)) => {
            // Cleanup
            let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
                .execute(&pool)
                .await;
            panic!("❌ Error receiving notification: {e}");
        }
        Err(_) => {
            // Cleanup
            let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
                .execute(&pool)
                .await;
            panic!("❌ Timeout waiting for notification from trigger");
        }
    }

    // Cleanup
    sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema_name} CASCADE"))
        .execute(&pool)
        .await
        .expect("Failed to cleanup");
    eprintln!("[TEST] Cleanup completed");
}
