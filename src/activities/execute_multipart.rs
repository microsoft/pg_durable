// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteMultipart activity - makes multipart/form-data HTTP requests.
//!
//! This is the file-upload / form-post counterpart to `execute_http`. It shares
//! the same security model (privilege check, scheme validation, Azure
//! allow-list, SSRF-safe DNS resolver, no redirects) and reuses
//! `execute_http::build_client` so the two paths cannot drift on client
//! configuration. The only differences are the body construction (a
//! `reqwest::multipart::Form` built from base64-encoded parts) and the
//! privilege target (`df.http_multipart` instead of `df.http`).
//!
//! Cargo features controlling outbound HTTP(S) are the same as for df.http —
//! see docs/http-security.md for the full security model.

use base64::Engine as _;
use duroxide::ActivityContext;
use std::sync::Arc;
use std::time::Duration;

use sqlx::PgPool;

use crate::activities::execute_http::build_client;
use crate::types::MultipartConfig;

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-multipart";

/// Check that `submitted_by` holds EXECUTE privilege on `df.http_multipart()`.
///
/// Mirrors `execute_http::check_http_privilege` — closes the bypass path where
/// a user crafts a raw Durofut JSON and passes it directly to `df.start()`,
/// inserting an HTTP_MULTIPART node without going through the DSL guard.
async fn check_multipart_privilege(pool: &PgPool, submitted_by: &str) -> Result<(), String> {
    let has_priv: Option<bool> = sqlx::query_scalar(
        "SELECT has_function_privilege($1::regrole, \
             'df.http_multipart(text,text,jsonb,jsonb,integer)'::regprocedure, \
             'EXECUTE')",
    )
    .bind(submitted_by)
    .fetch_optional(pool)
    .await
    .map_err(|e| format!("HTTP privilege check failed for role '{submitted_by}': {e}"))?;

    match has_priv {
        Some(true) => Ok(()),
        _ => Err(format!(
            "Blocked: role '{submitted_by}' does not have EXECUTE privilege on df.http_multipart(). \
             Grant EXECUTE ON FUNCTION df.http_multipart(text,text,jsonb,jsonb,integer) TO {submitted_by} to allow multipart HTTP requests."
        )),
    }
}

/// Execute a multipart/form-data HTTP request and return the response as JSON
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    config_json: String,
) -> Result<String, String> {
    let config: MultipartConfig = serde_json::from_str(&config_json)
        .map_err(|e| format!("Invalid multipart HTTP config: {e}"))?;

    // Audit context — submitted_by is always set by the orchestration, but guard
    // explicitly so a missing value produces a clear error.
    let audit_user = config.submitted_by.as_deref().ok_or(
        "Blocked: HTTP_MULTIPART node has no submitted_by \u{2014} cannot verify privilege",
    )?;

    // Validation chain — order is security-critical and mirrors execute_http:
    //   0. Privilege: submitted_by must hold EXECUTE on df.http_multipart().
    //   1. Scheme:    blocks file://, gopher://, etc.
    //   2. Allowlist: blocks ALL bare IPs (public and private) + non-Azure
    //                 domains. Fails-closed on malformed URLs.
    //   3. DNS resolver (SsrfSafeResolver): catches DNS rebinding.

    // --- Privilege check (Layer 0) ---
    check_multipart_privilege(&pool, audit_user)
        .await
        .inspect_err(|_| {
            ctx.trace_info(format!(
                "HTTP_MULTIPART BLOCKED (privilege) url={} submitted_by={audit_user}",
                config.url
            ));
        })?;

    // --- Scheme validation (always enforced) ---
    crate::ssrf::validate_url_scheme(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (scheme) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    // --- Azure endpoint allow-list ---
    crate::ssrf::validate_url_allowlist(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (allowlist) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    let start = std::time::Instant::now();
    ctx.trace_info(format!(
        "HTTP_MULTIPART {} {} ({} parts) submitted_by={audit_user}",
        config.method,
        config.url,
        config.parts.len()
    ));

    // Build client (shared SSRF-safe resolver + timeout) with execute_http.
    let client = build_client(Duration::from_secs(config.timeout_seconds))?;

    // Build request based on method. Multipart only makes sense for
    // body-carrying methods; the DSL guard restricts to POST/PUT/PATCH and we
    // defend in depth here.
    let mut request = match config.method.as_str() {
        "POST" => client.post(&config.url),
        "PUT" => client.put(&config.url),
        "PATCH" => client.patch(&config.url),
        _ => {
            return Err(format!(
                "Unsupported HTTP method for multipart: {}",
                config.method
            ))
        }
    };

    // Add headers — but NEVER Content-Type. reqwest sets
    // `multipart/form-data; boundary=...` itself when .multipart() is called; a
    // caller-supplied Content-Type would clobber the boundary and the server
    // would receive an unparseable body.
    if let Some(headers) = &config.headers {
        if let Some(obj) = headers.as_object() {
            for (key, value) in obj {
                if key.eq_ignore_ascii_case("content-type") {
                    continue;
                }
                if let Some(v) = value.as_str() {
                    request = request.header(key, v);
                }
            }
        }
    }

    // Build the multipart form from base64-encoded parts.
    let mut form = reqwest::multipart::Form::new();
    for part in &config.parts {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&part.data_b64)
            .map_err(|e| format!("Invalid base64 in part '{}': {e}", part.name))?;
        let mut req_part = reqwest::multipart::Part::bytes(bytes);
        if let Some(ct) = &part.content_type {
            req_part = req_part
                .mime_str(ct)
                .map_err(|e| format!("Invalid content_type for part '{}': {e}", part.name))?;
        }
        if let Some(filename) = &part.filename {
            req_part = req_part.file_name(filename.clone());
        }
        form = form.part(part.name.clone(), req_part);
    }

    // Execute request
    let response = request.multipart(form).send().await.map_err(|e| {
        let err_string = e.to_string();

        // Detect SSRF IP-blocklist rejections from the resolver.
        if crate::ssrf::is_ssrf_block_error(&err_string) {
            ctx.trace_info(format!(
                "HTTP_MULTIPART BLOCKED (ip) url={} submitted_by={audit_user}",
                config.url
            ));
            return err_string;
        }

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

    // Build response object — same envelope as execute_http.
    let result = serde_json::json!({
        "status": status_code,
        "body": response_body,
        "headers": response_headers,
        "ok": is_ok,
        "duration_ms": duration_ms
    });

    ctx.trace_info(format!(
        "HTTP_MULTIPART {} completed: status={}, ok={}, duration={}ms",
        config.method, status_code, is_ok, duration_ms
    ));

    // Fail on 5xx server errors (transient, should retry)
    if status.is_server_error() {
        return Err(format!(
            "HTTP_MULTIPART {} {} returned {}: {}",
            config.method, config.url, status_code, response_body
        ));
    }

    // Return response for all other cases (including 4xx)
    Ok(result.to_string())
}
