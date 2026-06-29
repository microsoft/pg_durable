// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Monitoring functions for pg_durable - using Duroxide Client Management API

#![allow(clippy::type_complexity)] // Required for pgrx TableIterator return types

use duroxide::Client;
use pgrx::datum::TimestampWithTimeZone;
use pgrx::prelude::*;
use std::collections::HashMap;

use crate::types::{backend_duroxide_schema, new_backend_provider, postgres_connection_string};

// ============================================================================
// Monitoring Functions
// ============================================================================

/// Wire-format version of the opaque keyset cursor. Embedded as the first
/// `|`-delimited component so the token shape can evolve (e.g. a future ordering
/// or filter-binding change) without silently mis-decoding an already-issued
/// cursor: decode_cursor rejects any version it does not recognize.
const CURSOR_VERSION: &str = "v1";

/// Maximum accepted length (in hex chars) of an `after_cursor`. Our cursors are
/// well under ~140 hex chars; the cap stops a corrupt or hostile token from
/// forcing a large allocation in decode_cursor before it is rejected.
const MAX_CURSOR_LEN: usize = 512;

/// Encode an opaque keyset cursor from a row's (created_at_text, id).
///
/// The encoding is the hex of "<version>|created_at_text|id" — opaque to clients
/// (so they pass it back verbatim rather than parsing it), dependency-free, and a
/// clean round-trip through decode_cursor. created_at_text is the ISO-8601
/// to_char rendering of created_at used in the listing query, so it casts back to
/// the exact instant via ::timestamptz.
fn encode_cursor(created_at_text: &str, id: &str) -> String {
    let raw = format!("{CURSOR_VERSION}|{created_at_text}|{id}");
    raw.bytes().map(|b| format!("{b:02x}")).collect()
}

/// Decode an opaque keyset cursor produced by encode_cursor into
/// (created_at_text, id). Returns None on any malformedness — wrong length,
/// non-hex, non-UTF8, unknown version, or an empty component — so the caller can
/// reject an invalid cursor rather than silently restarting pagination. Note:
/// the returned created_at_text is only validated structurally here; that it is
/// a parseable timestamp in the exact shape we emit is checked by the caller
/// (see list_instances) before it is used in a cast.
fn decode_cursor(cursor: &str) -> Option<(String, String)> {
    if cursor.is_empty() || cursor.len() > MAX_CURSOR_LEN || !cursor.len().is_multiple_of(2) {
        return None;
    }
    let bytes = cursor.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16)?;
        let lo = (bytes[i + 1] as char).to_digit(16)?;
        decoded.push((hi * 16 + lo) as u8);
        i += 2;
    }
    let s = String::from_utf8(decoded).ok()?;
    // Format is "<version>|<created_at_text>|<id>". Reject unknown versions.
    let (version, rest) = s.split_once('|')?;
    if version != CURSOR_VERSION {
        return None;
    }
    // created_at_text never contains '|', so the next '|' is the separator; the
    // id is whatever remains. Reject either part being empty.
    let (ts, id) = rest.split_once('|')?;
    if ts.is_empty() || id.is_empty() {
        return None;
    }
    Some((ts.to_string(), id.to_string()))
}

/// True if `ts` matches the exact ISO-8601 shape that the listing query emits via
/// to_char(created_at, 'YYYY-MM-DD"T"HH24:MI:SS.USOF'). A decoded cursor whose
/// timestamp does not match (a tampered or truncated token) would otherwise fail
/// the `::timestamptz` cast inside the main query and be swallowed as an empty
/// page — silently ending a client's pagination. We validate it here so a bad
/// cursor is reported as the documented error instead. The regex never raises,
/// so it is safe to evaluate against arbitrary input.
fn cursor_timestamp_well_formed(ts: &str) -> bool {
    Spi::connect(|client| {
        let mut ok = false;
        if let Ok(table) = client.select(
            "SELECT $1 ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{6}[+-][0-9]{2}(:[0-9]{2})?$'",
            None,
            &[ts.into()],
        ) {
            for row in table {
                ok = row.get::<bool>(1).ok().flatten().unwrap_or(false);
            }
        }
        ok
    })
}

