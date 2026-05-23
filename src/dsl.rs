//! DSL functions for defining durable SQL functions

use chrono::Utc;
use cron::Schedule as CronSchedule;
use pgrx::datum::DatumWithOid;
use pgrx::prelude::*;
use std::str::FromStr;

use std::cell::RefCell;
use std::time::Instant;

use crate::client::start_durable_function;
use crate::types::{short_id, validate_result_name, Durofut, FunctionInput};

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

/// Debug function to see what duroxide connection is being used
#[pg_extern(schema = "df")]
pub fn debug_connection() -> String {
    use crate::types::{postgres_connection_string, DUROXIDE_SCHEMA};
    format!(
        "{} (schema: {})",
        postgres_connection_string(),
        DUROXIDE_SCHEMA
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
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
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
/// The wait duration is computed at DSL time (when this function is called)
/// to ensure deterministic replay in the orchestration.
#[pg_extern(schema = "df")]
pub fn wait_for_schedule(cron_expr: &str) -> String {
    let cron_with_seconds = format!("0 {cron_expr}");
    let schedule = match CronSchedule::from_str(&cron_with_seconds) {
        Ok(s) => s,
        Err(e) => pgrx::error!("Invalid cron expression '{}': {}", cron_expr, e),
    };

    // Compute wait duration NOW (at DSL time) for deterministic orchestration replay
    let now = Utc::now();
    let next = match schedule.upcoming(Utc).next() {
        Some(t) => t,
        None => pgrx::error!("No upcoming schedule found for '{}'", cron_expr),
    };

    let duration_secs = (next - now).num_seconds().max(0) as u64;

    // Store pre-computed seconds, not the cron expression
    let config = serde_json::json!({
        "cron_expr": cron_expr,
        "wait_seconds": duration_secs
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

    let query = if let Some(cond) = condition {
        let cond_fut = Durofut::ensure(cond);
        let config = serde_json::json!({
            "condition_node": cond_fut
        });
        Some(config.to_string())
    } else {
        None
    };

    Durofut {
        node_type: "LOOP".to_string(),
        left_node: Some(Box::new(body_fut)),
        query,
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

    let config = serde_json::json!({
        "condition_node": condition_fut
    });

    Durofut {
        node_type: "IF".to_string(),
        left_node: Some(Box::new(then_fut)),
        right_node: Some(Box::new(else_fut)),
        query: Some(config.to_string()),
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
        left_node: Some(Box::new(then_fut)),
        right_node: Some(Box::new(else_fut)),
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
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
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

    let config = serde_json::json!({
        "extra_nodes": [c_fut]
    });

    Durofut {
        node_type: "JOIN".to_string(),
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
        query: Some(config.to_string()),
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
        left_node: Some(Box::new(a_fut)),
        right_node: Some(Box::new(b_fut)),
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
/// JSON object with: status, body, headers, ok (boolean), duration_ms
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
        if let Err(e) = crate::ssrf::validate_url_scheme(url) {
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

/// Starts a durable SQL function.
/// The fut argument can be either Durofut JSON or plain SQL string (auto-wrapped).
/// Variables from df.vars are captured and passed to the orchestration.
/// Optional database parameter targets a specific database on the cluster.
#[pg_extern(schema = "df")]
pub fn start(
    fut: &str,
    label: default!(Option<&str>, "NULL"),
    database: default!(Option<&str>, "NULL"),
) -> String {
    let durofut = match Durofut::ensure_strict(fut) {
        Ok(d) => d,
        Err(e) => pgrx::error!("Invalid durable function: {}", e),
    };

    // Validate the entire graph recursively before inserting
    if let Err(e) = durofut.validate_recursive() {
        pgrx::error!("Invalid durable function graph: {}", e);
    }
    let instance_id = short_id();

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
    let current_user_oid = unsafe { pgrx::pg_sys::GetUserId() };
    let current_user_name = unsafe {
        let name_ptr = pgrx::pg_sys::GetUserNameFromId(current_user_oid, false);
        std::ffi::CStr::from_ptr(name_ptr)
            .to_string_lossy()
            .into_owned()
    };

    // Validate current_user has LOGIN privilege
    let has_login: bool = match Spi::get_one_with_args(
        "SELECT rolcanlogin FROM pg_catalog.pg_roles WHERE oid = $1",
        &[current_user_oid.into()],
    ) {
        Ok(Some(has_login)) => has_login,
        Ok(None) => {
            pgrx::error!(
                "failed to check LOGIN privilege for current_user oid {}: query returned NULL",
                current_user_oid
            )
        }
        Err(e) => {
            pgrx::error!(
                "failed to check LOGIN privilege for current_user oid {}: {}",
                current_user_oid,
                e
            )
        }
    };
    if !has_login {
        pgrx::error!(
            "current_user \"{}\" does not have LOGIN privilege. \
             The background worker must connect as this role to execute SQL. \
             Grant LOGIN to this role or call df.start() as a role with LOGIN.",
            current_user_name
        );
    }

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

    // Insert all nodes from the nested graph into df.nodes, returning root node ID
    fn insert_nodes(
        node: &Durofut,
        instance_id: &str,
        current_user_oid: pgrx::pg_sys::Oid,
        database: Option<&str>,
        legacy_login_role: bool,
    ) -> String {
        let node_id = short_id();

        // Recursively insert children FIRST to get their IDs
        let left_id = node.left_node.as_ref().map(|n| {
            insert_nodes(
                n,
                instance_id,
                current_user_oid,
                database,
                legacy_login_role,
            )
        });
        let right_id = node.right_node.as_ref().map(|n| {
            insert_nodes(
                n,
                instance_id,
                current_user_oid,
                database,
                legacy_login_role,
            )
        });

        // Process config JSON to recursively insert embedded nodes and get their IDs
        let query_val: Option<String> = match node.transform_config_children(|child| {
            Ok(insert_nodes(
                child,
                instance_id,
                current_user_oid,
                database,
                legacy_login_role,
            ))
        }) {
            Ok(updated_query) => updated_query,
            Err(e) => pgrx::error!("Invalid config in {} node: {}", node.node_type, e),
        };

        // Build parameterized args for the INSERT
        let query_arg: DatumWithOid = match &query_val {
            Some(q) => q.as_str().into(),
            None => DatumWithOid::null::<String>(),
        };
        let result_name_arg: DatumWithOid = match &node.result_name {
            Some(n) => n.as_str().into(),
            None => DatumWithOid::null::<String>(),
        };
        let left_node_arg: DatumWithOid = match &left_id {
            Some(id) => id.as_str().into(),
            None => DatumWithOid::null::<String>(),
        };
        let right_node_arg: DatumWithOid = match &right_id {
            Some(id) => id.as_str().into(),
            None => DatumWithOid::null::<String>(),
        };
        let database_arg: DatumWithOid = match database {
            Some(db) => db.into(),
            None => DatumWithOid::null::<String>(),
        };

        // Insert this node with parameterized query
        // B1 backward compat: v0.1.x schema has login_role NOT NULL on
        // df.nodes; include it (= submitted_by) so the INSERT succeeds.
        let (node_sql, node_args): (&str, Vec<DatumWithOid>) = if legacy_login_role {
            (
                "INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, database)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8::oid::regrole, $9::oid::regrole, $10)",
                vec![
                    node_id.as_str().into(),
                    instance_id.into(),
                    node.node_type.as_str().into(),
                    query_arg,
                    result_name_arg,
                    left_node_arg,
                    right_node_arg,
                    current_user_oid.into(),
                    current_user_oid.into(), // login_role = submitted_by
                    database_arg,
                ],
            )
        } else {
            (
                "INSERT INTO df.nodes (id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, database)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8::oid::regrole, $9)",
                vec![
                    node_id.as_str().into(),
                    instance_id.into(),
                    node.node_type.as_str().into(),
                    query_arg,
                    result_name_arg,
                    left_node_arg,
                    right_node_arg,
                    current_user_oid.into(),
                    database_arg,
                ],
            )
        };
        if let Err(e) = Spi::run_with_args(node_sql, &node_args) {
            pgrx::error!("Failed to insert node {}: {:?}", node_id, e);
        }

        // Return the generated ID for parent to reference
        node_id
    }

    let legacy_login_role = legacy_login_role_schema();
    let root_node_id = insert_nodes(
        &durofut,
        &instance_id,
        current_user_oid,
        database,
        legacy_login_role,
    );

    // Build parameterized args for the instance INSERT
    let label_arg: DatumWithOid = match label {
        Some(l) => l.into(),
        None => DatumWithOid::null::<String>(),
    };
    let database_arg: DatumWithOid = match database {
        Some(db) => db.into(),
        None => DatumWithOid::null::<String>(),
    };

    // Create instance record with root node ID
    // B1 backward compat: v0.1.x schema has login_role NOT NULL on
    // df.instances; include it (= submitted_by) so the INSERT succeeds.
    let (inst_sql, inst_args): (&str, Vec<DatumWithOid>) = if legacy_login_role {
        (
            "INSERT INTO df.instances (id, label, root_node, submitted_by, login_role, database) VALUES ($1, $2, $3, $4::oid::regrole, $5::oid::regrole, $6)",
            vec![
                instance_id.as_str().into(),
                label_arg,
                root_node_id.as_str().into(),
                current_user_oid.into(),
                current_user_oid.into(), // login_role = submitted_by
                database_arg,
            ],
        )
    } else {
        (
            "INSERT INTO df.instances (id, label, root_node, submitted_by, database) VALUES ($1, $2, $3, $4::oid::regrole, $5)",
            vec![
                instance_id.as_str().into(),
                label_arg,
                root_node_id.as_str().into(),
                current_user_oid.into(),
                database_arg,
            ],
        )
    };
    if let Err(e) = Spi::run_with_args(inst_sql, &inst_args) {
        pgrx::error!("Failed to create instance: {:?}", e);
    }

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

    // Start the orchestration via duroxide
    let input = FunctionInput {
        instance_id: instance_id.clone(),
        label: label.map(|s| s.to_string()),
        vars,
    };
    let input_json = serde_json::to_string(&input).unwrap_or(instance_id.clone());

    if let Err(e) = start_durable_function(
        crate::orchestrations::execute_function_graph::NAME,
        &instance_id,
        &input_json,
    ) {
        pgrx::log!(
            "pg_durable: Warning - failed to start durable function: {}",
            e
        );
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
           WHERE id = (SELECT root_node FROM df.instances WHERE id = $1)
           AND status = 'completed'"#,
        &[instance_id.into()],
    )
    .ok()
    .flatten()
}

/// Waits for a durable function to complete, returning its final status.
/// Polls the instance status every 100ms until it reaches a terminal state
/// (completed, failed, or cancelled) or the timeout is exceeded.
///
/// This is a helper function for pg_regress tests to simplify polling logic
/// and ensure deterministic test output.
///
/// # Arguments
/// * `instance_id` - The durable function instance ID to wait for
/// * `timeout_seconds` - Maximum time to wait in seconds (default: 30)
///
/// # Returns
/// The final status as a string: 'completed', 'failed', or 'cancelled'
///
/// # Errors
/// Raises an error if the timeout is exceeded without reaching a terminal state
#[pg_extern(schema = "df")]
pub fn wait_for_completion(
    instance_id: &str,
    timeout_seconds: default!(i32, "30"),
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
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

#[cfg(test)]
mod tests {
    use super::parse_semver;

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
}
