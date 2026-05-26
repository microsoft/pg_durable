//! Cached client infrastructure for user session calls
//!
//! This module provides cached Tokio runtime and Duroxide client for efficient
//! df.start(), df.signal(), and df.cancel() calls from user sessions.

use std::sync::OnceLock;

use duroxide::Client;
use pgrx::prelude::*;
use tokio::runtime::Runtime;

use crate::types::{new_backend_provider, postgres_connection_string};

/// Cached tokio runtime for client operations.
static CLIENT_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Cached Duroxide client with connection pool.
static DUROXIDE_CLIENT: OnceLock<Client> = OnceLock::new();

/// Check whether the background worker has finished initializing the duroxide
/// schema for the current binary's expected schema version.
///
/// Returns `false` if `duroxide._worker_ready` does not exist, has no row, or
/// has a `schema_version` below `WORKER_SCHEMA_VERSION`. This is a fast SPI
/// read called once per session on the first call to any `df.*` function that
/// needs the duroxide client.
fn is_worker_ready() -> bool {
    // First check if the readiness table exists via the catalogue.  Querying
    // the non-existent table directly would raise a PostgreSQL ERROR that
    // aborts the current (sub)transaction — even if caught in Rust.
    let table_exists = Spi::get_one::<bool>(
        "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_tables \
         WHERE schemaname = 'duroxide' AND tablename = '_worker_ready')",
    )
    .ok()
    .flatten()
    .unwrap_or(false);

    if !table_exists {
        return false;
    }

    Spi::get_one_with_args::<bool>(
        "SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= $1)",
        &[crate::WORKER_SCHEMA_VERSION.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false)
}

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

    if !is_worker_ready() {
        return Err(
            "pg_durable background worker not yet initialized — try again in a moment".to_string(),
        );
    }

    let rt = get_client_runtime();
    let pg_conn_str = postgres_connection_string();

    rt.block_on(async {
        // Limit backend provider to 1 connection — backends need minimal duroxide
        // access (start/cancel/signal only). The runtime is single-threaded
        // (new_current_thread). Note: std::env::set_var becomes unsafe in Rust 2024 edition.
        std::env::set_var("DUROXIDE_PG_POOL_MAX", "1");

        let store = new_backend_provider(&pg_conn_str).await?;

        let _ = DUROXIDE_CLIENT.set(Client::new(store));
        DUROXIDE_CLIENT
            .get()
            .ok_or_else(|| "Failed to initialize client".to_string())
    })
}

async fn list_running_descendants(client: &Client, root_instance_id: &str) -> Vec<String> {
    let tree = match client.get_instance_tree(root_instance_id).await {
        Ok(tree) => tree,
        Err(e) => {
            warning!(
                "pg_durable: failed to inspect instance tree for signal fan-out (root={}): {:?}",
                root_instance_id,
                e
            );
            return vec![];
        }
    };

    let mut descendants = Vec::new();
    for child_instance_id in tree.all_ids {
        if child_instance_id == root_instance_id {
            continue;
        }

        match client.get_instance_info(&child_instance_id).await {
            Ok(info) if info.status.eq_ignore_ascii_case("running") => {
                descendants.push(child_instance_id);
            }
            Ok(_) => {}
            Err(e) => {
                warning!(
                    "pg_durable: failed to inspect child instance status for signal fan-out (child={}): {:?}",
                    child_instance_id, e
                );
            }
        }
    }

    descendants
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

        for child_instance_id in list_running_descendants(client, instance_id).await {
            if let Err(e) = client
                .raise_event(&child_instance_id, event_name, data)
                .await
            {
                warning!(
                    "pg_durable: failed to fan out signal '{}' to child instance {}: {:?}",
                    event_name,
                    child_instance_id,
                    e
                );
            }
        }

        Ok(())
    })
}
