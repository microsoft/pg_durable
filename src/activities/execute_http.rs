// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteHTTP activity - makes HTTP requests
//!
//! Cargo features control what outbound HTTP(S) is allowed:
//! - `http-allow-azure-domains`: Azure endpoints + api.github.com only
//!   (+ IP blocklist, no redirects).
//! - `http-allow-test-domains`: same + httpbingo.org.
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
///
/// The signature is resolved with `to_regprocedure()` over an ordered list
/// (current form first, pre-0.2.8 form second) because a `::regprocedure` cast
/// raises on a missing function: the new `.so` must also run against older
/// installed schemas that only have the five-argument form.
async fn check_http_privilege(pool: &PgPool, submitted_by: &str) -> Result<(), String> {
    let verdict: Option<String> = sqlx::query_scalar(
        "SELECT CASE \
             WHEN p.oid IS NULL THEN 'absent' \
             WHEN pg_catalog.has_function_privilege($1::regrole, p.oid, 'EXECUTE') THEN 'allowed' \
             ELSE 'denied' \
         END \
         FROM (SELECT COALESCE( \
             pg_catalog.to_regprocedure('df.http(text,text,text,jsonb,integer,jsonb)'), \
             pg_catalog.to_regprocedure('df.http(text,text,text,jsonb,integer)') \
         ) AS oid) p",
    )
    .bind(submitted_by)
    .fetch_optional(pool)
    .await
    .map_err(|e| format!("HTTP privilege check failed for role '{submitted_by}': {e}"))?;

    match verdict.as_deref() {
        Some("allowed") => Ok(()),
        Some("absent") => Err(format!(
            "Blocked: df.http() is not installed in this database, so the HTTP privilege \
             of role '{submitted_by}' cannot be verified."
        )),
        _ => Err(format!(
            "Blocked: role '{submitted_by}' does not have EXECUTE privilege on df.http(). \
             Grant EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer,jsonb) TO {submitted_by} to allow HTTP requests."
        )),
    }
}

