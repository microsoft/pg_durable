// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! ExecuteMultipart activity - makes multipart/form-data HTTP requests.
//!
//! This is the file-upload / form-post counterpart to `execute_http`. It shares
//! the same security model (privilege check, scheme validation, domain
//! allow-list, SSRF-safe DNS resolver, no redirects) and reuses
//! `execute_http::http_client` so the two paths cannot drift on client
//! configuration. The only differences are the body construction (a
//! `reqwest::multipart::Form` built from base64-encoded parts) and the
//! privilege target (`df.http_multipart` instead of `df.http`).
//!
//! Startup settings controlling outbound HTTP(S) are the same as for df.http —
//! see docs/http-security.md for the full security model.

use base64::Engine as _;
use duroxide::ActivityContext;
use std::sync::Arc;
use std::time::Duration;

use sqlx::PgPool;
use tokio::sync::Semaphore;

use crate::activities::execute_http::{check_http_privilege, http_client};
use crate::ssrf::HttpPolicy;
use crate::types::{HttpBodyOptions, MultipartConfig, MultipartPart};

/// Activity name for registration and scheduling
pub const NAME: &str = "pg_durable::activity::execute-multipart";

/// Decode a part's `data_b64` payload, tolerating ASCII whitespace.
///
/// PostgreSQL's `encode(bytea, 'base64')` follows RFC 2045 §6.8 and breaks its
/// output into 76-character lines separated by newlines. The `STANDARD` engine
/// rejects any character outside the base64 alphabet, so unwrapped decoding
/// fails for every payload larger than 57 source bytes — which is to say, for
/// the canonical way a PostgreSQL user produces base64. Whitespace is not part
/// of the alphabet, so stripping it loosens nothing that was ever meaningful.
///
/// The strip allocates only when whitespace is actually present; the common
/// case of a single unwrapped line decodes without a copy.
fn decode_part_data(data_b64: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let engine = base64::engine::general_purpose::STANDARD;
    if data_b64.bytes().any(|b| b.is_ascii_whitespace()) {
        let stripped: String = data_b64
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .collect();
        engine.decode(&stripped)
    } else {
        engine.decode(data_b64)
    }
}

