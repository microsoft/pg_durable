// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteHTTP activity - makes HTTP requests
//!
//! Cargo features control what outbound HTTP(S) is allowed:
//! - `http-allow-azure-domains`: Azure endpoints only (+ IP blocklist, no redirects).
//! - `http-allow-test-domains`: same + api.github.com / httpbingo.org.
//! - `http-allow-all`: no restrictions (development only).
//! - *(none)*: all HTTP calls fail at execution time.
//!
//! See docs/http-security.md for the full security model.

use duroxide::ActivityContext;
use std::sync::Arc;
use std::time::Duration;

use sqlx::PgPool;

use crate::types::HttpConfig;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-http";

/// Check that `submitted_by` holds EXECUTE privilege on `df.http()`.
///
/// This closes the bypass path where a user crafts a raw Durofut JSON and
/// passes it directly to `df.start()`, inserting an HTTP node without going
/// through the DSL guard in `df.http()`.
async fn check_http_privilege(pool: &PgPool, submitted_by: &str) -> Result<(), String> {
    let has_priv: Option<bool> = sqlx::query_scalar(
        "SELECT has_function_privilege($1::regrole, \
             'df.http(text,text,text,jsonb,integer)'::regprocedure, \
             'EXECUTE')",
    )
    .bind(submitted_by)
    .fetch_optional(pool)
    .await
    .map_err(|e| format!("HTTP privilege check failed for role '{submitted_by}': {e}"))?;

    match has_priv {
        Some(true) => Ok(()),
        _ => Err(format!(
            "Blocked: role '{submitted_by}' does not have EXECUTE privilege on df.http(). \
             Grant EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer) TO {submitted_by} to allow HTTP requests."
        )),
    }
}

/// Build a reqwest Client with optional SSRF-safe DNS resolver.
///
/// Redirects are disabled to prevent redirect-based SSRF bypasses: an attacker
/// could host a 302 redirecting to `http://169.254.169.254/...`, and reqwest
/// would follow it without calling our DNS resolver (since the target is an IP
/// literal).
fn build_client(timeout: Duration) -> Result<reqwest::Client, String> {
    let builder = reqwest::Client::builder()
        .timeout(timeout)
        .redirect(reqwest::redirect::Policy::none());

    // Inject the SSRF-safe DNS resolver unless http-allow-all removes all guards.
    #[cfg(not(feature = "http-allow-all"))]
    let builder = {
        use crate::ssrf::{SsrfSafeResolver, SystemResolver};
        use std::sync::Arc;
        let resolver = SsrfSafeResolver::wrapping(Arc::new(SystemResolver));
        builder.dns_resolver(Arc::new(resolver))
    };

    builder
        .build()
        .map_err(|e| format!("Failed to create HTTP client: {e}"))
}

