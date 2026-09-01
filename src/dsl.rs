// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! DSL functions for defining durable SQL functions

use cron::Schedule as CronSchedule;
use pgrx::datum::DatumWithOid;
use pgrx::prelude::*;
use std::str::FromStr;

use std::cell::RefCell;
use std::time::{Duration, Instant};

use crate::client::start_durable_function;
use crate::types::{
    flatten_graph, get_max_new_transaction_starts, get_new_transaction_start_timeout,
    mark_non_future_helper_call, short_id, validate_result_name, Durofut, FunctionInput,
    MaterializedNode,
};

/// Check if we're running inside a workflow context (background worker connection).
/// The background worker sets df.in_workflow='true' on all its connections.
fn is_in_workflow_context() -> bool {
    // Check the session variable set by the background worker
    // current_setting with missing_ok=true returns NULL if not set
    let result: Option<String> =
        Spi::get_one("SELECT pg_catalog.current_setting('df.in_workflow', true)")
            .ok()
            .flatten();

    result.as_deref() == Some("true")
}

// ============================================================================
// Version & Debug Functions
// ============================================================================

/// Returns the pg_durable version (semver + build timestamp)
#[pg_extern(schema = "df")]
pub fn version() -> String {
    format!(
        "{} (built {})",
        env!("CARGO_PKG_VERSION"),
        env!("BUILD_TIMESTAMP")
    )
}

/// Binary backward-compatibility shim for issue #110.
///
/// `df.debug_connection()` was removed from the SQL surface in v0.2.4: it is no
/// longer emitted on fresh installs (`sql = false`) and is dropped by the
/// `0.2.3 -> 0.2.4` upgrade script. Pre-0.2.4 schemas, however, still define the
/// function with `AS 'MODULE_PATHNAME','debug_connection_wrapper'`, and
/// PostgreSQL validates that C symbol at `CREATE FUNCTION` time. We therefore
/// keep the wrapper symbol compiled into the binary so the new `.so` can still
/// load every previously shipped schema (upgrade-test Scenario B1). The body
/// intentionally mirrors the old, non-secret output so a binary-only swap
/// (without `ALTER EXTENSION UPDATE`) keeps working until the customer upgrades.
///
/// Remove once `PROVIDER_COMPAT_START_VERSION` advances past 0.2.3.
#[pg_extern(sql = false)]
pub fn debug_connection() -> String {
    use crate::types::{backend_duroxide_schema, postgres_connection_string};
    format!(
        "{} (schema: {})",
        postgres_connection_string(),
        backend_duroxide_schema()
    )
}

// ============================================================================
// Variable Functions
// ============================================================================

fn parse_semver(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch_part = parts.next()?;
    let patch_digits = patch_part
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>();
    let patch = patch_digits.parse().ok()?;
    Some((major, minor, patch))
}

fn installed_extension_version() -> String {
    thread_local! {
        static CACHE: RefCell<Option<(String, Instant)>> = const { RefCell::new(None) };
    }
    const TTL_SECS: u64 = 5;

    CACHE.with(|cache| {
        let cached = cache.borrow();
        if let Some((ref version, ref ts)) = *cached {
            if ts.elapsed().as_secs() < TTL_SECS {
                return version.clone();
            }
        }
        drop(cached);

        let version = Spi::get_one::<String>(
            "SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_durable'",
        )
        .ok()
        .flatten()
        .unwrap_or_else(|| pgrx::error!("pg_durable extension metadata not found"));

        *cache.borrow_mut() = Some((version.clone(), Instant::now()));
        version
    })
}

fn owner_scoped_vars_enabled() -> bool {
    let extversion = installed_extension_version();
    let ext_semver = parse_semver(&extversion).unwrap_or_else(|| {
        pgrx::error!(
            "Unsupported pg_durable extension version format: {}",
            extversion
        )
    });

    ext_semver >= (0, 2, 0)
}

/// Returns true when the installed schema still has the legacy `login_role`
/// column (v0.1.x).  The new .so must set this column on INSERT to satisfy
/// the NOT NULL constraint until the customer runs ALTER EXTENSION UPDATE.
fn legacy_login_role_schema() -> bool {
    !owner_scoped_vars_enabled()
}

/// Sets a workflow variable. Must be called BEFORE df.start(), not inside a workflow.
/// Variables are captured at df.start() and remain immutable during execution.
/// Each user has their own variable namespace (owner = current_user).
#[pg_extern(schema = "df")]
pub fn setvar(name: &str, value: &str) -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.setvar() cannot be called inside a workflow - set variables before starting the workflow");
    }

    let sql = if owner_scoped_vars_enabled() {
        "INSERT INTO df.vars (name, value) VALUES ($1, $2)
         ON CONFLICT (owner, name) DO UPDATE SET value = EXCLUDED.value"
    } else {
        "INSERT INTO df.vars (name, value) VALUES ($1, $2)
         ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value"
    };
    if let Err(e) = Spi::run_with_args(sql, &[name.into(), value.into()]) {
        pgrx::error!("Failed to set variable: {:?}", e);
    }
    mark_non_future_helper_call("df.setvar");
    "OK".to_string()
}

/// Gets a workflow variable value.
/// Returns the variable owned by the current user.
#[pg_extern(schema = "df")]
pub fn getvar(name: &str) -> Option<String> {
    let sql = if owner_scoped_vars_enabled() {
        "SELECT value FROM df.vars WHERE name = $1 AND owner = quote_ident(current_user)::regrole"
    } else {
        "SELECT value FROM df.vars WHERE name = $1"
    };
    Spi::get_one_with_args::<String>(sql, &[name.into()])
        .ok()
        .flatten()
}

/// Removes a workflow variable.
/// Only removes variables owned by the current user.
#[pg_extern(schema = "df")]
pub fn unsetvar(name: &str) -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.unsetvar() cannot be called inside a workflow - manage variables before starting the workflow");
    }

    let sql = if owner_scoped_vars_enabled() {
        "DELETE FROM df.vars WHERE name = $1 AND owner = quote_ident(current_user)::regrole"
    } else {
        "DELETE FROM df.vars WHERE name = $1"
    };
    if let Err(e) = Spi::run_with_args(sql, &[name.into()]) {
        pgrx::error!("Failed to unset variable: {:?}", e);
    }
    mark_non_future_helper_call("df.unsetvar");
    "OK".to_string()
}

/// Clears all workflow variables owned by the current user.
#[pg_extern(schema = "df")]
pub fn clearvars() -> String {
    // Check if we're inside a workflow execution
    if is_in_workflow_context() {
        pgrx::error!("df.clearvars() cannot be called inside a workflow - manage variables before starting the workflow");
    }

    let sql = if owner_scoped_vars_enabled() {
        "DELETE FROM df.vars WHERE owner = quote_ident(current_user)::regrole"
    } else {
        "DELETE FROM df.vars"
    };

    if let Err(e) = Spi::run(sql) {
        pgrx::error!("Failed to clear variables: {:?}", e);
    }
    mark_non_future_helper_call("df.clearvars");
    "OK".to_string()
}

// ============================================================================
// Node Creation Functions
// ============================================================================