/// Batch-fetch (function_name, execution_count, output) for a set of instance ids
/// from duroxide's published `<schema>.get_instance_info(TEXT)` SQL function.
///
/// These values live in duroxide's internal schema, which restricted session
/// roles are not granted to read directly, so the lookup runs over a
/// worker-credentialed sqlx connection — the same trust boundary the per-instance
/// duroxide Client path used, not subject to the calling role's privileges on the
/// duroxide schema. A single batched query invokes get_instance_info once per id
/// via CROSS JOIN LATERAL rather than hand-joining duroxide's internal
/// instances/executions tables, keeping the dependency on duroxide's deliberate
/// function contract instead of its internal table layout. Both
/// `df.list_instances` overloads share this helper.
///
/// KEEP IN SYNC: we read the function's `instance_id`, `orchestration_name`,
/// `current_execution_id`, and `output` OUT columns; if duroxide-pg renames them
/// this query must follow (grep the duroxide-pg migrations for "get_instance_info").
/// LATERAL drops ids the function returns no row for (instances not yet known to
/// duroxide), so the caller skips them — matching the prior per-instance
/// skip-on-error behavior and df.instance_info(), which returns nothing for an
/// instance duroxide does not (yet) know about. Both failure paths warn rather
/// than fail the listing, so a silently-empty result is diagnosable.
///
/// `provider_schema` is a trusted config value (see backend_duroxide_schema), so
/// format! interpolation of the schema name is safe; ids are bound as a text[]
/// parameter and expanded with unnest. The id set is the caller's already
/// RLS-filtered ids, so no cross-user data can leak.
fn fetch_instance_info_map(
    ids: &[String],
    pg_conn_str: &str,
    provider_schema: &str,
) -> HashMap<String, (String, i64, Option<String>)> {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return HashMap::new(),
    };

    rt.block_on(async {
        use sqlx::postgres::PgPoolOptions;

        let mut info_by_id: HashMap<String, (String, i64, Option<String>)> = HashMap::new();

        let pool = match PgPoolOptions::new()
            .max_connections(1)
            .connect(pg_conn_str)
            .await
        {
            Ok(p) => p,
            // A connection failure (e.g. duroxide store unreachable on a freshly
            // initialized database) yields no duroxide info — every instance is
            // skipped by the caller, matching the previous provider-failure
            // behavior. Warn so a silently-empty result is diagnosable rather than
            // looking like "no instances".
            Err(e) => {
                pgrx::warning!("df.list_instances: could not connect to duroxide store: {e}");
                return info_by_id;
            }
        };

        let batch_sql = format!(
            "SELECT gi.instance_id, gi.orchestration_name, gi.current_execution_id, gi.output \
             FROM unnest($1::text[]) AS t(id) \
             CROSS JOIN LATERAL {schema}.get_instance_info(t.id) AS gi",
            schema = provider_schema
        );

        let rows = match sqlx::query_as::<_, (String, String, i64, Option<String>)>(&batch_sql)
            .bind(ids)
            .fetch_all(&pool)
            .await
        {
            Ok(rows) => rows,
            // Best-effort: a duroxide lookup failure must not fail the whole
            // listing (consistent with the other df monitoring functions), but
            // surface it as a warning so a silently-empty result is diagnosable
            // rather than looking like "no instances".
            Err(e) => {
                pgrx::warning!("df.list_instances: duroxide instance-info lookup failed: {e}");
                Vec::new()
            }
        };

        for (id, function_name, execution_count, output) in rows {
            info_by_id.insert(id, (function_name, execution_count, output));
        }

        info_by_id
    })
}

/// List durable function instances, newest-first, optionally filtered by status.
///
/// This is the original two-argument monitoring entry point. The richer
/// label-filter + keyset-pagination + timestamp variant is exposed as an overload
/// of the same SQL name with three or four arguments (see `list_instances_paged`);
/// the two are disjoint by arity, so 0–2 argument calls resolve here and 3–4
/// argument calls resolve to the paginated variant. Keeping this signature and
/// result shape unchanged preserves backward compatibility for a client running
/// the new shared object against a pre-0.2.4 schema that still has only this
/// declaration (upgrade Scenario B1).
#[pg_extern(schema = "df")]
pub fn list_instances(
    status_filter: default!(Option<&str>, "NULL"),
    limit_count: default!(i32, "100"),
) -> TableIterator<
    'static,
    (
        name!(instance_id, String),
        name!(label, Option<String>),
        name!(function_name, String),
        name!(status, String),
        name!(execution_count, i64),
        name!(output, Option<String>),
    ),
