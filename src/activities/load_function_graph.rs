// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! LoadFunctionGraph activity - loads graph from df.instances/df.nodes
//!
//! Includes retry logic to handle the race between df.start() enqueuing work
//! and the user's transaction committing.

use duroxide::ActivityContext;
use sqlx::{PgPool, Row};
use std::sync::Arc;
use std::time::Duration;

use crate::types::{
    is_role_superuser_name, superuser_instances_enabled, FunctionGraph, FunctionNode,
};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::load-function-graph";
/// Transaction-aware graph probe used only by inputs created by the current binary.
pub const TRANSACTION_AWARE_NAME: &str =
    "pg_durable::activity::probe-function-graph-transaction-v1";
/// Deadline for cheap visibility/transaction-status probes only (a single
/// primary-key lookup or `pg_xact_status()` call). Graph *loading* uses its own,
/// much longer policy below — see `GRAPH_LOAD_QUERY_TIMEOUT`.
const TRANSACTION_PROBE_QUERY_TIMEOUT: Duration = Duration::from_secs(2);
/// Deadline for the graph-loading path: role validation, fetching up to
/// `MAX_GRAPH_NODES` (10,000) node rows, constructing the graph, and
/// serializing it. Kept well above `TRANSACTION_PROBE_QUERY_TIMEOUT` so a
/// valid-but-large graph load is never mistaken for a stuck probe.
const GRAPH_LOAD_QUERY_TIMEOUT: Duration = Duration::from_secs(20);
/// Postgres-side `statement_timeout` applied while fetching node rows, so a
/// runaway query is cancelled by the server with a proper SQLSTATE instead of
/// relying solely on the client-side `GRAPH_LOAD_QUERY_TIMEOUT` dropping the
/// connection.
const GRAPH_LOAD_STATEMENT_TIMEOUT_MS: u64 = 15_000;
/// Postgres-side `lock_timeout` applied while fetching node rows, so a load
/// blocked behind a conflicting lock on `df.nodes`/`pg_roles` fails fast with
/// `55P03` (classified transient, see `classify_sqlstate`) rather than
/// consuming the whole statement timeout waiting to even start.
const GRAPH_LOAD_LOCK_TIMEOUT_MS: u64 = 5_000;
/// Postgres-side `statement_timeout` applied to every cheap probe query
/// (visibility, transaction-status, snapshot). Set below the 2s client-side
/// `TRANSACTION_PROBE_QUERY_TIMEOUT` so the *server* cancels a stuck probe and
/// hands the connection back to the pool cleanly, before the client-side
/// `tokio::time::timeout` would drop the in-flight future and force the pool to
/// drain (or discard) the connection — the failure mode that can otherwise
/// exhaust the small management pool under a conflicting lock.
const PROBE_STATEMENT_TIMEOUT_MS: u64 = 1_500;
/// Postgres-side `lock_timeout` applied to every cheap probe query, so a probe
/// blocked behind a conflicting lock (e.g. on `df.instances`) fails fast with
/// `55P03` (classified transient) instead of occupying a management connection
/// until the client deadline.
const PROBE_LOCK_TIMEOUT_MS: u64 = 1_500;

/// Retry configuration for waiting on uncommitted transactions
pub const MAX_WAIT_SECS: u64 = 5;
pub const POLL_INTERVAL_MS: u64 = 100;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TransactionAwareLoadInput {
    pub instance_id: String,
    pub origin_xid: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TransactionGraphProbe {
    Ready { graph: String },
    InProgress,
    Retry,
    Aborted,
    CommittedMissing,
}

#[derive(Debug)]
enum LoadGraphError {
    Retryable(String),
    Permanent(String),
}

impl LoadGraphError {
    fn into_message(self) -> String {
        match self {
            Self::Retryable(message) | Self::Permanent(message) => message,
        }
    }
}

/// Whether a database error observed while probing/loading a graph is worth
/// retrying (bounded, see `MAX_GRAPH_RETRY_ATTEMPTS` in the orchestration) or
/// should fail the workflow immediately.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ErrorClass {
    Transient,
    Permanent,
}