/// Build a reqwest Client with optional SSRF-safe DNS resolver.
///
/// A default `User-Agent` is set so requests are not anonymous: some endpoints
/// (e.g. fly.io-hosted services) reject requests that omit it. Nodes may still
/// override it via an explicit `User-Agent` header.
///
/// Redirects are disabled to prevent redirect-based SSRF bypasses: an attacker
/// could host a 302 redirecting to `http://169.254.169.254/...`, and reqwest
/// would follow it without calling our DNS resolver (since the target is an IP
/// literal).
///
/// Restricted builds also disable environment/system proxies. A proxy resolves
/// the destination itself, which would bypass `SsrfSafeResolver`'s check of the
/// address reqwest ultimately reaches.
pub(crate) fn build_client(timeout: Duration) -> Result<reqwest::Client, String> {
    let builder = reqwest::Client::builder()
        .timeout(timeout)
        .user_agent(concat!("pg_durable/", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::none());

    // Inject the SSRF-safe DNS resolver unless http-allow-all removes all guards.
    #[cfg(not(feature = "http-allow-all"))]
    let builder = {
        use crate::ssrf::{SsrfSafeResolver, SystemResolver};
        use std::sync::Arc;
        let resolver = SsrfSafeResolver::wrapping(Arc::new(SystemResolver));
        builder.no_proxy().dns_resolver(Arc::new(resolver))
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

    // Every log line and error below reports this, never `config.url`: an Azure
    // SAS token lives entirely in the query string, and both sinks outlive the
    // instance (the server log has no retention bound; errors are persisted to
    // df.nodes.error and into duroxide history).
    let safe_url = crate::redact::redact_url(&config.url);

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
    //
    // Steps 1 and 2 inspect the parsed URL that step 4 sends, so no parser
    // differential can separate what we approve from what we request.

    // --- Privilege check (Layer 0): submitted_by must have EXECUTE on df.http() ---
    check_http_privilege(&pool, audit_user)
        .await
        .inspect_err(|_| {
            ctx.trace_info(format!(
                "HTTP BLOCKED (privilege) url={safe_url} submitted_by={audit_user}"
            ));
        })?;

    let request_url = crate::ssrf::parse_request_url(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP BLOCKED (malformed) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    // --- Scheme validation (always enforced, regardless of feature flag) ---
    crate::ssrf::validate_scheme(&request_url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP BLOCKED (scheme) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    // --- Azure endpoint allow-list (blocks all bare IPs + non-Azure domains) ---
    crate::ssrf::validate_allowlist(&request_url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP BLOCKED (allowlist) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    let start = std::time::Instant::now();
    ctx.trace_info(format!(
        "HTTP {} {safe_url} submitted_by={audit_user}",
        config.method
    ));

    // Build client with SSRF-safe resolver (when feature enabled) and timeout
    let client = build_client(Duration::from_secs(config.timeout_seconds))?;

    // Build request based on method
    let mut request = match config.method.as_str() {
        "GET" => client.get(request_url),
        "POST" => client.post(request_url),
        "PUT" => client.put(request_url),
        "DELETE" => client.delete(request_url),
        "PATCH" => client.patch(request_url),
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
                "HTTP BLOCKED (ip) url={safe_url} submitted_by={audit_user}"
            ));
            return crate::redact::redact_urls_in(&err_string);
        }

        // Try to extract status code from error if available
        let status_info = e
            .status()
            .map(|s| format!(" (HTTP {})", s.as_u16()))
            .unwrap_or_default();

        // reqwest's Display interpolates the request URL, so the error text is
        // scrubbed as well as the URL we format ourselves.
        let detail = crate::redact::redact_urls_in(&err_string);

        if e.is_timeout() {
            format!(
                "HTTP timeout after {}s{}: {}",
                config.timeout_seconds, status_info, safe_url
            )
        } else if e.is_connect() {
            format!("HTTP connection failed{status_info}: {safe_url} - {detail}")
        } else if e.is_status() {
            // Error due to HTTP status code
            format!("HTTP request failed{status_info}: {safe_url} - {detail}")
        } else {
            format!("HTTP request failed{status_info}: {safe_url} - {detail}")
        }
    })?;

    let status = response.status();
    let status_code = status.as_u16();

    // Collect response headers
    let response_headers = crate::activities::http_response::collect_headers(&response);

    // Text or base64 depending on Content-Type — see activities::http_response.
    let response_body = crate::activities::http_response::read_body(response).await?;

    let duration_ms = start.elapsed().as_millis() as u64;
    let is_ok = status.is_success();

    // Build response object
    let result = crate::activities::http_response::build_envelope(
        status_code,
        &response_body,
        response_headers,
        is_ok,
        duration_ms,
    );

    ctx.trace_info(format!(
        "HTTP {} completed: status={}, ok={}, encoding={}, duration={}ms",
        config.method, status_code, is_ok, response_body.encoding, duration_ms
    ));

    // Fail on 5xx server errors (transient, should retry)
    if status.is_server_error() {
        return Err(format!(
            "HTTP {} {safe_url} returned {}: {}",
            config.method,
            status_code,
            response_body.error_preview()
        ));
    }

    // Return response for all other cases (including 4xx)
    // 4xx are client errors - user should handle in workflow logic
    Ok(result.to_string())
}

#[cfg(all(test, not(feature = "http-allow-all")))]
mod tests {
    use super::*;
    use std::ffi::OsString;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    struct EnvGuard {
        name: &'static str,
        original: Option<OsString>,
    }

    impl EnvGuard {
        fn set(name: &'static str, value: &str) -> Self {
            let original = std::env::var_os(name);
            std::env::set_var(name, value);
            Self { name, original }
        }

        fn remove(name: &'static str) -> Self {
            let original = std::env::var_os(name);
            std::env::remove_var(name);
            Self { name, original }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.original {
                Some(value) => std::env::set_var(self.name, value),
                None => std::env::remove_var(self.name),
            }
        }
    }

    #[tokio::test]
    async fn restricted_builds_ignore_environment_proxy() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let proxy_url = format!("http://{}", listener.local_addr().unwrap());

        let _http_proxy_upper = EnvGuard::set("HTTP_PROXY", &proxy_url);
        let _http_proxy_lower = EnvGuard::set("http_proxy", &proxy_url);
        let _no_proxy_upper = EnvGuard::remove("NO_PROXY");
        let _no_proxy_lower = EnvGuard::remove("no_proxy");

        let (stop_tx, stop_rx) = mpsc::channel();
        let proxy_thread = std::thread::spawn(move || loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(1)))
                        .unwrap();
                    let mut request = [0; 1024];
                    let _ = stream.read(&mut request);
                    stream
                        .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                        .unwrap();
                    return true;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if stop_rx.try_recv().is_ok() {
                        return false;
                    }
                    std::thread::yield_now();
                }
                Err(error) => panic!("proxy listener failed: {error}"),
            }
        });

        let client = build_client(Duration::from_secs(1)).unwrap();
        let _ = client
            .get("http://pg-durable-proxy-test.invalid/")
            .send()
            .await;
        stop_tx.send(()).unwrap();
        let proxy_was_used = proxy_thread.join().unwrap();

        assert!(
            !proxy_was_used,
            "restricted HTTP modes must bypass system proxies"
        );
    }
}