> {
    if limit_count < 1 {
        pgrx::error!("limit_count must be at least 1");
    }
    let limit_count = limit_count.min(10000);

    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();

    // Query df.instances via SPI first — RLS filters to calling user's rows only.
    // We also fetch status here so that all three monitoring APIs (df.status(),
    // df.list_instances(), df.instance_info()) share the same authoritative source
    // for the status column, eliminating the vocabulary mismatch between
    // df.instances.status ('cancelled') and duroxide executions.status ('Failed').
    let user_instances: Vec<(String, Option<String>, String)> = Spi::connect(|client| {
        use pgrx::datum::DatumWithOid;

        let (sql, args): (&str, Vec<DatumWithOid>) = if let Some(status) = status_filter {
            (
                "SELECT id, label, status FROM df.instances WHERE status = $1 ORDER BY created_at DESC LIMIT $2",
                vec![status.into(), (limit_count as i64).into()],
            )
        } else {
            (
                "SELECT id, label, status FROM df.instances ORDER BY created_at DESC LIMIT $1",
                vec![(limit_count as i64).into()],
            )
        };
        let mut instances = Vec::new();
        if let Ok(table) = client.select(sql, None, &args) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    let label: Option<String> = row.get(2).ok().flatten();
                    let status: String = row.get(3).ok().flatten().unwrap_or_default();
                    instances.push((id, label, status));
                }
            }
        }
        instances
    });

    if user_instances.is_empty() {
        return TableIterator::new(vec![]);
    }

    let ids: Vec<String> = user_instances.iter().map(|(id, _, _)| id.clone()).collect();
    let mut info_by_id = fetch_instance_info_map(&ids, &pg_conn_str, provider_schema);

    // Reassemble in df.instances order (created_at DESC). Instances with no
    // corresponding duroxide row are intentionally skipped — same as the prior
    // per-instance skip-on-error behavior, and consistent with df.instance_info(),
    // which returns nothing for an instance duroxide does not (yet) know about. id
    // is unique in df.instances, so remove() (a move, not a clone) is safe.
    let results: Vec<(String, Option<String>, String, String, i64, Option<String>)> =
        user_instances
            .into_iter()
            .filter_map(|(id, label, df_status)| {
                let (function_name, execution_count, output) = info_by_id.remove(&id)?;
                Some((id, label, function_name, df_status, execution_count, output))
            })
            .collect();

    TableIterator::new(results)
}

/// List durable function instances, newest-first, with optional status/label
/// filters and keyset pagination.
///
/// This is the enhanced overload of `df.list_instances`: the same SQL function
/// name as the two-argument variant above, distinguished by arity. PostgreSQL
/// resolves a 3- or 4-argument call here and a 0–2-argument call to the basic
/// variant. The two overloads must stay disjoint by arity (otherwise PostgreSQL
/// reports the call as ambiguous), so the first three parameters carry NO
/// defaults: a caller passes status_filter and limit_count positionally (use NULL
/// / a large limit to "not filter") to reach the label filter or pagination —
/// e.g. df.list_instances(NULL, 100, 'my-label') or
/// df.list_instances(NULL, 100, NULL, '<cursor>').
///
/// Filters (all RLS-scoped to the calling role's own instances):
/// - `status_filter`: only instances whose df.instances.status equals this value
///   (pass NULL to not filter by status).
/// - `label_filter`: only instances whose label equals this value; pass NULL to
///   not filter by label (issue #87).
/// - `after_cursor`: opaque keyset cursor from a previous page's `next_cursor`
///   column; returns the instances that sort strictly after it. Pass NULL (or
///   omit) for the first page (issue #146).
///
/// Ordering is `created_at DESC, id ASC` — deterministic and served directly by
/// the (created_at DESC, id) indexes on df.instances. `created_at`/`completed_at`
/// come from df.instances (RLS-filtered, no duroxide round-trip). `next_cursor`
/// is the cursor to fetch the page *after* this one; it is the same value on
/// every returned row and is NULL when no further page exists. See USER_GUIDE.md.
#[pg_extern(name = "list_instances", schema = "df")]
pub fn list_instances_paged(
    status_filter: Option<&str>,
    limit_count: i32,
    label_filter: Option<&str>,
    after_cursor: default!(Option<&str>, "NULL"),
) -> TableIterator<
    'static,
    (
        name!(instance_id, String),
        name!(label, Option<String>),
        name!(function_name, String),
        name!(status, String),
        name!(execution_count, i64),
        name!(output, Option<String>),
        name!(created_at, TimestampWithTimeZone),
        name!(completed_at, Option<TimestampWithTimeZone>),
        name!(next_cursor, Option<String>),
    ),