/// Execute an HTTP request and return the response as JSON
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    config_json: String,
) -> Result<String, String> {
    let config: HttpConfig =
        serde_json::from_str(&config_json).map_err(|e| format!("Invalid HTTP config: {e}"))?;

    // Audit context — submitted_by is always set by the orchestration (from
    // FunctionNode.submitted_by which is non-optional), but guard explicitly
    // so a missing value produces a clear error instead of a confusing
    // 'role "unknown" does not exist' from the regrole cast.
    let audit_user = config
        .submitted_by
        .as_deref()
        .ok_or("Blocked: HTTP node has no submitted_by \u{2014} cannot verify privilege")?;

    // Validation chain — order is security-critical:
    //   0. Privilege: submitted_by must hold EXECUTE on df.http(). Closes the
    //                 bypass path where a user crafts raw Durofut JSON and passes
    //                 it to df.start() without going through the DSL guard.
    //   1. Scheme:    blocks file://, gopher://, etc.
    //   2. Allowlist: blocks ALL bare IPs (public and private) + non-Azure
    //                 domains. Fails-closed on malformed URLs. Because bare IPs
    //                 bypass the DNS resolver entirely in reqwest, this is the
    //                 definitive gate for IP-literal URLs.
    //   3. DNS resolver (SsrfSafeResolver): catches DNS rebinding — a hostname
    //                 that passes the allowlist but resolves to a private IP at
    //                 connect time.

    // --- Privilege check (Layer 0): submitted_by must have EXECUTE on df.http() ---
    check_http_privilege(&pool, audit_user)
        .await
        .inspect_err(|_| {
            ctx.trace_info(format!(
                "HTTP BLOCKED (privilege) url={} submitted_by={audit_user}",
                config.url
            ));
        })?;

    // --- Scheme validation (always enforced, regardless of feature flag) ---
    crate::ssrf::validate_url_scheme(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP BLOCKED (scheme) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    // --- Azure endpoint allow-list (blocks all bare IPs + non-Azure domains) ---
    crate::ssrf::validate_url_allowlist(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP BLOCKED (allowlist) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    let start = std::time::Instant::now();
    ctx.trace_info(format!(
        "HTTP {} {} submitted_by={audit_user}",
        config.method, config.url
    ));

    // Build client with SSRF-safe resolver (when feature enabled) and timeout
    let client = build_client(Duration::from_secs(config.timeout_seconds))?;

    // Build request based on method
    let mut request = match config.method.as_str() {
        "GET" => client.get(&config.url),
        "POST" => client.post(&config.url),
        "PUT" => client.put(&config.url),
        "DELETE" => client.delete(&config.url),
        "PATCH" => client.patch(&config.url),
        _ => return Err(format!("Unsupported HTTP method: {}", config.method)),
    };

    // Add headers
    if let Some(headers) = &config.headers {
        if let Some(obj) = headers.as_object() {
            for (key, value) in obj {
                if let Some(v) = value.as_str() {
                    request = request.header(key, v);
                }
            }
        }
    }

    // Add body (for POST/PUT/PATCH)
    if let Some(body) = &config.body {
        request = request.body(body.clone());
    }

    // Execute request
    let response = request.send().await.map_err(|e| {
        let err_string = e.to_string();

        // Detect SSRF IP-blocklist rejections from the resolver and emit
        // a structured audit log (mirrors the scheme-block log above).
        if crate::ssrf::is_ssrf_block_error(&err_string) {
            ctx.trace_info(format!(
                "HTTP BLOCKED (ip) url={} submitted_by={audit_user}",
                config.url
            ));
            return err_string;
        }

        // Try to extract status code from error if available
        let status_info = e
            .status()
            .map(|s| format!(" (HTTP {})", s.as_u16()))
            .unwrap_or_default();

        if e.is_timeout() {
            format!(
                "HTTP timeout after {}s{}: {}",
                config.timeout_seconds, status_info, config.url
            )
        } else if e.is_connect() {
            format!(
                "HTTP connection failed{}: {} - {}",
                status_info, config.url, e
            )
        } else if e.is_status() {
            // Error due to HTTP status code
            format!("HTTP request failed{}: {} - {}", status_info, config.url, e)
        } else {
            format!("HTTP request failed{}: {} - {}", status_info, config.url, e)
        }
    })?;

    let status = response.status();
    let status_code = status.as_u16();

    // Collect response headers
    let response_headers: serde_json::Map<String, serde_json::Value> = response
        .headers()
        .iter()
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|s| (k.to_string(), serde_json::Value::String(s.to_string())))
        })
        .collect();

    let response_body = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response body: {e}"))?;

    let duration_ms = start.elapsed().as_millis() as u64;
    let is_ok = status.is_success();

    // Build response object
    let result = serde_json::json!({
        "status": status_code,
        "body": response_body,
        "headers": response_headers,
        "ok": is_ok,
        "duration_ms": duration_ms
    });

    ctx.trace_info(format!(
        "HTTP {} completed: status={}, ok={}, duration={}ms",
        config.method, status_code, is_ok, duration_ms
    ));

    // Fail on 5xx server errors (transient, should retry)
    if status.is_server_error() {
        return Err(format!(
            "HTTP {} {} returned {}: {}",
            config.method, config.url, status_code, response_body
        ));
    }

    // Return response for all other cases (including 4xx)
    // 4xx are client errors - user should handle in workflow logic
    Ok(result.to_string())
}
