//! Cached client infrastructure for user session calls
//!
//! This module provides cached Tokio runtime and Duroxide client for efficient
//! df.start(), df.signal(), and df.cancel() calls from user sessions.

use std::sync::{Arc, OnceLock};

use duroxide::Client;
use duroxide_pg_opt::PostgresProvider;
use pgrx::prelude::*;
use tokio::runtime::Runtime;

use crate::types::{backend_provider_config, postgres_connection_string};

/// Cached tokio runtime for client operations.
static CLIENT_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Cached Duroxide client with connection pool.
static DUROXIDE_CLIENT: OnceLock<Client> = OnceLock::new();

/// Get or create the cached tokio runtime.
fn get_client_runtime() -> &'static Runtime {
    CLIENT_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// Get or create the cached Duroxide client.
fn get_duroxide_client() -> Result<&'static Client, String> {
    if let Some(client) = DUROXIDE_CLIENT.get() {
        return Ok(client);
    }

    let rt = get_client_runtime();
    let pg_conn_str = postgres_connection_string();

    rt.block_on(async {
        let store = Arc::new(
            PostgresProvider::new_with_config(&pg_conn_str, backend_provider_config())
                .await
                .map_err(|e| format!("Failed to connect to duroxide store: {e}"))?,
        );

        let _ = DUROXIDE_CLIENT.set(Client::new(store));
        DUROXIDE_CLIENT
            .get()
            .ok_or_else(|| "Failed to initialize client".to_string())
    })
}

/// Start a durable function via the shared PostgreSQL store.
pub fn start_durable_function(
    function_name: &str,
    instance_id: &str,
    input: &str,
) -> Result<(), String> {
    log!(
        "pg_durable: start_durable_function for instance {}",
        instance_id
    );

    let rt = get_client_runtime();
    let client = get_duroxide_client()?;

    rt.block_on(async {
        client
            .start_orchestration(instance_id, function_name, input)
            .await
            .map_err(|e| format!("Failed to start durable function: {e:?}"))?;
        Ok(())
    })
}

/// Cancel a durable function.
pub fn cancel_durable_function(instance_id: &str, reason: &str) -> Result<(), String> {
    let rt = get_client_runtime();
    let client = get_duroxide_client()?;

    rt.block_on(async {
        client
            .cancel_instance(instance_id, reason)
            .await
            .map_err(|e| format!("Failed to cancel durable function: {e:?}"))?;
        Ok(())
    })
}

/// Raise an external event (signal) to a running orchestration.
pub fn raise_external_event(instance_id: &str, event_name: &str, data: &str) -> Result<(), String> {
    let rt = get_client_runtime();
    let client = get_duroxide_client()?;

    rt.block_on(async {
        client
            .raise_event(instance_id, event_name, data)
            .await
            .map_err(|e| format!("Failed to raise event: {e:?}"))?;
        Ok(())
    })
}