> {
    if limit_count < 1 {
        pgrx::error!("limit_count must be at least 1");
    }
    let limit_count = limit_count.min(10000);

    // Decode the opaque keyset cursor up front. A malformed cursor is a client
    // error (the token must be passed back verbatim from a prior next_cursor), so
    // reject it rather than silently restarting from the first page.
    let cursor: Option<(String, String)> = match after_cursor {
        Some(c) => match decode_cursor(c) {
            Some((ts, id)) => {
                // A structurally valid cursor (right length, hex, known version)
                // can still carry a tampered or truncated timestamp. That would
                // fail the `::timestamptz` cast inside the listing query and be
                // swallowed as an empty page — silently ending the client's
                // pagination. Validate the timestamp shape here so a bad cursor
                // surfaces as the documented client error instead.
                if !cursor_timestamp_well_formed(&ts) {
                    pgrx::error!("df.list_instances: invalid after_cursor");
                }
                Some((ts, id))
            }
            None => pgrx::error!("df.list_instances: invalid after_cursor"),
        },
        None => None,
    };

    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();

    // Query df.instances via SPI first — RLS filters to calling user's rows only.
    // We fetch status, created_at and completed_at here so that all three
    // monitoring APIs (df.status(), df.list_instances(), df.instance_info()) share
    // the same authoritative source for status (eliminating the vocabulary
    // mismatch between df.instances.status 'cancelled' and duroxide
    // executions.status 'Failed') and so the timestamps and the keyset cursor come
    // from df.instances directly — no duroxide round-trip, and RLS-safe.
    //
    // Filters (status, label, after_cursor) are composed dynamically; each value
    // is bound as a parameter ($1, $2, …), never interpolated, so this is not a
    // SQL-injection surface. We fetch one extra row (LIMIT n+1) purely to detect
    // whether a further page exists. The trailing to_char() renders created_at as
    // the ISO-8601 text embedded in the opaque keyset cursor (see encode_cursor);
    // it round-trips back to the exact instant via ::timestamptz.
    //
    // Ordering created_at DESC, id ASC matches the (created_at DESC, id) indexes,
    // so both the ORDER BY and the keyset range predicate are index-served.
    let mut user_instances: Vec<(
        String,
        Option<String>,
        String,
        TimestampWithTimeZone,
        Option<TimestampWithTimeZone>,
        String,
    )> = Spi::connect(|client| {
        use pgrx::datum::DatumWithOid;

        let mut conds: Vec<String> = Vec::new();
        let mut args: Vec<DatumWithOid> = Vec::new();

        // df.instances.created_at has DEFAULT now() but no NOT NULL constraint.
        // A NULL-created_at row would sort first under DESC, be fetched inside the
        // LIMIT n+1 window, then get skipped in the row loop below — consuming the
        // has_more sentinel and prematurely ending pagination while dropping real
        // rows. Exclude such rows at the SQL level, before the LIMIT, so the page
        // and the has_more probe only ever see cursorable rows. Behavior-preserving
        // for normal rows, which always carry a created_at.
        conds.push("created_at IS NOT NULL".to_string());

        if let Some(status) = status_filter {
            args.push(status.into());
            conds.push(format!("status = ${}", args.len()));
        }
        if let Some(label) = label_filter {
            args.push(label.into());
            conds.push(format!("label = ${}", args.len()));
        }
        if let Some((cur_ts, cur_id)) = cursor.as_ref() {
            args.push(cur_ts.as_str().into());
            let ts_idx = args.len();
            args.push(cur_id.as_str().into());
            let id_idx = args.len();
            // created_at DESC, id ASC → a row sorts after the cursor when it is
            // strictly older, or same-instant with a larger id. The leading
            // `created_at <= $ts` is logically implied by both disjuncts (no change
            // to the result set) but gives the btree a tight upper bound on the
            // leading index column instead of an unSARGable OR.
            conds.push(format!(
                "(created_at <= ${ts_idx}::timestamptz \
                 AND (created_at < ${ts_idx}::timestamptz \
                 OR (created_at = ${ts_idx}::timestamptz AND id > ${id_idx})))"
            ));
        }

        // One extra row beyond the page to detect whether more pages remain.
        args.push(((limit_count as i64) + 1).into());
        let limit_idx = args.len();

        let where_clause = if conds.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", conds.join(" AND "))
        };
        let sql = format!(
            "SELECT id, label, status, created_at, completed_at, \
             to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS.USOF') \
             FROM df.instances{where_clause} \
             ORDER BY created_at DESC, id ASC LIMIT ${limit_idx}"
        );

        let mut instances = Vec::new();
        if let Ok(table) = client.select(&sql, None, &args) {
            for row in table {
                // created_at NULLs are already excluded by the WHERE guard above,
                // so the LIMIT n+1 window only ever holds cursorable rows. This
                // remains as defense-in-depth: a row missing id or created_at
                // cannot participate in keyset ordering, so skip it rather than
                // emit an unordered/uncursorable row.
                let id = match row.get::<String>(1) {
                    Ok(Some(v)) => v,
                    _ => continue,
                };
                let created_at = match row.get::<TimestampWithTimeZone>(4) {
                    Ok(Some(v)) => v,
                    _ => continue,
                };
                let label: Option<String> = row.get(2).ok().flatten();
                let status: String = row.get(3).ok().flatten().unwrap_or_default();
                let completed_at: Option<TimestampWithTimeZone> = row.get(5).ok().flatten();
                let cursor_ts: String = row.get(6).ok().flatten().unwrap_or_default();
                instances.push((id, label, status, created_at, completed_at, cursor_ts));
            }
        }
        instances
    });

    // Detect a further page from the extra row, then trim back to the page size.
    // next_cursor is computed over the df.instances ordering (the authoritative,
    // RLS-filtered set), independent of whether the duroxide lookup below skips
    // any row — so the cursor always advances correctly even when a row is
    // skipped. It is NULL when no further page exists.
    let has_more = user_instances.len() > limit_count as usize;
    user_instances.truncate(limit_count as usize);
    let next_cursor: Option<String> = if has_more {
        user_instances
            .last()
            .map(|(id, _, _, _, _, cursor_ts)| encode_cursor(cursor_ts, id))
    } else {
        None
    };

    if user_instances.is_empty() {
        return TableIterator::new(vec![]);
    }

    // function_name, execution_count and output are not in df.instances; batch
    // them from duroxide over a worker-credentialed connection (see
    // fetch_instance_info_map). The id set is the already RLS-filtered ids above,
    // and status is taken from df.instances so all monitoring APIs agree on it.
    let ids: Vec<String> = user_instances.iter().map(|(id, ..)| id.clone()).collect();
    let mut info_by_id = fetch_instance_info_map(&ids, &pg_conn_str, provider_schema);

    // Reassemble in df.instances order (created_at DESC, id ASC). Instances with
    // no corresponding duroxide row are intentionally skipped — same as the prior
    // per-instance skip-on-error behavior, and consistent with df.instance_info(),
    // which returns nothing for an instance duroxide does not (yet) know about. id
    // is unique in df.instances, so remove() (a move, not a clone) is safe.
    //
    // next_cursor is the same page-level value on every row (NULL on the last
    // page). Known limitation: if every row on a non-final page is skipped here,
    // the page returns zero rows and the caller cannot read next_cursor; in
    // practice instances are registered with duroxide at df.start() time, so this
    // only affects a brief start-up race window.
    let results: Vec<(
        String,
        Option<String>,
        String,
        String,
        i64,
        Option<String>,
        TimestampWithTimeZone,
        Option<TimestampWithTimeZone>,
        Option<String>,
    )> = user_instances
        .into_iter()
        .filter_map(
            |(id, label, df_status, created_at, completed_at, _cursor_ts)| {
                let (function_name, execution_count, output) = info_by_id.remove(&id)?;
                Some((
                    id,
                    label,
                    function_name,
                    df_status,
                    execution_count,
                    output,
                    created_at,
                    completed_at,
                    next_cursor.clone(),
                ))
            },
        )
        .collect();

    TableIterator::new(results)
}