/// Creates a SQL node in the function graph.
#[pg_extern(schema = "df")]
pub fn sql(query: &str) -> String {
    Durofut {
        node_type: "SQL".to_string(),
        query: Some(query.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a sequence node that executes two nodes in order.
/// The SQL operator ~> is syntactic sugar for this function.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "seq", schema = "df")]
pub fn then_fn(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "THEN".to_string(),
        left_node: Some(a_fut.into_raw()),
        right_node: Some(b_fut.into_raw()),
        ..Default::default()
    }
    .to_json()
}

/// Names a result for later reference.
/// The SQL operator |=> is syntactic sugar for this function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Note: Parameter order matches the |=> operator: fut |=> name -> df.as(fut, name)
#[pg_extern(name = "as", schema = "df")]
pub fn as_named(fut: &str, name: &str) -> String {
    if let Err(msg) = validate_result_name(name) {
        pgrx::error!("df.as: {msg}");
    }
    let mut durofut = Durofut::ensure(fut);
    durofut.result_name = Some(name.to_string());

    durofut.to_json()
}

/// Creates a sleep node that pauses for the specified number of seconds.
#[pg_extern(schema = "df")]
pub fn sleep(seconds: i64) -> String {
    if seconds < 0 {
        pgrx::error!("Sleep duration must be non-negative");
    }
    Durofut {
        node_type: "SLEEP".to_string(),
        query: Some(seconds.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a wait-for-schedule node that waits until the next cron match.
///
/// The cron expression is only *validated* here (at DSL time) so an invalid
/// expression fails fast at `df.start()`. The actual "next tick" is computed at
/// execution time inside the orchestration (see `execute_wait_schedule_node`),
/// using duroxide's deterministic clock. This is intentional: a cron schedule is
/// a function of the current wall-clock time, so it must be evaluated when the
/// node actually runs — not at `df.start()` time — otherwise any delay between
/// `df.start()` and execution (and, critically, every iteration of a recurring
/// `@>` loop) would wake at the wrong moment. Only the cron expression is stored
/// in the node config.
#[pg_extern(schema = "df")]
pub fn wait_for_schedule(cron_expr: &str) -> String {
    // Validate eagerly so a bad expression is rejected at df.start() time. The
    // "0 " prefix supplies the seconds field the `cron` crate expects; the same
    // prefix is re-applied at execution time when the schedule is recomputed.
    let cron_with_seconds = format!("0 {cron_expr}");
    if let Err(e) = CronSchedule::from_str(&cron_with_seconds) {
        pgrx::error!("Invalid cron expression '{}': {}", cron_expr, e);
    }

    // Store only the cron expression. The wait is computed at execution time.
    let config = serde_json::json!({
        "cron_expr": cron_expr,
    });

    Durofut {
        node_type: "WAIT_SCHEDULE".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a loop node.
///
/// With one argument: repeats the body indefinitely (infinite loop).
/// With two arguments: repeats while the condition is true (while loop).
///
/// The body and condition can be either Durofut JSON or plain SQL strings (auto-wrapped).
/// The condition is evaluated after each iteration (do-while semantics).
///
/// # Examples
/// ```sql
/// -- Infinite loop
/// df.loop('SELECT process_item()')
///
/// -- While loop - continues while condition is true
/// df.loop('SELECT process_item()', 'SELECT count(*) > 0 FROM queue')
/// ```
#[pg_extern(name = "loop", schema = "df")]
pub fn loop_fn(body: &str, condition: default!(Option<&str>, "NULL")) -> String {
    let body_fut = Durofut::ensure(body);
    let condition_node = condition.map(|cond| Durofut::ensure(cond).into_raw());

    Durofut {
        node_type: "LOOP".to_string(),
        left_node: Some(body_fut.into_raw()),
        condition_node,
        ..Default::default()
    }
    .to_json()
}

/// Creates a break node that exits the enclosing loop.
///
/// When executed, the loop terminates and returns the provided value (or null).
///
/// Unlike most DSL functions, `df.break()` does **not** auto-wrap its argument
/// as SQL — the string is returned verbatim as a literal value (typically JSON
/// or text). To break with the result of a SQL query, run the query first and
/// reference the result via variable substitution, e.g.
/// `'SELECT summary FROM r' |=> 'r' ~> df.break('$r.summary')`.
///
/// # Examples
/// ```sql
/// -- Break with no value
/// df.break()
///
/// -- Break with a literal return value (NOT executed as SQL)
/// df.break('{"status": "complete"}')
/// ```
#[pg_extern(name = "break", schema = "df")]
pub fn break_fn(value: default!(Option<&str>, "NULL")) -> String {
    let config = serde_json::json!({
        "break_value": value
    });

    Durofut {
        node_type: "BREAK".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a conditional branch node.
/// All arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "if", schema = "df")]
pub fn if_fn(condition: &str, then_branch: &str, else_branch: &str) -> String {
    let condition_fut = Durofut::ensure(condition);
    let then_fut = Durofut::ensure(then_branch);
    let else_fut = Durofut::ensure(else_branch);

    Durofut {
        node_type: "IF".to_string(),
        left_node: Some(then_fut.into_raw()),
        right_node: Some(else_fut.into_raw()),
        condition_node: Some(condition_fut.into_raw()),
        ..Default::default()
    }
    .to_json()
}

/// Branches based on whether a named result has any rows.
/// Unlike df.if(), the condition is not a SQL query — it checks the
/// in-memory result JSON for row_count > 0. Zero-cost, no activity scheduled.
#[pg_extern(name = "if_rows", schema = "df")]
pub fn if_rows_fn(result_name: &str, then_branch: &str, else_branch: &str) -> String {
    let then_fut = Durofut::ensure(then_branch);
    let else_fut = Durofut::ensure(else_branch);

    let config = serde_json::json!({
        "condition_type": "result_has_rows",
        "result_name": result_name
    });

    Durofut {
        node_type: "IF".to_string(),
        left_node: Some(then_fut.into_raw()),
        right_node: Some(else_fut.into_raw()),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a parallel join node for 2 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn join(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "JOIN".to_string(),
        left_node: Some(a_fut.into_raw()),
        right_node: Some(b_fut.into_raw()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a parallel join node for 3 branches.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(name = "join3", schema = "df")]
pub fn join3(a: &str, b: &str, c: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);
    let c_fut = Durofut::ensure(c);

    Durofut {
        node_type: "JOIN".to_string(),
        left_node: Some(a_fut.into_raw()),
        right_node: Some(b_fut.into_raw()),
        extra_nodes: vec![c_fut.into_raw()],
        ..Default::default()
    }
    .to_json()
}

/// Creates a race node - runs branches in parallel, first to complete wins.
/// Arguments can be either Durofut JSON or plain SQL strings (auto-wrapped).
#[pg_extern(schema = "df")]
pub fn race(a: &str, b: &str) -> String {
    let a_fut = Durofut::ensure(a);
    let b_fut = Durofut::ensure(b);

    Durofut {
        node_type: "RACE".to_string(),
        left_node: Some(a_fut.into_raw()),
        right_node: Some(b_fut.into_raw()),
        ..Default::default()
    }
    .to_json()
}

/// Creates an HTTP request node.
/// Makes an HTTP request to the specified URL and returns the response.
///
/// # Arguments
/// * `url` - The URL to request
/// * `method` - HTTP method (GET, POST, PUT, DELETE, PATCH). Default: POST
/// * `body` - Request body (typically JSON). Supports $variable substitution
/// * `headers` - JSONB object of headers. Example: '{"Authorization": "Bearer token"}'
/// * `timeout_seconds` - Request timeout in seconds. Default: 30
///
/// # Returns
/// JSON object with: status, body, encoding, headers, ok (boolean), duration_ms.
/// `encoding` is "text" when the body is the response as-is, or "base64" when
/// the response was not textual and `body` holds the base64 of the raw bytes.
#[pg_extern(schema = "df")]
pub fn http(
    url: &str,
    method: default!(&str, "'POST'"),
    body: default!(Option<&str>, "NULL"),
    headers: default!(Option<pgrx::JsonB>, "NULL"),
    timeout_seconds: default!(i32, "30"),
) -> String {
    // Fail early when no http feature is compiled in — df.nodes can be inserted
    // by hand, so we also enforce this at execution time, but blocking at DSL
    // construction time gives a clearer error to developers.
    if !crate::ssrf::http_enabled() {
        pgrx::error!(
            "df.http() is disabled. Rebuild with the 'http-allow-azure-domains' \
             Cargo feature to enable outbound HTTP requests."
        );
    }

    // Validate URL scheme at DSL time for early error feedback.
    // Execution-time validation in execute_http also runs, but catching this
    // here surfaces the error before df.start() is ever called.
    // Skip the check when the URL contains variable placeholders ({...}) —
    // substitution happens at execution time so the scheme is not yet known.
    if !url.contains('{') {
        if let Err(e) = crate::ssrf::precheck_url_scheme(url) {
            pgrx::error!("{}", e);
        }
    }

    // Validate method
    let method_upper = method.to_uppercase();
    if !["GET", "POST", "PUT", "DELETE", "PATCH"].contains(&method_upper.as_str()) {
        pgrx::error!(
            "Invalid HTTP method: {}. Must be GET, POST, PUT, DELETE, or PATCH",
            method
        );
    }

    if timeout_seconds <= 0 {
        pgrx::error!("Timeout must be positive");
    }

    let config = serde_json::json!({
        "url": url,
        "method": method_upper,
        "body": body,
        "headers": headers.as_ref().map(|h| &h.0),
        "timeout_seconds": timeout_seconds
    });

    Durofut {
        node_type: "HTTP".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Creates a multipart/form-data HTTP request node (file uploads / form fields).
///
/// Each part in `parts` is a JSON object: `{"name": "...", "filename": "...",
/// "content_type": "...", "data_b64": "..."}`. Only `name` and `data_b64`
/// (base64-encoded payload) are required; `filename` and `content_type` are
/// optional. The response shape and security model match `df.http`.
///
/// `data_b64` may contain whitespace, so `encode(bytea, 'base64')` output —
/// which PostgreSQL wraps at 76 columns — can be passed straight through. It
/// also supports $variable substitution, but only as a whole value (e.g.
/// `"$resp.body"`); mixing a reference with surrounding text fails the node,
/// since splicing into a base64 string cannot yield a valid encoding.
///
/// # Arguments
/// * `url` - The URL to request. Supports $variable substitution
/// * `method` - HTTP method (POST, PUT, PATCH). Default: POST
/// * `parts` - JSONB array of part objects (see above)
/// * `headers` - JSONB object of headers. Content-Type is ignored (multipart
///   owns the boundary). Example: '{"Authorization": "Bearer token"}'
/// * `timeout_seconds` - Request timeout in seconds. Default: 30
///
/// # Returns
/// JSON object with: status, body, encoding, headers, ok (boolean), duration_ms.
/// `encoding` is "text" when the body is the response as-is, or "base64" when
/// the response was not textual and `body` holds the base64 of the raw bytes.
#[pg_extern(schema = "df")]
pub fn http_multipart(
    url: &str,
    method: default!(&str, "'POST'"),
    // parts defaults to NULL solely to satisfy PostgreSQL's rule that every
    // parameter after a defaulted one (method) must also have a default. A NULL
    // parts list is rejected below — at least one part is required.
    parts: default!(Option<pgrx::JsonB>, "NULL"),
    headers: default!(Option<pgrx::JsonB>, "NULL"),
    timeout_seconds: default!(i32, "30"),
) -> String {
    // Fail early when no http feature is compiled in — same guard as df.http.
    if !crate::ssrf::http_enabled() {
        pgrx::error!(
            "df.http_multipart() is disabled. Rebuild with the 'http-allow-azure-domains' \
             Cargo feature to enable outbound HTTP requests."
        );
    }

    // Validate URL scheme at DSL time (skip when URL contains variable
    // placeholders — substitution happens at execution time). Mirrors df.http.
    if !url.contains('{') {
        if let Err(e) = crate::ssrf::precheck_url_scheme(url) {
            pgrx::error!("{}", e);
        }
    }

    // Validate method — multipart only makes sense for body-carrying methods.
    let method_upper = method.to_uppercase();
    if !["POST", "PUT", "PATCH"].contains(&method_upper.as_str()) {
        pgrx::error!(
            "Invalid HTTP method for multipart: {}. Must be POST, PUT, or PATCH",
            method
        );
    }

    if timeout_seconds <= 0 {
        pgrx::error!("Timeout must be positive");
    }

    // parts is required — the NULL default is only there to keep the SQL
    // signature valid (see the signature comment).
    let parts_value = match &parts {
        Some(p) => &p.0,
        None => pgrx::error!("parts is required and cannot be NULL"),
    };

    // Validate parts is a non-empty array. Per-part shape is checked when the
    // activity deserializes MultipartConfig.
    let parts_arr = match parts_value.as_array() {
        None => pgrx::error!("parts must be a JSON array of part objects"),
        Some(arr) if arr.is_empty() => pgrx::error!("parts must contain at least one part"),
        Some(arr) => arr,
    };
    let _ = parts_arr; // shape validated; activity re-parses from the JSON below

    let config = serde_json::json!({
        "url": url,
        "method": method_upper,
        "parts": parts_value,
        "headers": headers.as_ref().map(|h| &h.0),
        "timeout_seconds": timeout_seconds
    });

    Durofut {
        node_type: "HTTP_MULTIPART".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

// ============================================================================
// Signals
// ============================================================================

/// Wait for an external signal to be sent to this durable function instance.
///
/// Signals allow external code to send events to running durable functions, enabling:
/// - Human-in-the-loop approval workflows
/// - Webhook callbacks from external systems
/// - Event-driven coordination between processes
///
/// # Arguments
/// * `name` - Name of the signal to wait for
/// * `timeout_seconds` - Optional timeout in seconds (NULL = wait forever)
///
/// # Returns
/// JSON object with: signal_name, timed_out (boolean), data (the signal payload)
#[pg_extern(schema = "df")]
pub fn wait_for_signal(name: &str, timeout_seconds: default!(Option<i32>, "NULL")) -> String {
    if name.is_empty() {
        pgrx::error!("Signal name cannot be empty");
    }

    if let Some(timeout) = timeout_seconds {
        if timeout <= 0 {
            pgrx::error!("Timeout must be positive");
        }
    }

    let config = serde_json::json!({
        "signal_name": name,
        "timeout_seconds": timeout_seconds
    });

    Durofut {
        node_type: "SIGNAL".to_string(),
        query: Some(config.to_string()),
        ..Default::default()
    }
    .to_json()
}

/// Send a signal to a running durable function instance.
///
/// # Arguments
/// * `instance_id` - The durable function instance ID to signal
/// * `signal_name` - Name of the signal (must match what the instance is waiting for)
/// * `signal_data` - Optional signal payload text (defaults to '{}')
///
/// # Returns
/// 'OK' on success, raises error on failure
#[pg_extern(schema = "df")]
pub fn signal(instance_id: &str, signal_name: &str, signal_data: default!(&str, "'{}'")) -> String {
    use crate::client::raise_external_event;

    if instance_id.is_empty() {
        pgrx::error!("Instance ID cannot be empty");
    }

    if signal_name.is_empty() {
        pgrx::error!("Signal name cannot be empty");
    }

    let signal_data = serde_json::from_str::<serde_json::Value>(signal_data)
        .unwrap_or_else(|_| serde_json::Value::String(signal_data.to_string()))
        .to_string();

    // Ownership check: SPI goes through RLS, so this returns false for
    // non-owned instances (the row is invisible to the calling user).
    let exists: bool = Spi::get_one_with_args(
        "SELECT EXISTS(SELECT 1 FROM df.instances WHERE id = $1)",
        &[instance_id.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false);
    if !exists {
        pgrx::error!("Instance not found or access denied: {}", instance_id);
    }

    match raise_external_event(instance_id, signal_name, &signal_data) {
        Ok(_) => "OK".to_string(),
        Err(e) => pgrx::error!("Failed to send signal: {}", e),
    }
}

// ============================================================================
// Orchestration Control Functions
// ============================================================================

/// Maximum number of attempts to generate a collision-free random ID before
/// giving up. The 8-hex ID space (`short_id`) makes collisions rare, so a small
/// bound is plenty; exhausting it signals either an astronomically unlucky run
/// or a genuinely saturated ID space, both of which should surface as an error
/// rather than an unverified ID.
const MAX_ID_ATTEMPTS: usize = 10;

/// Keep each node INSERT comfortably below PostgreSQL's 65,535 bind-parameter
/// limit. The legacy schema uses ten parameters per row, so this caps a batch
/// at 10,000 parameters and a maximum-size graph at ten INSERT statements.
const NODE_INSERT_BATCH_SIZE: usize = 1_000;

/// Generate a random ID and claim it, retrying on collision (issue #129).
///
/// `generate` produces a fresh candidate ID; `try_claim` attempts to durably
/// reserve it, returning `Ok(true)` when the candidate was claimed, `Ok(false)`
/// when it collided with an existing ID (re-roll), or `Err` when the claim
/// failed for any other reason (propagated immediately).
///
/// The claim — not the generation — is the loop tail, so this only ever returns
/// an ID that `try_claim` confirmed was inserted. On exhaustion it returns an
/// `Err` rather than a last, unverified candidate (review finding C1).
fn pick_id_with_retry(
    mut generate: impl FnMut() -> String,
    mut try_claim: impl FnMut(&str) -> Result<bool, String>,
    max_attempts: usize,
) -> Result<String, String> {
    for _ in 0..max_attempts {
        let candidate = generate();
        if try_claim(&candidate)? {
            return Ok(candidate);
        }
    }
    Err(format!(
        "exhausted {max_attempts} attempts to generate a collision-free ID"
    ))
}

fn node_insert_sql(row_count: usize, legacy_login_role: bool) -> String {
    let (columns, parameters_per_row) = if legacy_login_role {
        (
            "id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, database",
            10,
        )
    } else {
        (
            "id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database",
            9,
        )
    };
    let mut sql = format!("INSERT INTO df.nodes ({columns}) VALUES ");

    for row_index in 0..row_count {
        if row_index > 0 {
            sql.push_str(", ");
        }
        let first = row_index * parameters_per_row + 1;
        if legacy_login_role {
            sql.push_str(&format!(
                "(${first}, ${}, ${}, ${}, ${}, ${}, ${}, ${}::oid::regrole, ${}::oid::regrole, ${})",
                first + 1,
                first + 2,
                first + 3,
                first + 4,
                first + 5,
                first + 6,
                first + 7,
                first + 8,
                first + 9,
            ));
        } else {
            sql.push_str(&format!(
                "(${first}, ${}, ${}, ${}, ${}, ${}, ${}, ${}::oid::regrole, ${})",
                first + 1,
                first + 2,
                first + 3,
                first + 4,
                first + 5,
                first + 6,
                first + 7,
                first + 8,
            ));
        }
    }

    sql
}

/// Capture the effective role identity (after `SET ROLE` / `SECURITY DEFINER`)
/// as both its OID and its name.
fn current_user_identity() -> (pgrx::pg_sys::Oid, String) {
    let oid = unsafe { pgrx::pg_sys::GetUserId() };
    let name = unsafe {
        let name_ptr = pgrx::pg_sys::GetUserNameFromId(oid, false);
        std::ffi::CStr::from_ptr(name_ptr)
            .to_string_lossy()
            .into_owned()
    };
    (oid, name)
}

/// Raise unless the submitting role can log in.
///
/// Both start paths need this: the background worker connects as this role to
/// execute SQL nodes, and `transaction_mode => 'new'` additionally connects as
/// it to persist the graph. Checking here turns a NOLOGIN role into a clear
/// error instead of an opaque connection failure later.
fn require_login_privilege(oid: pgrx::pg_sys::Oid, name: &str, caller: &str) {
    let has_login: bool = match Spi::get_one_with_args(
        "SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE oid = $1",
        &[oid.into()],
    ) {
        Ok(Some(has_login)) => has_login,
        Ok(None) => pgrx::error!(
            "failed to check LOGIN privilege for current_user oid {}: query returned NULL",
            oid
        ),
        Err(e) => pgrx::error!(
            "failed to check LOGIN privilege for current_user oid {}: {}",
            oid,
            e
        ),
    };

    if !has_login {
        pgrx::error!(
            "current_user \"{}\" does not have LOGIN privilege. \
             The background worker must connect as this role to execute SQL. \
             Grant LOGIN to this role or call {} as a role with LOGIN.",
            name,
            caller
        );
    }
}

/// `transaction_mode`: the start participates in the caller's transaction and
/// is rolled back with it. This is the default and the historical behaviour.
const TXN_MODE_CALLER: &str = "caller";

/// `transaction_mode`: the start runs in its own transaction, on a separate
/// session, and therefore survives a rollback of the caller's transaction.
const TXN_MODE_NEW: &str = "new";

/// Advisory-lock namespace for admission control on `transaction_mode => 'new'`
/// launches. Each slot is a separate session-level advisory lock object under
/// this class ID.
///
/// The value spells `PGDF` in ASCII to make the slots easy to spot in
/// `pg_locks` (they appear with `locktype = 'advisory'`, `classid = 1346982470`,
/// `objsubid = 2`, and `objid` equal to the slot index). Reserving a distinctive
/// two-int advisory-lock class id means a collision is only possible if an
/// application separately calls `pg_advisory_lock(0x50474446::int4, ...)`.
const NEW_TRANSACTION_START_LOCK_CLASS_ID: i32 = 0x5047_4446;

struct NewTransactionStartAdmissionGuard {
    slot: i32,
}

impl Drop for NewTransactionStartAdmissionGuard {
    fn drop(&mut self) {
        let _ = Spi::run_with_args(
            "SELECT pg_catalog.pg_advisory_unlock($1::int4, $2::int4)",
            &[NEW_TRANSACTION_START_LOCK_CLASS_ID.into(), self.slot.into()],
        );
    }
}

fn try_acquire_new_transaction_start_slot(limit: u32) -> Result<Option<i32>, String> {
    for slot in 0..limit {
        match Spi::get_one_with_args::<bool>(
            "SELECT pg_catalog.pg_try_advisory_lock($1::int4, $2::int4)",
            &[
                NEW_TRANSACTION_START_LOCK_CLASS_ID.into(),
                (slot as i32).into(),
            ],
        ) {
            Ok(Some(true)) => return Ok(Some(slot as i32)),
            Ok(Some(false)) => {}
            Ok(None) => {
                return Err(
                    "failed to acquire transaction_mode => 'new' launch slot: pg_try_advisory_lock returned NULL"
                        .to_string(),
                )
            }
            Err(e) => {
                return Err(format!(
                    "failed to acquire transaction_mode => 'new' launch slot: {e}"
                ))
            }
        }
    }

    Ok(None)
}

fn acquire_new_transaction_start_slot() -> Result<NewTransactionStartAdmissionGuard, String> {
    let limit = get_max_new_transaction_starts();
    let timeout = get_new_transaction_start_timeout();
    let started = Instant::now();

    loop {
        if let Some(slot) = try_acquire_new_transaction_start_slot(limit)? {
            return Ok(NewTransactionStartAdmissionGuard { slot });
        }

        if started.elapsed() >= timeout {
            return Err(format!(
                "pg_durable: transaction_mode => '{TXN_MODE_NEW}' launch limit reached \
                 (max_new_transaction_starts={limit}). Timed out after {}s waiting for a \
                 launch slot before opening the loopback session.",
                timeout.as_secs()
            ));
        }

        // Poll instead of blocking on a lock: a failed pg_try_advisory_lock
        // returns immediately holding nothing, so a waiting caller blocks no one
        // and cannot deadlock. Note this sleep does not CHECK_FOR_INTERRUPTS, so
        // a cancel / statement_timeout on a waiting caller is only honored on the
        // next SPI poll (<=100ms later, when pg_try_advisory_lock runs).
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Starts a durable SQL function.
///
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Variables from df.vars are captured and passed to the orchestration.
/// Optional database parameter targets a specific database on the cluster.
///
/// `transaction_mode` selects which transaction the *start itself* runs in. It
/// changes nothing about the durable function that gets started:
///
/// - `'caller'` (default) — the start joins the caller's transaction, so a
///   `ROLLBACK` discards the durable function along with everything else.
/// - `'new'` — the start runs in its own transaction on a separate session, so
///   it commits independently and **survives a rollback of the caller's
///   transaction**. This provides the same rollback-survival outcome as Oracle
///   autonomous transactions for asynchronously started work, but it is not a
///   synchronous autonomous routine: only the launch commits before this call
///   returns, and execution errors are observed through monitoring APIs.
///
/// Because a separate session cannot see the caller's uncommitted rows, under
/// `'new'` the `df.vars` snapshot captured for the instance reflects only
/// **committed** variables — anything set with `df.setvar()` earlier in the
/// caller's open transaction is not visible to it.
#[pg_extern(name = "start", schema = "df")]
pub fn start_v2(
    fut: &str,
    label: default!(Option<&str>, "NULL"),
    database: default!(Option<&str>, "NULL"),
    transaction_mode: default!(&str, "'caller'"),
) -> String {
    // Reject anything we do not recognise. Silently treating a typo as the
    // default would hand back an instance id for a start the caller believes
    // survives their rollback, and which quietly does not.
    if transaction_mode.eq_ignore_ascii_case(TXN_MODE_CALLER) {
        start_in_caller_transaction(fut, label, database)
    } else if transaction_mode.eq_ignore_ascii_case(TXN_MODE_NEW) {
        start_in_new_transaction(fut, label, database)
    } else {
        pgrx::error!(
            "invalid transaction_mode \"{}\" for df.start(): expected '{}' or '{}'",
            transaction_mode,
            TXN_MODE_CALLER,
            TXN_MODE_NEW
        );
    }
}

/// Legacy three-argument `df.start()`, retained for binary compatibility only.
///
/// Schemas from before `transaction_mode` existed declare `df.start(text, text,
/// text)` against this symbol. A customer who swaps in a newer `.so` without
/// running `ALTER EXTENSION UPDATE` still resolves to it, so it must keep
/// taking exactly three arguments. `sql = false` keeps the symbol in the binary
/// while emitting no DDL, so upgraded and fresh installs expose only the
/// four-argument `df.start()` above and no ambiguous overload exists.
#[pg_extern(sql = false)]
pub fn start(fut: &str, label: Option<&str>, database: Option<&str>) -> String {
    start_in_caller_transaction(fut, label, database)
}

/// `df.start()` under `transaction_mode => 'new'`.
fn start_in_new_transaction(fut: &str, label: Option<&str>, database: Option<&str>) -> String {
    // Inside a workflow this mode is pure cost. A df.sql() node is executed as
    // a single statement on an autocommit connection, so a plain df.start()
    // there already commits on its own and cannot be rolled back by the
    // caller — 'new' would buy nothing and burn an extra backend, which is not
    // counted against pg_durable.max_user_connections.
    if is_in_workflow_context() {
        pgrx::error!(
            "df.start() with transaction_mode => '{}' cannot be called inside a workflow - \
             a df.sql() node already runs as a single autocommitted statement, so a plain \
             df.start() there is already independent of any caller transaction",
            TXN_MODE_NEW
        );
    }

    // Capture the calling role so the separate session runs df.start() with the
    // same identity (and therefore the same privileges / RLS scope).
    let (user_oid, user_name) = current_user_identity();

    // That session logs in as this role, so a NOLOGIN role must fail here with
    // the usual message rather than as a connection error.
    require_login_privilege(user_oid, &user_name, "df.start()");

    // Admission control is cross-session, not process-local: each PostgreSQL
    // client backend is its own process. Hold a session-level advisory-lock slot
    // while the loopback session is being opened and running df.start().
    let _admission_guard = match acquire_new_transaction_start_slot() {
        Ok(guard) => guard,
        Err(e) => pgrx::error!("{e}"),
    };

    match crate::client::start_in_new_transaction(fut, label, database, &user_name) {
        Ok(id) => id,
        Err(e) => pgrx::error!("{}", e),
    }
}

/// `df.start()` under `transaction_mode => 'caller'`: build and persist the
/// graph through SPI, so it lives or dies with the caller's transaction.
fn start_in_caller_transaction(fut: &str, label: Option<&str>, database: Option<&str>) -> String {
    let durofut = match Durofut::ensure_strict(fut) {
        Ok(d) => d,
        Err(e) => pgrx::error!("Invalid durable function: {}", e),
    };

    // The instance ID is reserved later (after identity validation), using an
    // INSERT ... ON CONFLICT (id) DO NOTHING retry so collisions — including
    // against other roles' instances invisible under RLS — re-roll instead of
    // surfacing a primary-key error (issue #129).

    // Validate that the target database exists (if specified)
    if let Some(db) = database {
        let exists: bool = match Spi::get_one_with_args(
            "SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_database WHERE datname = $1)",
            &[db.into()],
        ) {
            Ok(Some(v)) => v,
            Ok(None) => false,
            Err(e) => pgrx::error!("failed to check database existence: {}", e),
        };
        if !exists {
            pgrx::error!("database \"{}\" does not exist", db);
        }
    }

    // Capture user identity for privilege isolation
    let (current_user_oid, current_user_name) = current_user_identity();

    require_login_privilege(current_user_oid, &current_user_name, "df.start()");

    // Reject superuser submission identities unless explicitly enabled.
    if !crate::types::superuser_instances_enabled() {
        let is_super = match crate::types::is_role_superuser_oid(current_user_oid) {
            Ok(v) => v,
            Err(e) => pgrx::error!("pg_durable: superuser check failed: {}", e),
        };
        if is_super {
            pgrx::error!(
                "pg_durable: superuser instances are disabled. \
                 current_user \"{}\" is a superuser, but \
                 pg_durable.enable_superuser_instances is off. \
                 Set pg_durable.enable_superuser_instances = on to allow this.",
                current_user_name
            );
        }
    }

    fn insert_nodes(
        nodes: &[MaterializedNode],
        instance_id: &str,
        current_user_oid: pgrx::pg_sys::Oid,
        database: Option<&str>,
        legacy_login_role: bool,
    ) {
        // B1 backward compat: the v0.1.x schema has login_role NOT NULL on
        // df.nodes, so the legacy branch still sets it (= submitted_by).
        for batch in nodes.chunks(NODE_INSERT_BATCH_SIZE) {
            let mut node_args =
                Vec::with_capacity(batch.len() * if legacy_login_role { 10 } else { 9 });
            for node in batch {
                let query_arg: DatumWithOid = match &node.query {
                    Some(q) => q.as_str().into(),
                    None => DatumWithOid::null::<String>(),
                };
                let result_name_arg: DatumWithOid = match &node.result_name {
                    Some(n) => n.as_str().into(),
                    None => DatumWithOid::null::<String>(),
                };
                let left_node_arg: DatumWithOid = match &node.left_node {
                    Some(id) => id.as_str().into(),
                    None => DatumWithOid::null::<String>(),
                };
                let right_node_arg: DatumWithOid = match &node.right_node {
                    Some(id) => id.as_str().into(),
                    None => DatumWithOid::null::<String>(),
                };
                let database_arg: DatumWithOid = match database {
                    Some(db) => db.into(),
                    None => DatumWithOid::null::<String>(),
                };
                node_args.extend([
                    node.id.as_str().into(),
                    instance_id.into(),
                    node.node_type.as_str().into(),
                    query_arg,
                    result_name_arg,
                    left_node_arg,
                    right_node_arg,
                    current_user_oid.into(),
                ]);
                if legacy_login_role {
                    node_args.push(current_user_oid.into()); // login_role = submitted_by
                }
                node_args.push(database_arg);
            }

            let node_sql = node_insert_sql(batch.len(), legacy_login_role);
            if let Err(e) = Spi::run_with_args(&node_sql, &node_args) {
                let first_id = batch.first().map(|node| node.id.as_str()).unwrap_or("");
                let last_id = batch.last().map(|node| node.id.as_str()).unwrap_or("");
                pgrx::error!(
                    "Failed to insert node batch '{}..{}': {:?}",
                    first_id,
                    last_id,
                    e
                );
            }
        }
    }

    let legacy_login_role = legacy_login_role_schema();

    // Assign IDs as nodes are discovered. Per-graph uniqueness is required
    // because parent references are materialized before any rows are inserted.
    let mut assigned_ids = std::collections::HashSet::new();
    let mut id_source = || {
        for _ in 0..MAX_ID_ATTEMPTS {
            let candidate = short_id();
            if assigned_ids.insert(candidate.clone()) {
                return Ok(candidate);
            }
        }
        Err(format!(
            "exhausted {MAX_ID_ATTEMPTS} attempts to generate a graph-unique node ID"
        ))
    };
    let (root_id, nodes) = match flatten_graph(&durofut, &mut id_source) {
        Ok(flattened) => flattened,
        Err(e) => pgrx::error!("Invalid durable function graph: {}", e),
    };

    // Reserve the instance ID before inserting nodes so node rows can reference
    // it. Collisions on the 8-hex ID space are rare, but we reserve via
    // INSERT ... ON CONFLICT (id) DO NOTHING RETURNING id and re-roll on
    // collision so a raw primary-key error never reaches the caller (issue
    // #129). ON CONFLICT arbitration runs against the global id index *below*
    // RLS, so this also re-rolls on collisions with another role's instance
    // that the caller cannot SELECT — closing the gap left by the old
    // RLS-limited pre-check. root_node is set to the pre-generated root_id; the
    // same-instance FK on root_node is DEFERRABLE INITIALLY DEFERRED, so the
    // referenced root node row is inserted (with that ID) before commit — no
    // post-insert UPDATE is needed (df callers aren't granted UPDATE on
    // root_node).
    let instance_id = match pick_id_with_retry(
        short_id,
        |candidate| {
            let label_arg: DatumWithOid = match label {
                Some(l) => l.into(),
                None => DatumWithOid::null::<String>(),
            };
            let database_arg: DatumWithOid = match database {
                Some(db) => db.into(),
                None => DatumWithOid::null::<String>(),
            };
            let (inst_sql, inst_args): (&str, Vec<DatumWithOid>) = if legacy_login_role {
                (
                    "INSERT INTO df.instances (id, label, root_node, submitted_by, login_role, database)
                     VALUES ($1, $2, $3, $4::oid::regrole, $5::oid::regrole, $6)
                     ON CONFLICT (id) DO NOTHING
                     RETURNING id",
                    vec![
                        candidate.into(),
                        label_arg,
                        root_id.as_str().into(),
                        current_user_oid.into(),
                        current_user_oid.into(), // login_role = submitted_by
                        database_arg,
                    ],
                )
            } else {
                (
                    "INSERT INTO df.instances (id, label, root_node, submitted_by, database)
                     VALUES ($1, $2, $3, $4::oid::regrole, $5)
                     ON CONFLICT (id) DO NOTHING
                     RETURNING id",
                    vec![
                        candidate.into(),
                        label_arg,
                        root_id.as_str().into(),
                        current_user_oid.into(),
                        database_arg,
                    ],
                )
            };
            Spi::connect_mut(
                |client| match client.update(inst_sql, Some(1), &inst_args) {
                    Ok(table) => Ok(!table.is_empty()),
                    Err(e) => Err(format!("{e:?}")),
                },
            )
        },
        MAX_ID_ATTEMPTS,
    ) {
        Ok(id) => id,
        Err(e) => pgrx::error!("Failed to create instance: {}", e),
    };

    // The same-instance node references are DEFERRABLE INITIALLY DEFERRED, so
    // pre-order insertion is valid even when a parent row precedes its child.
    insert_nodes(
        &nodes,
        &instance_id,
        current_user_oid,
        database,
        legacy_login_role,
    );

    // Capture vars from df.vars using the installed extension version as the
    // compatibility boundary: pre-0.2.0 uses legacy global vars, 0.2.0+ uses
    // owner-scoped vars.
    let vars_query = if owner_scoped_vars_enabled() {
        "SELECT name, value FROM df.vars WHERE owner = quote_ident(current_user)::regrole"
    } else {
        "SELECT name, value FROM df.vars"
    };

    let vars: std::collections::HashMap<String, String> = Spi::connect(|client| {
        let mut vars = std::collections::HashMap::new();
        if let Ok(table) = client.select(vars_query, None, &[]) {
            for row in table {
                if let (Ok(Some(name)), Ok(Some(value))) =
                    (row.get::<String>(1), row.get::<String>(2))
                {
                    vars.insert(name, value);
                }
            }
        }
        vars
    });

    // df.start() hands the orchestration to duroxide over a separately committed
    // connection before this caller transaction commits. Carry the owning
    // top-level xid so the worker can wait for its actual outcome instead of
    // guessing that a transaction lasting more than a fixed timeout rolled back.
    let origin_xid = Spi::get_one::<String>("SELECT pg_catalog.pg_current_xact_id()::text")
        .unwrap_or_else(|e| pgrx::error!("failed to capture df.start() transaction id: {e}"))
        .unwrap_or_else(|| pgrx::error!("df.start() transaction id is unavailable"));

    // Start the orchestration via duroxide
    let input = FunctionInput {
        instance_id: instance_id.clone(),
        label: label.map(|s| s.to_string()),
        vars,
        loop_iteration: 0,
        // Generation 0 loads the graph from df.nodes; only a root loop continuing as new
        // carries it inline.
        graph: None,
        origin_xid: Some(origin_xid),
        graph_wait_attempt: 0,
        graph_retry_attempt: 0,
    };
    let input_json = serde_json::to_string(&input).unwrap_or(instance_id.clone());

    if let Err(e) = start_durable_function(
        crate::orchestrations::execute_function_graph::NAME,
        &instance_id,
        &input_json,
    ) {
        // Fail fast: the durable engine could not accept the start, so abort the
        // whole df.start() transaction rather than committing an instance row
        // that would never run (a stuck instance nothing recovers). The df rows
        // and this error are in the caller's transaction, so the abort rolls
        // them back cleanly; the caller can retry.
        //
        // The pgrx unit-test build does not run the background worker (see the
        // test-build note on validate_database in lib.rs), so the enqueue always
        // fails there; in that build we log instead of aborting so df.start()'s
        // graph construction stays unit-testable.
        #[cfg(not(any(test, feature = "pg_test")))]
        pgrx::error!("failed to start durable function: {e}");
        #[cfg(any(test, feature = "pg_test"))]
        pgrx::log!("pg_durable: start enqueue failed (test build, ignored): {e}");
    }

    instance_id
}

/// Cancels a running durable function.
#[pg_extern(schema = "df")]
pub fn cancel(instance_id: &str, reason: default!(&str, "'Cancelled by user'")) -> String {
    use crate::client::cancel_durable_function;

    // Ownership check: SPI goes through RLS, so this returns false for
    // non-owned instances (the row is invisible to the calling user).
    let exists: bool = Spi::get_one_with_args(
        "SELECT EXISTS(SELECT 1 FROM df.instances WHERE id = $1)",
        &[instance_id.into()],
    )
    .ok()
    .flatten()
    .unwrap_or(false);
    if !exists {
        pgrx::error!("Instance not found or access denied: {}", instance_id);
    }

    if let Err(e) = cancel_durable_function(instance_id, reason) {
        return format!("Failed to cancel: {e}");
    }

    // Update the instance status to 'cancelled' via SPI only when the instance is not
    // already in a terminal state.  This prevents two bugs:
    // 1. Overwriting a 'completed' or 'failed' instance that finished before the cancel
    //    signal was processed by duroxide.
    // 2. Calling df.cancel twice in a row (idempotent by guard).
    // User has column-level UPDATE on (status, updated_at) with RLS restricting to own rows.
    Spi::run_with_args(
        "UPDATE df.instances SET status = 'cancelled', updated_at = pg_catalog.now() \
         WHERE id = $1 AND status NOT IN ('completed', 'failed', 'cancelled')",
        &[instance_id.into()],
    )
    .unwrap_or_else(|e| warning!("Failed to update instance status: {e}"));

    format!("Instance {instance_id} cancelled: {reason}")
}

/// Gets the status of a durable function instance.
#[pg_extern(schema = "df")]
pub fn status(instance_id: &str) -> Option<String> {
    Spi::get_one_with_args::<String>(
        "SELECT status FROM df.instances WHERE id = $1",
        &[instance_id.into()],
    )
    .ok()
    .flatten()
}

/// Manually runs pending durable functions.
#[pg_extern(schema = "df")]
pub fn run(instance_id: default!(Option<&str>, "NULL")) -> String {
    if let Some(id) = instance_id {
        format!("Triggered run for instance: {id}")
    } else {
        "Triggered run for all pending instances".to_string()
    }
}

/// Gets the result of a completed durable function.
#[pg_extern(schema = "df")]
pub fn result(instance_id: &str) -> Option<String> {
    Spi::get_one_with_args::<String>(
        r#"SELECT result::text FROM df.nodes
           WHERE instance_id = $1
             AND id = (SELECT root_node FROM df.instances WHERE id = $1)
             AND status = 'completed'"#,
        &[instance_id.into()],
    )
    .ok()
    .flatten()
}

/// Blocks the calling backend until a durable function instance reaches a
/// terminal state, returning its final status as plain text
/// ('completed', 'failed', or 'cancelled'). Polls `df.instances` every 100ms
/// until the instance terminates or the timeout is exceeded.
///
/// Intended for test drivers and ad-hoc inspection from a regular client
/// session. It is **not** a composable durable primitive:
///
/// * Its return value is plain text, not a `Durofut`, so it must not be
///   threaded into `df.seq` / `df.join` / `df.race` / `~>` / `&` / `|` etc.
///   Attempting to do so raises an error at composition time.
/// * Calling it from inside a workflow would block a background worker
///   thread for up to `timeout_seconds`, risk a long-running transaction
///   blocking VACUUM, and -- if the instance being waited on is the
///   caller's own -- deadlock the workflow on itself. The function therefore
///   refuses to run inside a workflow context. Use `df.signal()` /
///   `df.wait_for_signal()` for cross-workflow coordination.
///
/// # Arguments
/// * `instance_id` - The durable function instance ID to wait for
/// * `timeout_seconds` - Maximum time to wait in seconds (default: 30)
///
/// # Returns
/// The final status as a string: 'completed', 'failed', or 'cancelled'
///
/// # Errors
/// Raises an error if called inside a workflow, if `timeout_seconds <= 0`,
/// if the instance is not found, or if the timeout is exceeded without
/// reaching a terminal state.
#[pg_extern(schema = "df")]
pub fn await_instance(
    instance_id: &str,
    timeout_seconds: default!(i32, "30"),
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    // Refuse to run inside a workflow: blocking the worker thread on
    // df.instances would hold a worker slot for up to `timeout_seconds`,
    // and waiting on the current instance would deadlock the workflow on
    // itself (the polling loop never sees a terminal state because the
    // worker is stuck here instead of advancing the instance).
    if is_in_workflow_context() {
        pgrx::error!(
            "df.await_instance() cannot be called inside a workflow - it would block a worker thread (and self-deadlock if waiting on the current instance). Use df.signal() and df.wait_for_signal() for cross-workflow coordination."
        );
    }

    if timeout_seconds <= 0 {
        pgrx::error!("Timeout must be positive");
    }

    let max_attempts = timeout_seconds * 10; // Poll every 100ms
    let mut attempts = 0;

    loop {
        // Query instance status
        let status: Option<String> = Spi::get_one_with_args(
            "SELECT status FROM df.instances WHERE id = $1",
            &[instance_id.into()],
        )
        .map_err(|e| format!("Failed to query status: {:?}", e))?;

        if let Some(ref s) = status {
            let s_lower = s.to_lowercase();
            if s_lower == "completed" || s_lower == "failed" || s_lower == "cancelled" {
                // Mark this call so that if its plain-text return value is
                // accidentally threaded into a DSL composer in the same
                // statement (e.g. `SELECT df.seq(df.await_instance(id),
                // df.sql(...))`), Durofut::ensure can attribute the error
                // to df.await_instance rather than silently treating
                // "completed" as a SQL string to execute.
                mark_non_future_helper_call("df.await_instance");
                return Ok(s_lower);
            }
        } else {
            return Err(format!("Instance not found: {}", instance_id).into());
        }

        attempts += 1;
        if attempts >= max_attempts {
            return Err(format!(
                "Timeout after {}s waiting for instance {} (status: {}). Check if background worker is running.",
                timeout_seconds,
                instance_id,
                status.unwrap_or_else(|| "unknown".to_string())
            )
            .into());
        }

        // Sleep 100ms
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

/// **Deprecated alias for `df.await_instance`.** Retained so that the new
/// `.so` keeps servicing the `df.wait_for_completion` binding present in
/// schemas installed at or before v0.2.3, where the catalog entry references
/// the C symbol `wait_for_completion_wrapper`. New code should call
/// `df.await_instance` directly.
#[pg_extern(schema = "df")]
pub fn wait_for_completion(
    instance_id: &str,
    timeout_seconds: default!(i32, "30"),
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    warning!("df.wait_for_completion() is deprecated; use df.await_instance() instead");
    await_instance(instance_id, timeout_seconds)
}

#[cfg(test)]
mod tests {
    use super::{node_insert_sql, parse_semver, pick_id_with_retry};

    #[test]
    fn test_node_insert_sql_uses_current_schema_columns_and_numbered_parameters() {
        let sql = node_insert_sql(2, false);

        assert!(sql.starts_with(
            "INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database) VALUES "
        ));
        assert!(sql.contains("($1, $2, $3, $4, $5, $6, $7, $8::oid::regrole, $9)"));
        assert!(sql.contains("($10, $11, $12, $13, $14, $15, $16, $17::oid::regrole, $18)"));
        assert!(!sql.contains("login_role"));
    }

    #[test]
    fn test_node_insert_sql_uses_legacy_schema_columns_and_numbered_parameters() {
        let sql = node_insert_sql(2, true);

        assert!(sql.starts_with(
            "INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, database) VALUES "
        ));
        assert!(
            sql.contains("($1, $2, $3, $4, $5, $6, $7, $8::oid::regrole, $9::oid::regrole, $10)")
        );
        assert!(sql.contains(
            "($11, $12, $13, $14, $15, $16, $17, $18::oid::regrole, $19::oid::regrole, $20)"
        ));
    }

    #[test]
    fn test_parse_semver_basic() {
        assert_eq!(parse_semver("0.1.1"), Some((0, 1, 1)));
        assert_eq!(parse_semver("0.2.0"), Some((0, 2, 0)));
        assert_eq!(parse_semver("1.0.0"), Some((1, 0, 0)));
        assert_eq!(parse_semver("12.34.56"), Some((12, 34, 56)));
    }

    #[test]
    fn test_parse_semver_with_prerelease_suffix() {
        assert_eq!(parse_semver("0.2.0-rc1"), Some((0, 2, 0)));
        assert_eq!(parse_semver("1.0.0-beta.2"), Some((1, 0, 0)));
    }

    #[test]
    fn test_parse_semver_invalid() {
        assert_eq!(parse_semver(""), None);
        assert_eq!(parse_semver("0"), None);
        assert_eq!(parse_semver("0.1"), None);
        assert_eq!(parse_semver("abc.def.ghi"), None);
        assert_eq!(parse_semver("0.1.abc"), None);
    }

    #[test]
    fn test_parse_semver_comparison() {
        assert!(parse_semver("0.2.0").unwrap() >= (0, 2, 0));
        assert!(parse_semver("0.1.1").unwrap() < (0, 2, 0));
        assert!(parse_semver("0.3.0").unwrap() >= (0, 2, 0));
        assert!(parse_semver("1.0.0").unwrap() >= (0, 2, 0));
    }

    #[test]
    fn test_pick_id_with_retry_succeeds_first_try() {
        let mut gen_calls = 0;
        let id = pick_id_with_retry(
            || {
                gen_calls += 1;
                "aaaa0000".to_string()
            },
            |_candidate| Ok(true),
            10,
        )
        .expect("first candidate should be claimed");
        assert_eq!(id, "aaaa0000");
        assert_eq!(gen_calls, 1);
    }

    #[test]
    fn test_pick_id_with_retry_rerolls_on_collision() {
        // generate yields two colliding candidates then a free one; try_claim
        // reports the known duplicate as a collision and accepts anything else.
        let mut candidates = vec!["dup00000", "dup00000", "uniq0000"].into_iter();
        let mut claim_attempts = 0;
        let id = pick_id_with_retry(
            || candidates.next().unwrap().to_string(),
            |candidate| {
                claim_attempts += 1;
                Ok(candidate != "dup00000")
            },
            10,
        )
        .expect("should re-roll past collisions to a free ID");
        assert_eq!(id, "uniq0000");
        assert_eq!(claim_attempts, 3);
    }

    #[test]
    fn test_pick_id_with_retry_exhausts_without_returning_unverified_id() {
        // Every claim collides, so the helper must error (review finding C1)
        // rather than hand back an unverified candidate.
        let mut claim_attempts = 0;
        let result = pick_id_with_retry(
            || "same0000".to_string(),
            |_candidate| {
                claim_attempts += 1;
                Ok(false)
            },
            3,
        );
        assert_eq!(claim_attempts, 3);
        let err = result.unwrap_err();
        assert!(err.contains("exhausted"), "unexpected error: {err}");
    }

    #[test]
    fn test_pick_id_with_retry_propagates_claim_error() {
        let result = pick_id_with_retry(
            || "x".to_string(),
            |_candidate| Err("claim blew up".to_string()),
            10,
        );
        assert_eq!(result.unwrap_err(), "claim blew up");
    }
}