/// Classify a Postgres SQLSTATE as transient (worth a bounded retry) or
/// permanent (fail immediately). Deliberately conservative: any code not on
/// the transient allowlist - including codes we don't recognize - is treated
/// as permanent, since silently retrying an unrecognized error forever is
/// exactly the bug class this classification exists to prevent.
fn classify_sqlstate(code: &str) -> ErrorClass {
    match code {
        // Connection Exception class: transport/connection-level failures
        // that are expected to be transient.
        "08000" | "08001" | "08003" | "08004" | "08006" | "08007" | "08P01" => {
            ErrorClass::Transient
        }
        // Concurrency conflicts that are expected to clear on retry.
        "40001" /* serialization_failure */ | "40P01" /* deadlock_detected */ => {
            ErrorClass::Transient
        }
        // Our own statement/lock timeouts (see GRAPH_LOAD_STATEMENT_TIMEOUT_MS /
        // GRAPH_LOAD_LOCK_TIMEOUT_MS): the query was cancelled by policy, not
        // because it can never succeed.
        "57014" /* query_canceled */ | "55P03" /* lock_not_available */ => ErrorClass::Transient,
        // Admin-initiated cancellation / hot-standby conflicts: transient by
        // nature (server restart, failover, recovery conflict).
        "57P01" | "57P02" | "57P03" => ErrorClass::Transient,
        _ => ErrorClass::Permanent,
    }
}

/// Extract the SQLSTATE code from a sqlx error, if any.
fn sqlstate_of(error: &sqlx::Error) -> Option<String> {
    error
        .as_database_error()
        .and_then(|db| db.code())
        .map(|code| code.into_owned())
}

/// Classify a sqlx error as transient or permanent. Errors without a SQLSTATE
/// (pool exhaustion, IO/TLS/protocol failures - i.e. connection failures that
/// never reached the server) are treated as transient.
fn classify_sqlx_error(error: &sqlx::Error) -> ErrorClass {
    match sqlstate_of(error) {
        Some(code) => classify_sqlstate(&code),
        None => ErrorClass::Transient,
    }
}

/// Wrap a sqlx error observed while loading a graph into the appropriately
/// classified `LoadGraphError`, embedding the SQLSTATE (or "unknown") so
/// terminal failures are diagnosable.
fn classified_load_graph_error(operation: &str, error: sqlx::Error) -> LoadGraphError {
    let code = sqlstate_of(&error).unwrap_or_else(|| "unknown".to_string());
    let message = format!("{operation} failed (SQLSTATE {code}): {error}");
    match classify_sqlx_error(&error) {
        ErrorClass::Transient => LoadGraphError::Retryable(message),
        ErrorClass::Permanent => LoadGraphError::Permanent(message),
    }
}

const INSTANCE_QUERY: &str = "SELECT root_node, r.rolname AS submitted_by
    FROM df.instances i
    LEFT JOIN pg_catalog.pg_roles r ON r.oid = i.submitted_by::oid
    WHERE i.id = $1";

/// Begin a transaction with server-side `statement_timeout` / `lock_timeout`
/// applied via `SET LOCAL`, so every cheap probe query is cancelled by
/// PostgreSQL before the client-side deadline fires. The timeouts are scoped to
/// the transaction and discarded on rollback, so they never leak onto a pooled
/// connection reused by unrelated work. Callers run their read against the
/// returned transaction and roll it back (the probes are read-only, so the
/// rollback vs. commit distinction is not observable).
async fn begin_probe_tx(
    pool: &PgPool,
) -> Result<sqlx::Transaction<'_, sqlx::Postgres>, sqlx::Error> {
    let mut tx = pool.begin().await?;
    sqlx::query(&format!(
        "SET LOCAL statement_timeout = '{PROBE_STATEMENT_TIMEOUT_MS}ms'"
    ))
    .execute(&mut *tx)
    .await?;
    sqlx::query(&format!(
        "SET LOCAL lock_timeout = '{PROBE_LOCK_TIMEOUT_MS}ms'"
    ))
    .execute(&mut *tx)
    .await?;
    Ok(tx)
}