/// Get detailed info about a specific durable function instance.
#[pg_extern(schema = "df")]
pub fn instance_info(
    instance_id: &str,
) -> TableIterator<
    'static,
    (
        name!(instance_id, String),
        name!(label, Option<String>),
        name!(function_name, String),
        name!(function_version, String),
        name!(current_execution_id, i64),
        name!(status, String),
        name!(output, Option<String>),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();
    let instance_id_str = instance_id.to_string();

    // Ownership check: SPI goes through RLS, returning NULL for non-owned instances.
    // Also fetch status here so that df.instance_info() uses df.instances as the
    // authoritative status source, consistent with df.status() and df.list_instances().
    let row: Option<(Option<String>, String)> = Spi::connect(|client| {
        client
            .select(
                "SELECT label, status FROM df.instances WHERE id = $1",
                Some(1),
                &[instance_id.into()],
            )
            .ok()
            .and_then(|table| {
                table.into_iter().next().map(|row| {
                    // SPI row columns are 1-based: col 1 = label, col 2 = status
                    let label: Option<String> = row.get(1).ok().flatten();
                    let status: String = row.get(2).ok().flatten().unwrap_or_default();
                    (label, status)
                })
            })
    });

    let (label, df_status) = match row {
        Some(r) => r,
        None => return TableIterator::new(vec![]),
    };

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str, provider_schema).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        match client.get_instance_info(&instance_id_str).await {
            Ok(info) => vec![(
                info.instance_id,
                label,
                info.orchestration_name,
                info.orchestration_version,
                info.current_execution_id as i64,
                df_status,
                info.output,
            )],
            Err(_) => vec![],
        }
    });

    TableIterator::new(results)
}

