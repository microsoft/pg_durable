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
use std::sync::{Arc, OnceLock};
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
/// No client-level timeout is set: the timeout is per-node config, so callers
/// apply it with `RequestBuilder::timeout`.
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
fn build_client() -> Result<reqwest::Client, String> {
    let builder = reqwest::Client::builder()
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

static HTTP_CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();

/// The process-wide HTTP client, built on first use.
///
/// The client owns reqwest's connection pool, so building it per request meant
/// a fresh TCP and TLS handshake every time. Caching it keeps connections alive
/// across requests and builds the SSRF-safe resolver and TLS connector once.
pub(crate) fn http_client() -> Result<&'static reqwest::Client, String> {
    HTTP_CLIENT
        .get_or_init(build_client)
        .as_ref()
        .map_err(|e| e.clone())
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
    // df.nodes.result and into duroxide history).
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
            "HTTP BLOCKED (malformed) url={safe_url} submitted_by={audit_user}"
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

    // Shared client with SSRF-safe resolver (when feature enabled); the
    // per-node timeout is applied to the request, not the client.
    let client = http_client()?;

    // Build request based on method
    let mut request = match config.method.as_str() {
        "GET" => client.get(request_url),
        "POST" => client.post(request_url),
        "PUT" => client.put(request_url),
        "DELETE" => client.delete(request_url),
        "PATCH" => client.patch(request_url),
        _ => return Err(format!("Unsupported HTTP method: {}", config.method)),
    }
    .timeout(Duration::from_secs(config.timeout_seconds));

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
        let e = e.without_url();
        let err_string = e.to_string();

        // Detect SSRF IP-blocklist rejections from the resolver and emit
        // a structured audit log (mirrors the scheme-block log above).
        if crate::ssrf::is_ssrf_block_error(&err_string) {
            ctx.trace_info(format!(
                "HTTP BLOCKED (ip) url={safe_url} submitted_by={audit_user}"
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
                config.timeout_seconds, status_info, safe_url
            )
        } else if e.is_connect() {
            format!("HTTP connection failed{status_info}: {safe_url} - {err_string}")
        } else {
            format!("HTTP request failed{status_info}: {safe_url} - {err_string}")
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

        let client = build_client().unwrap();
        let _ = client
            .get("http://pg-durable-proxy-test.invalid/")
            .timeout(Duration::from_secs(1))
            .send()
            .await;
        stop_tx.send(()).unwrap();
        let proxy_was_used = proxy_thread.join().unwrap();

        assert!(
            !proxy_was_used,
            "restricted HTTP modes must bypass system proxies"
        );
    }

    /// Kept as a single test because `http_client()` caches into a process-wide
    /// `OnceLock`; a second `#[tokio::test]` touching it could reuse a client
    /// bound to another test's runtime.
    #[tokio::test]
    async fn shared_client_reuses_connections_without_sharing_request_options() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();

        let keep_alive_thread = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut connections = Vec::new();
            let mut requests = Vec::new();
            while requests.len() < 2 && std::time::Instant::now() < deadline {
                match listener.accept() {
                    Ok((stream, _)) => {
                        stream
                            .set_read_timeout(Some(Duration::from_millis(20)))
                            .unwrap();
                        stream
                            .set_write_timeout(Some(Duration::from_secs(1)))
                            .unwrap();
                        connections.push((stream, Vec::new()));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(error) => panic!("keep-alive listener failed: {error}"),
                }
                for (stream, request) in &mut connections {
                    let mut buffer = [0; 1024];
                    match stream.read(&mut buffer) {
                        Ok(n) => request.extend_from_slice(&buffer[..n]),
                        Err(error)
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) => {}
                        Err(error) => panic!("keep-alive read failed: {error}"),
                    }
                    if request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                        requests.push(std::mem::take(request));
                        stream
                            .write_all(
                                b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\
                                  Set-Cookie: pooled=not-for-next-request; Path=/\r\n\r\nok",
                            )
                            .unwrap();
                    }
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            (connections.len(), requests)
        });

        // Reacquire the client and consume each body: retaining one local client
        // or timing out both responses would not prove cross-lookup TCP reuse.
        let responses = tokio::time::timeout(Duration::from_secs(5), async {
            let first = http_client()
                .unwrap()
                .get(&url)
                .header("Authorization", "Bearer first-only")
                .header("Cookie", "caller=first-only")
                .timeout(Duration::from_secs(2))
                .send()
                .await?
                .text()
                .await?;
            let second = http_client()
                .unwrap()
                .get(&url)
                .timeout(Duration::from_secs(2))
                .send()
                .await?
                .text()
                .await?;
            Ok::<_, reqwest::Error>([first, second])
        })
        .await;

        let (connection_count, requests) = keep_alive_thread.join().unwrap();
        assert_eq!(responses.unwrap().unwrap(), ["ok", "ok"]);
        assert_eq!(requests.len(), 2);
        assert_eq!(
            connection_count, 1,
            "separate client lookups must reuse TCP"
        );
        let first = String::from_utf8(requests[0].clone())
            .unwrap()
            .to_ascii_lowercase();
        let second = String::from_utf8(requests[1].clone())
            .unwrap()
            .to_ascii_lowercase();
        assert!(first.contains("\r\nauthorization: bearer first-only\r\n"));
        assert!(first.contains("\r\ncookie: caller=first-only\r\n"));
        assert!(!second.contains("\r\nauthorization:"));
        assert!(!second.contains("\r\ncookie:"));

        // Accept connections and never reply, so only the timeout can end a request.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();

        let (stop_tx, stop_rx) = mpsc::channel();
        let stall_thread = std::thread::spawn(move || {
            let mut accepted = Vec::new();
            loop {
                match listener.accept() {
                    Ok((stream, _)) => accepted.push(stream),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if !matches!(stop_rx.try_recv(), Err(mpsc::TryRecvError::Empty)) {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    Err(error) => panic!("stall listener failed: {error}"),
                }
            }
        });

        // An IP-literal URL never reaches the DNS resolver, so loopback is
        // reachable in this client-only test, unlike a validated HTTP activity.
        let url = format!("http://{addr}/");

        let timeouts = tokio::time::timeout(Duration::from_secs(5), async {
            let short_started = std::time::Instant::now();
            let short_result = http_client()
                .unwrap()
                .get(url.as_str())
                .timeout(Duration::from_millis(200))
                .send()
                .await;
            let short_elapsed = short_started.elapsed();

            let long_started = std::time::Instant::now();
            let long_result = http_client()
                .unwrap()
                .get(url.as_str())
                .timeout(Duration::from_millis(900))
                .send()
                .await;
            (
                short_result,
                short_elapsed,
                long_result,
                long_started.elapsed(),
            )
        })
        .await;

        stop_tx.send(()).unwrap();
        stall_thread.join().unwrap();
        let (short_result, short_elapsed, long_result, long_elapsed) = timeouts.unwrap();
        let short_error = short_result.expect_err("a stalled response must fail");
        let long_error = long_result.expect_err("a stalled response must fail");

        // execute() branches on is_timeout() to build its error message.
        assert!(
            short_error.is_timeout(),
            "expected a timeout error, got: {short_error}"
        );
        assert!(
            long_error.is_timeout(),
            "expected a timeout error, got: {long_error}"
        );

        assert!(
            short_elapsed < Duration::from_millis(600),
            "first request overran its 200ms deadline: {short_elapsed:?}"
        );
        assert!(
            long_elapsed > Duration::from_millis(600),
            "second request inherited the first request's deadline: {long_elapsed:?}"
        );
    }
}