async fn find_visible_instance(
    pool: &PgPool,
    instance_id: &str,
) -> Result<Option<sqlx::postgres::PgRow>, sqlx::Error> {
    let mut tx = begin_probe_tx(pool).await?;
    let row = sqlx::query(INSTANCE_QUERY)
        .bind(instance_id)
        .fetch_optional(&mut *tx)
        .await;
    // Read-only transaction: a rollback failure cannot change the result.
    let _ = tx.rollback().await;
    row
}

/// Probe the caller's origin transaction status (`pg_xact_status`) under
/// server-enforced probe timeouts, so a blocked catalog read is cancelled by
/// PostgreSQL rather than pinning a management connection.
async fn probe_origin_transaction_status(
    pool: &PgPool,
    origin_xid: &str,
) -> Result<Option<String>, sqlx::Error> {
    let mut tx = begin_probe_tx(pool).await?;
    let status = sqlx::query_scalar("SELECT pg_catalog.pg_xact_status($1::text::xid8)::text")
        .bind(origin_xid)
        .fetch_one(&mut *tx)
        .await;
    let _ = tx.rollback().await;
    status
}

/// Probe whether the origin transaction is visible in a fresh snapshot, under
/// server-enforced probe timeouts (see `begin_probe_tx`).
async fn probe_snapshot_visible(pool: &PgPool, origin_xid: &str) -> Result<bool, sqlx::Error> {
    let mut tx = begin_probe_tx(pool).await?;
    let visible = sqlx::query_scalar::<_, bool>(
        "SELECT pg_catalog.pg_visible_in_snapshot($1::text::xid8, pg_catalog.pg_current_snapshot())",
    )
    .bind(origin_xid)
    .fetch_one(&mut *tx)
    .await;
    let _ = tx.rollback().await;
    visible
}

/// Fetch a graph's node rows with a real Postgres-side timeout backstop.
///
/// Runs inside its own transaction so `SET LOCAL statement_timeout` /
/// `SET LOCAL lock_timeout` apply only to this read and are automatically
/// discarded when the transaction ends - no risk of leaking a modified
/// timeout onto a pooled connection reused by unrelated work. The read never
/// writes anything, so the transaction is always rolled back regardless of
/// outcome (rollback vs. commit makes no observable difference here; rollback
/// avoids depending on the connection's default transaction characteristics).
async fn fetch_node_rows(
    pool: &PgPool,
    instance_id: &str,
) -> Result<Vec<sqlx::postgres::PgRow>, sqlx::Error> {
    const NODES_QUERY: &str = r#"SELECT n.id, n.node_type, n.query, n.result_name,
           n.left_node, n.right_node,
           r.rolname AS submitted_by,
           n.database
        FROM df.nodes n
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
        WHERE n.instance_id = $1"#;

    let mut tx = pool.begin().await?;
    sqlx::query(&format!(
        "SET LOCAL statement_timeout = '{GRAPH_LOAD_STATEMENT_TIMEOUT_MS}ms'"
    ))
    .execute(&mut *tx)
    .await?;
    sqlx::query(&format!(
        "SET LOCAL lock_timeout = '{GRAPH_LOAD_LOCK_TIMEOUT_MS}ms'"
    ))
    .execute(&mut *tx)
    .await?;

    let rows = sqlx::query(NODES_QUERY)
        .bind(instance_id)
        .fetch_all(&mut *tx)
        .await;

    // Best-effort: this is a read-only transaction, so a rollback failure
    // (e.g. connection already dropped) doesn't change the outcome we report.
    let _ = tx.rollback().await;
    rows
}

