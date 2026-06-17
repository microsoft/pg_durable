// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Shared, read-only accessors for the `df.nodes` table.
//!
//! [`NodeSnapshot`] is the canonical projection of the seven *base* columns of
//! `df.nodes`. It is the single source of truth for the positional SPI read of
//! those columns. Other modules issue intentionally *wider* projections on top
//! of the same row shape:
//!
//! * `src/explain.rs` adds `result::text` (column 8) for tree rendering.
//! * `src/monitoring.rs` adds `result::text` and `updated_at` (columns 8–9).
//!
//! When the `df.nodes` column order changes, update the `SELECT` here and those
//! two sites together — the positional `row.get(N)` reads are not checked by the
//! compiler.

use pgrx::prelude::*;

/// Hard cap on the number of `df.nodes` rows loaded for a single instance.
///
/// A durable function graph is normally tens of nodes; this bound exists only
/// to keep a pathologically large (or maliciously constructed) instance from
/// forcing the backend to materialize an unbounded result set into memory.
pub const MAX_NODES_PER_INSTANCE: usize = 50_000;

/// The seven base columns of a `df.nodes` row, as read by the oracle.
#[derive(Debug, Clone)]
pub struct NodeSnapshot {
    pub id: String,
    pub node_type: String,
    pub query: Option<String>,
    pub result_name: Option<String>,
    pub left_node: Option<String>,
    pub right_node: Option<String>,
    pub status: String,
}

/// Load up to `limit` node snapshots for one instance (RLS-scoped).
///
/// Returns `None` when the instance has *more* than `limit` nodes, signalling
/// the caller to treat the instance as too large to evaluate rather than
/// silently operating on a truncated snapshot.
pub fn load_node_snapshots(instance_id: &str, limit: usize) -> Option<Vec<NodeSnapshot>> {
    Spi::connect(|client| {
        // Fetch one more than the cap so we can detect (not silently truncate)
        // an over-limit instance.
        let sql = format!(
            "SELECT id, node_type, query, result_name, left_node, right_node, status \
             FROM df.nodes WHERE instance_id = $1 LIMIT {}",
            limit + 1
        );
        let mut out: Vec<NodeSnapshot> = Vec::new();
        if let Ok(table) = client.select(&sql, None, &[instance_id.into()]) {
            for row in table {
                let id: String = match row.get::<String>(1) {
                    Ok(Some(v)) => v,
                    _ => continue,
                };
                out.push(NodeSnapshot {
                    id,
                    node_type: row.get(2).ok().flatten().unwrap_or_default(),
                    query: row.get(3).ok().flatten(),
                    result_name: row.get(4).ok().flatten(),
                    left_node: row.get(5).ok().flatten(),
                    right_node: row.get(6).ok().flatten(),
                    status: row.get::<String>(7).ok().flatten().unwrap_or_default(),
                });
                if out.len() > limit {
                    return None;
                }
            }
        }
        Some(out)
    })
}