/// Get the last N executions for an eternal durable function (loop).
///
/// Distinguishes "this instance genuinely has no execution history yet" (empty
/// rowset) from "the execution-history lookup failed" (explicit error). The
/// latter — failing to build the runtime, connect to the duroxide store, list
/// executions, or fetch a specific execution's info — now raises an error
/// instead of being silently swallowed into an empty rowset. A completed
/// instance always has at least one execution row, so an empty result for one
/// previously masked a real lookup failure. See issue #168.
#[pg_extern(schema = "df")]
pub fn instance_executions(
    instance_id: &str,
    limit_count: default!(i32, "5"),
) -> TableIterator<
    'static,
    (
        name!(execution_id, i64),
        name!(status, String),
        name!(event_count, i64),
        name!(duration_ms, i64),
        name!(output, Option<String>),
    ),
> {
    if limit_count < 1 {
        pgrx::error!("limit_count must be at least 1");
    }
    let limit_count = limit_count.min(10000);

    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();
    let instance_id_owned = instance_id.to_string();

    // Ownership check: SPI goes through RLS, so non-owned instances are invisible.
    // A non-existent or non-owned instance legitimately has no history to show,
    // so an empty rowset (not an error) is the correct response here.
    let exists: bool = Spi::get_one_with_args(
        "SELECT EXISTS(SELECT 1 FROM df.instances WHERE id = $1)",
        &[instance_id.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false);

    if !exists {
        return TableIterator::new(vec![]);
    }

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => pgrx::error!("failed to create async runtime for instance_executions: {e}"),
    };

    let results: Result<Vec<(i64, String, i64, i64, Option<String>)>, String> =
        rt.block_on(async {
            let store = new_backend_provider(&pg_conn_str, provider_schema).await?;

            let client = Client::new(store);

            let execution_ids = client
                .list_executions(&instance_id_owned)
                .await
                .map_err(|e| format!("failed to list executions: {e:?}"))?;

            let mut sorted_ids: Vec<_> = execution_ids.into_iter().collect();
            sorted_ids.sort_by(|a, b| b.cmp(a));
            let limited: Vec<_> = sorted_ids.into_iter().take(limit_count as usize).collect();

            let mut rows = Vec::new();
            for exec_id in limited {
                let info = client
                    .get_execution_info(&instance_id_owned, exec_id)
                    .await
                    .map_err(|e| format!("failed to fetch info for execution {exec_id}: {e:?}"))?;

                let duration_ms = info
                    .completed_at
                    .map(|end| end.saturating_sub(info.started_at))
                    .unwrap_or(0);

                rows.push((
                    info.execution_id as i64,
                    info.status,
                    info.event_count as i64,
                    duration_ms as i64,
                    info.output,
                ));
            }
            Ok(rows)
        });

    match results {
        Ok(rows) => TableIterator::new(rows),
        Err(e) => pgrx::error!("df.instance_executions: execution history lookup failed: {e}"),
    }
}