async fn load_visible_graph(
    ctx: &ActivityContext,
    pool: &PgPool,
    instance_id: String,
    instance_row: sqlx::postgres::PgRow,
) -> Result<String, LoadGraphError> {
    let root_node_id: String = instance_row.get("root_node");
    let instance_submitted_by: Option<String> = instance_row.get("submitted_by");
    let instance_submitted_by = instance_submitted_by.ok_or_else(|| {
        LoadGraphError::Permanent(format!(
            "Instance {instance_id}: submitted_by role no longer exists in pg_roles"
        ))
    })?;

    // Worker-side superuser guard: reject before executing any user SQL.
    // This closes the forgery path where a BYPASSRLS role inserts rows with
    // submitted_by = <superuser> directly, bypassing the df.start() check.
    if !superuser_instances_enabled() {
        match is_role_superuser_name(pool, &instance_submitted_by).await {
            Ok(true) => {
                return Err(LoadGraphError::Permanent(format!(
                    "pg_durable blocked instance {instance_id}: submitted_by role \
                     \"{instance_submitted_by}\" is a superuser, but \
                     pg_durable.enable_superuser_instances is off"
                )));
            }
            Ok(false) => {}
            Err(e) => {
                return Err(LoadGraphError::Retryable(format!(
                    "pg_durable: superuser check failed for instance {instance_id}: {e}"
                )));
            }
        }
    }

    let rows = fetch_node_rows(pool, &instance_id)
        .await
        .map_err(|e| classified_load_graph_error("Failed to load function nodes", e))?;

    let mut nodes = std::collections::BTreeMap::new();
    for row in rows {
        let id: String = row.get("id");
        let submitted_by: Option<String> = row.get("submitted_by");
        let submitted_by = submitted_by.ok_or_else(|| {
            LoadGraphError::Permanent(format!(
                "Instance {instance_id}: node {id} submitted_by role no longer exists in pg_roles"
            ))
        })?;

        // No per-node superuser check needed: a composite FK
        //   (instance_id, submitted_by) REFERENCES df.instances (id, submitted_by)
        // guarantees every node shares the instance's submitted_by.
        // The instance-level check above already covers the superuser case.
        let node = FunctionNode {
            id: id.clone(),
            node_type: row.get("node_type"),
            query: row.get("query"),
            result_name: row.get("result_name"),
            left_node: row.get("left_node"),
            right_node: row.get("right_node"),
            submitted_by,
            database: row.get("database"),
        };
        nodes.insert(id, node);
    }

    let graph = FunctionGraph {
        instance_id,
        root_node_id,
        nodes,
    };

    ctx.trace_info(format!(
        "Loaded function graph with {} nodes",
        graph.nodes.len()
    ));

    serde_json::to_string(&graph)
        .map_err(|e| LoadGraphError::Permanent(format!("Failed to serialize graph: {e}")))
}