fn build_multipart_request(
    request: reqwest::RequestBuilder,
    parts: &[MultipartPart],
    options: &HttpBodyOptions,
) -> Result<reqwest::Request, String> {
    let (client, request) = request.build_split();
    let mut request = request
        .map_err(|error| format!("Failed to build multipart request: {}", error.without_url()))?;
    if options.max_request_bytes.is_some() {
        request
            .headers_mut()
            .remove(reqwest::header::CONTENT_LENGTH);
    }
    let mut form = reqwest::multipart::Form::new();
    let mut total_bytes = 0u64;
    for part in parts {
        let bytes = decode_part_data(&part.data_b64)
            .map_err(|error| format!("Invalid base64 in part '{}': {error}", part.name))?;
        total_bytes = total_bytes
            .checked_add(bytes.len() as u64)
            .ok_or("HTTP request body length overflow")?;
        options.check_request_bytes(total_bytes)?;
        let mut req_part = reqwest::multipart::Part::bytes(bytes);
        if let Some(content_type) = &part.content_type {
            req_part = req_part.mime_str(content_type).map_err(|error| {
                format!("Invalid content_type for part '{}': {error}", part.name)
            })?;
        }
        if let Some(filename) = &part.filename {
            req_part = req_part.file_name(filename.clone());
        }
        form = form.part(part.name.clone(), req_part);
    }
    let request = reqwest::RequestBuilder::from_parts(client, request)
        .multipart(form)
        .build()
        .map_err(|error| format!("Failed to build multipart request: {}", error.without_url()))?;
    if options.max_request_bytes.is_some() {
        let length = request
            .headers()
            .get(reqwest::header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .ok_or("Cannot enforce max_request_bytes: multipart body length is unknown")?;
        options.check_request_bytes(length)?;
    }
    Ok(request)
}

/// Execute a multipart/form-data HTTP request and return the response as JSON
pub async fn execute(
    ctx: ActivityContext,
    pool: Arc<PgPool>,
    semaphore: Arc<Semaphore>,
    policy: Arc<HttpPolicy>,
    config_json: String,
) -> Result<String, String> {
    let config: MultipartConfig = serde_json::from_str(&config_json)
        .map_err(|e| format!("Invalid multipart HTTP config: {e}"))?;

    // Audit context — submitted_by is always set by the orchestration, but guard
    // explicitly so a missing value produces a clear error.
    let audit_user = config.submitted_by.as_deref().ok_or(
        "Blocked: HTTP_MULTIPART node has no submitted_by \u{2014} cannot verify privilege",
    )?;

    // See execute_http: never log or return `config.url` itself.
    let safe_url = crate::redact::redact_url(&config.url);

    // Validation chain — order is security-critical and mirrors execute_http:
    //   0. Privilege: submitted_by must hold EXECUTE on df.http_multipart().
    //   1. Scheme:    blocks file://, gopher://, etc.
    //   2. Allowlist: blocks ALL bare IPs (public and private) + unlisted
    //                 domains. Fails-closed on malformed URLs.
    //   3. DNS resolver (SsrfSafeResolver): catches DNS rebinding.

    // --- Privilege check (Layer 0) ---
    check_http_privilege(&pool, audit_user, config.endpoint.is_some(), true)
        .await
        .inspect_err(|_| {
            ctx.trace_info(format!(
                "HTTP_MULTIPART BLOCKED (privilege) url={safe_url} submitted_by={audit_user}"
            ));
        })?;

    config
        .secret_options
        .validate(false, &config.method, true, config.headers.as_ref())?;
    config.body_options.validate()?;
    let mut catalog = crate::endpoints::EndpointCatalog::new(audit_user, &semaphore);
    let mut prepared = crate::endpoints::prepare_request(
        &mut catalog,
        config.endpoint.as_deref(),
        &config.url,
        config.headers.as_ref(),
    )
    .await
    .inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (malformed) url={safe_url} submitted_by={audit_user}"
        ));
    })?;
    let request_url = &prepared.url;
    let safe_url = if config.endpoint.is_some() {
        crate::redact::redact_url(request_url.as_str())
    } else {
        safe_url
    };

    // --- Scheme validation (always enforced) ---
    crate::ssrf::validate_scheme(request_url, policy.security).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (scheme) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    // --- Endpoint allow-list ---
    crate::ssrf::validate_allowlist(request_url, &policy).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (allowlist) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    let resolved = config
        .secret_options
        .resolve(&mut catalog, &mut prepared, config.headers.as_ref())
        .await?;
    catalog.close().await?;
    let safe_url = if config
        .secret_options
        .secret_bindings
        .as_ref()
        .is_some_and(|bindings| !bindings.query.is_empty())
    {
        crate::redact::redact_url(prepared.url.as_str())
    } else {
        safe_url
    };
    let request_url = prepared.url;
    let start = std::time::Instant::now();
    ctx.trace_info(format!(
        "HTTP_MULTIPART {} {safe_url} ({} parts) submitted_by={audit_user}",
        config.method,
        config.parts.len()
    ));

    // Client shared with execute_http (same SSRF-safe resolver and pool); the
    // per-node timeout is applied to the request.
    let client = http_client(policy.security)?;

    // Build request based on method. Multipart only makes sense for
    // body-carrying methods; the DSL guard restricts to POST/PUT/PATCH and we
    // defend in depth here.
    let mut request = match config.method.as_str() {
        "POST" => client.post(request_url),
        "PUT" => client.put(request_url),
        "PATCH" => client.patch(request_url),
        _ => {
            return Err(format!(
                "Unsupported HTTP method for multipart: {}",
                config.method
            ))
        }
    }
    .timeout(Duration::from_secs(config.timeout_seconds));

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

    if let Some((name, value)) = prepared.credential_header {
        request = request.header(name, value);
    }
    request = request.headers(resolved.headers);

    let request = build_multipart_request(request, &config.parts, &config.body_options)?;

    // Execute request
    let response = client.execute(request).await.map_err(|e| {
        let e = e.without_url();
        let err_string = e.to_string();

        // Detect SSRF IP-blocklist rejections from the resolver.
        if crate::ssrf::is_ssrf_block_error(&err_string) {
            ctx.trace_info(format!(
                "HTTP_MULTIPART BLOCKED (ip) url={safe_url} submitted_by={audit_user}"
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
    let response_headers =
        crate::activities::http_response::collect_headers(&response, &config.body_options);

    // Text or base64 depending on Content-Type — see activities::http_response.
    let mut response_body =
        crate::activities::http_response::read_body(response, &config.body_options).await?;

    if !status.is_server_error() {
        response_body
            .store_in_sink(
                &config.body_options,
                audit_user,
                config.database.as_deref(),
                &semaphore,
                Duration::from_secs(config.timeout_seconds),
            )
            .await?;
    }

    let duration_ms = start.elapsed().as_millis() as u64;
    let is_ok = status.is_success();

    // Build response object — same envelope as execute_http.
    let result = crate::activities::http_response::build_envelope(
        status_code,
        &response_body,
        response_headers,
        is_ok,
        duration_ms,
    );

    ctx.trace_info(format!(
        "HTTP_MULTIPART {} completed: status={}, ok={}, encoding={}, duration={}ms",
        config.method,
        status_code,
        is_ok,
        response_body.encoding(),
        duration_ms
    ));

    // Fail on 5xx server errors (transient, should retry)
    if status.is_server_error() {
        return Err(format!(
            "HTTP_MULTIPART {} {safe_url} returned {}: {}",
            config.method,
            status_code,
            response_body.error_preview()
        ));
    }

    // Return response for all other cases (including 4xx)
    Ok(result.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn http_request_cap_includes_multipart_framing_and_ignores_spoofed_length() {
        let client = reqwest::Client::new();
        let parts = [MultipartPart {
            name: "field".to_string(),
            filename: Some("file.txt".to_string()),
            content_type: Some("text/plain".to_string()),
            data_b64: "YWJj".to_string(),
        }];
        let build = |limit| {
            build_multipart_request(
                client
                    .post("https://example.com/")
                    .header("Content-Length", "1"),
                &parts,
                &HttpBodyOptions {
                    max_request_bytes: Some(limit),
                    ..Default::default()
                },
            )
        };
        assert!(build(3).unwrap_err().contains("max_request_bytes"));
        let mut request = build(4096).unwrap();
        let length: u64 = request.headers()[reqwest::header::CONTENT_LENGTH]
            .to_str()
            .unwrap()
            .parse()
            .unwrap();
        assert!(length > 3);
        assert_eq!(
            request
                .headers()
                .get_all(reqwest::header::CONTENT_LENGTH)
                .iter()
                .count(),
            1
        );
        let body = reqwest::Response::from(http::Response::new(request.body_mut().take().unwrap()))
            .bytes()
            .await
            .unwrap();
        assert_eq!(body.len() as u64, length);
        assert!(build(length).is_ok());
        assert!(build(length - 1).unwrap_err().contains("max_request_bytes"));
    }

    /// Mirror of PostgreSQL's `encode(bytea, 'base64')`: RFC 2045 §6.8 line
    /// breaking at 76 characters.
    fn pg_style_encode(data: &[u8]) -> String {
        let flat = base64::engine::general_purpose::STANDARD.encode(data);
        flat.as_bytes()
            .chunks(76)
            .map(|c| std::str::from_utf8(c).unwrap())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn decodes_unwrapped_base64() {
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"hello");
        assert_eq!(decode_part_data(&encoded).unwrap(), b"hello");
    }

    #[test]
    fn decodes_pg_wrapped_base64() {
        // 200 bytes -> 268 base64 chars -> wrapped across 4 lines.
        let payload: Vec<u8> = (0u8..200).collect();
        let encoded = pg_style_encode(&payload);
        assert!(
            encoded.contains('\n'),
            "fixture must exercise line wrapping"
        );
        assert_eq!(decode_part_data(&encoded).unwrap(), payload);
    }

    #[test]
    fn decodes_with_surrounding_whitespace() {
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"hello");
        let padded = format!("  \n{encoded}\n  ");
        assert_eq!(decode_part_data(&padded).unwrap(), b"hello");
    }

    #[test]
    fn decodes_with_crlf_line_endings() {
        let payload: Vec<u8> = (0u8..200).collect();
        let encoded = pg_style_encode(&payload).replace('\n', "\r\n");
        assert_eq!(decode_part_data(&encoded).unwrap(), payload);
    }

    #[test]
    fn decodes_empty_payload() {
        assert_eq!(decode_part_data("").unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn rejects_malformed_base64() {
        assert!(decode_part_data("!!!!").is_err());
        // Whitespace stripping must not rescue genuinely invalid input.
        assert!(decode_part_data("!!\n!!").is_err());
    }
}