/// Get system-wide durable function metrics.
///
/// Access is controlled by PostgreSQL function privileges. Roles with ordinary
/// df usage can call `df.list_instances()` to see counts scoped to their own
/// workflows; `df.metrics()` should be granted only to roles that may see
/// system-wide aggregate counts.
#[pg_extern(schema = "df")]
pub fn metrics() -> TableIterator<
    'static,
    (
        name!(total_instances, i64),
        name!(running_instances, i64),
        name!(completed_instances, i64),
        name!(failed_instances, i64),
        name!(total_executions, i64),
        name!(total_events, i64),
    ),
> {
    let pg_conn_str = postgres_connection_string();
    let provider_schema = backend_duroxide_schema();

    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return TableIterator::new(vec![]),
    };

    let results = rt.block_on(async {
        let store = match new_backend_provider(&pg_conn_str, provider_schema).await {
            Ok(s) => s,
            Err(_) => return vec![],
        };

        let client = Client::new(store);

        match client.get_system_metrics().await {
            Ok(m) => vec![(
                m.total_instances as i64,
                m.running_instances as i64,
                m.completed_instances as i64,
                m.failed_instances as i64,
                m.total_executions as i64,
                m.total_events as i64,
            )],
            Err(_) => vec![],
        }
    });

    TableIterator::new(results)
}

struct NodeRow {
    id: String,
    node_type: String,
    query: Option<String>,
    result_name: Option<String>,
    left_node: Option<String>,
    right_node: Option<String>,
    status: Option<String>,
    result: Option<String>,
    status_details: Option<String>,
    updated_at: Option<TimestampWithTimeZone>,
}

impl crate::node_status::NodeFacts for NodeRow {
    fn node_type(&self) -> &str {
        &self.node_type
    }
    fn query(&self) -> Option<&str> {
        self.query.as_deref()
    }
    fn left_node(&self) -> Option<&str> {
        self.left_node.as_deref()
    }
    fn right_node(&self) -> Option<&str> {
        self.right_node.as_deref()
    }
    fn status(&self) -> Option<&str> {
        self.status.as_deref()
    }
    fn status_details(&self) -> Option<&str> {
        self.status_details.as_deref()
    }
}

fn load_instance_nodes(instance_id: &str) -> (Option<String>, Vec<NodeRow>) {
    Spi::connect(|client| {
        let status_details_expr = crate::node_status::status_details_select_expr(client);
        let node_sql = format!(
            "SELECT id, node_type, query, result_name, left_node, right_node,
                    status, result::text, {status_details_expr}, updated_at
             FROM df.nodes WHERE instance_id = $1"
        );
        let mut nodes = Vec::new();
        if let Ok(table) = client.select(&node_sql, None, &[instance_id.into()]) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    nodes.push(NodeRow {
                        id,
                        node_type: row.get::<String>(2).ok().flatten().unwrap_or_default(),
                        query: row.get(3).ok().flatten(),
                        result_name: row.get(4).ok().flatten(),
                        left_node: row.get(5).ok().flatten(),
                        right_node: row.get(6).ok().flatten(),
                        status: row.get(7).ok().flatten(),
                        result: row.get(8).ok().flatten(),
                        status_details: row.get(9).ok().flatten(),
                        updated_at: row.get(10).ok().flatten(),
                    });
                }
            }
        }

        let mut root: Option<String> = None;
        if let Ok(table) = client.select(
            "SELECT root_node FROM df.instances WHERE id = $1",
            None,
            &[instance_id.into()],
        ) {
            if let Some(row) = table.into_iter().next() {
                root = row.get::<String>(1).ok().flatten();
            }
        }

        (root, nodes)
    })
}