/// Load a function graph from the database, with retry logic for transaction visibility
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    instance_id: String,
) -> Result<String, String> {
    ctx.trace_info(format!(
        "Loading function graph for instance: {instance_id}"
    ));

    // Retry loop: wait for instance data to appear
    let start_time = std::time::Instant::now();
    let instance_row = loop {
        match find_visible_instance(pool.as_ref(), &instance_id).await {
            Ok(Some(row)) => break row,
            Ok(None) => {
                let elapsed = start_time.elapsed();
                if elapsed.as_secs() >= MAX_WAIT_SECS {
                    return Err(format!(
                        "Instance {instance_id} not found after {MAX_WAIT_SECS}s (transaction may have been rolled back)"
                    ));
                }
                if elapsed.as_millis() < POLL_INTERVAL_MS as u128 * 2 {
                    ctx.trace_info(format!(
                        "Instance {instance_id} not yet visible, waiting for transaction commit..."
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
            }
            Err(e) => {
                let elapsed = start_time.elapsed();
                if elapsed.as_secs() >= MAX_WAIT_SECS {
                    return Err(format!(
                        "Instance {instance_id} not found after {MAX_WAIT_SECS}s: {e}"
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_millis(POLL_INTERVAL_MS)).await;
            }
        }
    };

    load_visible_graph(&ctx, pool.as_ref(), instance_id, instance_row)
        .await
        .map_err(LoadGraphError::into_message)
}

fn serialize_probe(probe: &TransactionGraphProbe) -> Result<String, String> {
    serde_json::to_string(probe).map_err(|e| format!("Failed to serialize graph probe result: {e}"))
}

fn retry_probe(
    ctx: &ActivityContext,
    operation: &str,
    instance_id: &str,
    error: impl std::fmt::Display,
) -> Result<String, String> {
    ctx.trace_info(format!(
        "Transient {operation} failure for instance {instance_id}; graph probe will retry: {error}"
    ));
    serialize_probe(&TransactionGraphProbe::Retry)
}

/// Route a sqlx error encountered while probing (visibility/transaction-status
/// checks) through classification: transient errors become a bounded `Retry`
/// probe result, permanent errors fail the activity immediately with the
/// SQLSTATE embedded so the workflow doesn't poll forever on an unrecoverable
/// condition (e.g. insufficient_privilege, undefined_table).
fn probe_error_outcome(
    ctx: &ActivityContext,
    operation: &str,
    instance_id: &str,
    error: sqlx::Error,
) -> Result<String, String> {
    match classify_sqlx_error(&error) {
        ErrorClass::Transient => retry_probe(ctx, operation, instance_id, error),
        ErrorClass::Permanent => {
            let code = sqlstate_of(&error).unwrap_or_else(|| "unknown".to_string());
            Err(format!(
                "Instance {instance_id}: {operation} failed permanently (SQLSTATE {code}): {error}"
            ))
        }
    }
}

/// Decision point for the exact race window this handles: PostgreSQL can
/// record a transaction as committed before `ProcArrayEndTransaction` removes
/// it from the running-transactions set used to build a fresh snapshot. In
/// that window, a graph re-read can spuriously return no rows even though the
/// transaction is genuinely committed and the graph exists. Extracted as a
/// pure function so the decision itself has direct unit coverage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommittedProbeStep {
    /// The origin xid is committed but not yet snapshot-visible: retry
    /// (bounded) instead of trusting a re-read.
    AwaitSnapshotVisibility,
    /// The origin xid is committed and snapshot-visible: a re-read that finds
    /// no graph can be trusted as genuine `CommittedMissing`.
    ReadyToReread,
}

fn committed_probe_step(snapshot_visible: bool) -> CommittedProbeStep {
    if snapshot_visible {
        CommittedProbeStep::ReadyToReread
    } else {
        CommittedProbeStep::AwaitSnapshotVisibility
    }
}

/// Probe graph visibility without pinning an activity task while the caller's
/// transaction remains open. The orchestration schedules a durable timer and
/// invokes this single-shot activity again when the xid is still in progress.
pub async fn probe_transaction(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    input_json: String,
) -> Result<String, String> {
    let input: TransactionAwareLoadInput = serde_json::from_str(&input_json)
        .map_err(|e| format!("Invalid transaction-aware graph probe input: {e}"))?;
    if input.origin_xid.parse::<u64>().is_err() {
        return Err(format!(
            "Invalid origin transaction id \"{}\" for instance {}",
            input.origin_xid, input.instance_id
        ));
    }

    ctx.trace_info(format!(
        "Probing graph visibility for instance {} from origin transaction {}",
        input.instance_id, input.origin_xid
    ));

    let visible = match tokio::time::timeout(
        TRANSACTION_PROBE_QUERY_TIMEOUT,
        find_visible_instance(pool.as_ref(), &input.instance_id),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => {
            return retry_probe(
                &ctx,
                "graph visibility check",
                &input.instance_id,
                "timed out after 2s",
            );
        }
    };

    match visible {
        Ok(Some(row)) => {
            let loaded = match tokio::time::timeout(
                GRAPH_LOAD_QUERY_TIMEOUT,
                load_visible_graph(&ctx, pool.as_ref(), input.instance_id.clone(), row),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => {
                    return retry_probe(
                        &ctx,
                        "graph load",
                        &input.instance_id,
                        format!("timed out after {}s", GRAPH_LOAD_QUERY_TIMEOUT.as_secs()),
                    );
                }
            };
            return match loaded {
                Ok(graph) => serialize_probe(&TransactionGraphProbe::Ready { graph }),
                Err(LoadGraphError::Retryable(error)) => {
                    retry_probe(&ctx, "graph load", &input.instance_id, error)
                }
                Err(LoadGraphError::Permanent(error)) => Err(error),
            };
        }
        Ok(None) => {}
        Err(e) => {
            return probe_error_outcome(&ctx, "graph visibility check", &input.instance_id, e);
        }
    }

    let transaction_status_query = tokio::time::timeout(
        TRANSACTION_PROBE_QUERY_TIMEOUT,
        probe_origin_transaction_status(pool.as_ref(), &input.origin_xid),
    )
    .await;
    let transaction_status: Option<String> = match transaction_status_query {
        Ok(Ok(status)) => status,
        Ok(Err(e)) => {
            return probe_error_outcome(&ctx, "origin transaction check", &input.instance_id, e);
        }
        Err(_) => {
            return retry_probe(
                &ctx,
                "origin transaction check",
                &input.instance_id,
                "timed out after 2s",
            );
        }
    };

    let probe = match transaction_status.as_deref() {
        Some("in progress") => TransactionGraphProbe::InProgress,
        Some("aborted") => TransactionGraphProbe::Aborted,
        Some("committed") => {
            // pg_xact_status() can report "committed" before
            // ProcArrayEndTransaction removes the xid from the running set
            // used to build a fresh snapshot. Check snapshot visibility
            // explicitly before trusting a re-read as proof the graph is
            // absent - otherwise a valid committed graph can be permanently
            // misclassified as CommittedMissing during this narrow window.
            let snapshot_visible_query = tokio::time::timeout(
                TRANSACTION_PROBE_QUERY_TIMEOUT,
                probe_snapshot_visible(pool.as_ref(), &input.origin_xid),
            )
            .await;
            let snapshot_visible = match snapshot_visible_query {
                Ok(Ok(visible)) => visible,
                Ok(Err(e)) => {
                    return probe_error_outcome(
                        &ctx,
                        "post-commit snapshot visibility check",
                        &input.instance_id,
                        e,
                    );
                }
                Err(_) => {
                    return retry_probe(
                        &ctx,
                        "post-commit snapshot visibility check",
                        &input.instance_id,
                        "timed out after 2s",
                    );
                }
            };

            if committed_probe_step(snapshot_visible) == CommittedProbeStep::AwaitSnapshotVisibility
            {
                return retry_probe(
                    &ctx,
                    "post-commit snapshot visibility",
                    &input.instance_id,
                    "origin transaction committed but not yet snapshot-visible",
                );
            }

            // The status and graph reads use separate READ COMMITTED statements.
            // Re-read once after observing commit so a commit between the first
            // graph query and pg_xact_status cannot be misclassified as missing.
            // Snapshot visibility is now confirmed above, so a `None` here is a
            // genuine CommittedMissing, not a visibility race.
            let visible = match tokio::time::timeout(
                TRANSACTION_PROBE_QUERY_TIMEOUT,
                find_visible_instance(pool.as_ref(), &input.instance_id),
            )
            .await
            {
                Ok(result) => result,
                Err(_) => {
                    return retry_probe(
                        &ctx,
                        "post-commit graph visibility check",
                        &input.instance_id,
                        "timed out after 2s",
                    );
                }
            };
            match visible {
                Ok(Some(row)) => {
                    let loaded = match tokio::time::timeout(
                        GRAPH_LOAD_QUERY_TIMEOUT,
                        load_visible_graph(&ctx, pool.as_ref(), input.instance_id.clone(), row),
                    )
                    .await
                    {
                        Ok(result) => result,
                        Err(_) => {
                            return retry_probe(
                                &ctx,
                                "post-commit graph load",
                                &input.instance_id,
                                format!("timed out after {}s", GRAPH_LOAD_QUERY_TIMEOUT.as_secs()),
                            );
                        }
                    };
                    match loaded {
                        Ok(graph) => TransactionGraphProbe::Ready { graph },
                        Err(LoadGraphError::Retryable(error)) => {
                            return retry_probe(
                                &ctx,
                                "post-commit graph load",
                                &input.instance_id,
                                error,
                            );
                        }
                        Err(LoadGraphError::Permanent(error)) => return Err(error),
                    }
                }
                Ok(None) => TransactionGraphProbe::CommittedMissing,
                Err(e) => {
                    return probe_error_outcome(
                        &ctx,
                        "post-commit graph visibility check",
                        &input.instance_id,
                        e,
                    );
                }
            }
        }
        Some(other) => {
            return Err(format!(
                "Origin transaction {} for instance {} has unknown status \"{}\"",
                input.origin_xid, input.instance_id, other
            ))
        }
        None => {
            return Err(format!(
                "Origin transaction {} for instance {} has no available status",
                input.origin_xid, input.instance_id
            ))
        }
    };

    serialize_probe(&probe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transaction_probe_input_round_trips() {
        let input = TransactionAwareLoadInput {
            instance_id: "deadbeef".to_string(),
            origin_xid: "12345".to_string(),
        };
        let json = serde_json::to_string(&input).unwrap();
        assert_eq!(
            serde_json::from_str::<TransactionAwareLoadInput>(&json).unwrap(),
            input
        );
    }

    #[test]
    fn transaction_probe_results_have_stable_tags() {
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::InProgress).unwrap(),
            r#"{"state":"in_progress"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::Aborted).unwrap(),
            r#"{"state":"aborted"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::Retry).unwrap(),
            r#"{"state":"retry"}"#
        );
        assert_eq!(
            serde_json::to_string(&TransactionGraphProbe::CommittedMissing).unwrap(),
            r#"{"state":"committed_missing"}"#
        );
    }

    #[test]
    fn committed_probe_step_awaits_snapshot_visibility_until_confirmed() {
        // The exact race this covers: pg_xact_status() already reports
        // "committed" but the xid isn't snapshot-visible yet - must not be
        // treated as ready to re-read (that would risk a spurious
        // CommittedMissing classification for a genuinely committed graph).
        assert_eq!(
            committed_probe_step(false),
            CommittedProbeStep::AwaitSnapshotVisibility
        );
        assert_eq!(
            committed_probe_step(true),
            CommittedProbeStep::ReadyToReread
        );
    }

    #[test]
    fn classify_sqlstate_allows_connection_and_our_own_timeout_codes() {
        for code in [
            "08000", "08001", "08003", "08004", "08006", "08007", "08P01", "40001", "40P01",
            "57014", "55P03", "57P01", "57P02", "57P03",
        ] {
            assert_eq!(
                classify_sqlstate(code),
                ErrorClass::Transient,
                "expected {code} to classify as transient"
            );
        }
    }

    #[test]
    fn classify_sqlstate_treats_privilege_and_schema_errors_as_permanent() {
        for code in ["42501", "42883", "42P01", "22P02", "23505"] {
            assert_eq!(
                classify_sqlstate(code),
                ErrorClass::Permanent,
                "expected {code} to classify as permanent"
            );
        }
    }

    #[test]
    fn classify_sqlstate_defaults_unknown_codes_to_permanent() {
        // Deliberate: an unrecognized SQLSTATE must not be silently retried
        // forever - that's exactly the bug class being fixed.
        assert_eq!(classify_sqlstate("XXUNK"), ErrorClass::Permanent);
    }
}