/// Get one row per node, with stored status plus read-time inferred status.
#[pg_extern(name = "instance_nodes", schema = "df")]
pub fn instance_nodes_v2(
    instance_id_param: &str,
) -> TableIterator<
    'static,
    (
        name!(node_id, String),
        name!(node_type, String),
        name!(query, Option<String>),
        name!(result_name, Option<String>),
        name!(left_node, Option<String>),
        name!(right_node, Option<String>),
        name!(status, Option<String>),
        name!(result, Option<String>),
        name!(status_details, Option<String>),
        name!(inferred_status, String),
        name!(inferred_status_from_ancestor_id, Option<String>),
        name!(updated_at, Option<pgrx::datum::TimestampWithTimeZone>),
    ),
> {
    use crate::node_status::infer_statuses;

    let (root_node, node_rows) = load_instance_nodes(instance_id_param);
    let nodes: HashMap<String, NodeRow> =
        node_rows.into_iter().map(|n| (n.id.clone(), n)).collect();

    // Shared with df.explain() so both views agree on skipped/superseded nodes.
    let inferred = infer_statuses(root_node.as_deref(), &nodes);

    type Row = (
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        String,
        Option<String>,
        Option<TimestampWithTimeZone>,
    );

    let mut rows: Vec<Row> = Vec::with_capacity(nodes.len());
    for (id, n) in &nodes {
        let inf = inferred.get(id);
        let inferred_status = inf
            .map(|i| i.status.clone())
            .unwrap_or_else(|| n.status.clone().unwrap_or_else(|| "pending".to_string()));
        let from_anc = inf.and_then(|i| i.from_ancestor_id.clone());
        rows.push((
            id.clone(),
            n.node_type.clone(),
            n.query.clone(),
            n.result_name.clone(),
            n.left_node.clone(),
            n.right_node.clone(),
            n.status.clone(),
            n.result.clone(),
            n.status_details.clone(),
            inferred_status,
            from_anc,
            n.updated_at,
        ));
    }

    TableIterator::new(rows)
}

/// Compatibility wrapper for df.instance_nodes(text, integer).
///
/// A pure projection of df.nodes in the pre-0.2.4 result shape: no inference, no
/// execution-history fan-out, and a constant execution_id of 1. It selects only
/// columns present in every 0.2.x schema, so it behaves identically whether the
/// running schema has df.nodes.status_details (0.2.4) or not (0.2.3 under a newer
/// .so) — no column probe required. last_n_executions is ignored.
#[pg_extern(schema = "df")]
pub fn instance_nodes(
    instance_id_param: &str,
    _last_n_executions: i32,
) -> TableIterator<
    'static,
    (
        name!(execution_id, i64),
        name!(node_id, String),
        name!(node_type, String),
        name!(query, Option<String>),
        name!(result_name, Option<String>),
        name!(left_node, Option<String>),
        name!(right_node, Option<String>),
        name!(status, Option<String>),
        name!(result, Option<String>),
        name!(updated_at, Option<pgrx::datum::TimestampWithTimeZone>),
    ),
> {
    type CompatRow = (
        i64,
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<TimestampWithTimeZone>,
    );

    let instance_id = instance_id_param.to_string();
    let rows: Vec<CompatRow> = Spi::connect(|client| {
        let sql = "SELECT id, node_type, query, result_name, left_node, right_node,
                          status, result::text, updated_at
                   FROM df.nodes WHERE instance_id = $1";
        let mut rows = Vec::new();
        if let Ok(table) = client.select(sql, None, &[instance_id.as_str().into()]) {
            for row in table {
                if let Ok(Some(id)) = row.get::<String>(1) {
                    rows.push((
                        1i64,
                        id,
                        row.get::<String>(2).ok().flatten().unwrap_or_default(),
                        row.get(3).ok().flatten(),
                        row.get(4).ok().flatten(),
                        row.get(5).ok().flatten(),
                        row.get(6).ok().flatten(),
                        row.get(7).ok().flatten(),
                        row.get(8).ok().flatten(),
                        row.get(9).ok().flatten(),
                    ));
                }
            }
        }
        rows
    });

    TableIterator::new(rows)
}
