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
/// Signature resolution uses `to_regprocedure()` for the same backward
/// compatibility reason described there.
async fn check_multipart_privilege(pool: &PgPool, submitted_by: &str) -> Result<(), String> {
    let verdict: Option<String> = sqlx::query_scalar(
        "SELECT CASE \
             WHEN p.oid IS NULL THEN 'absent' \
             WHEN pg_catalog.has_function_privilege($1::regrole, p.oid, 'EXECUTE') THEN 'allowed' \
             ELSE 'denied' \
         END \
         FROM (SELECT COALESCE( \
             pg_catalog.to_regprocedure('df.http_multipart(text,text,jsonb,jsonb,integer,jsonb)'), \
             pg_catalog.to_regprocedure('df.http_multipart(text,text,jsonb,jsonb,integer)') \
         ) AS oid) p",
    )
    .bind(submitted_by)
    .fetch_optional(pool)
    .await
    .map_err(|e| format!("HTTP privilege check failed for role '{submitted_by}': {e}"))?;

    match verdict.as_deref() {
        Some("allowed") => Ok(()),
        Some("absent") => Err(format!(
            "Blocked: df.http_multipart() is not installed in this database, so the multipart \
             HTTP privilege of role '{submitted_by}' cannot be verified."
        )),
        _ => Err(format!(
            "Blocked: role '{submitted_by}' does not have EXECUTE privilege on df.http_multipart(). \
             Grant EXECUTE ON FUNCTION df.http_multipart(text,text,jsonb,jsonb,integer,jsonb) TO {submitted_by} to allow multipart HTTP requests."
        )),
    }
}

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

    // See execute_http: never log or return `config.url` itself.
    let safe_url = crate::redact::redact_url(&config.url);

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
                "HTTP_MULTIPART BLOCKED (privilege) url={safe_url} submitted_by={audit_user}"
            ));
        })?;

    let request_url = crate::ssrf::parse_request_url(&config.url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (malformed) url={} submitted_by={audit_user}",
            config.url
        ));
    })?;

    // --- Scheme validation (always enforced) ---
    crate::ssrf::validate_scheme(&request_url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (scheme) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    // --- Azure endpoint allow-list ---
    crate::ssrf::validate_allowlist(&request_url).inspect_err(|_| {
        ctx.trace_info(format!(
            "HTTP_MULTIPART BLOCKED (allowlist) url={safe_url} submitted_by={audit_user}"
        ));
    })?;

    let start = std::time::Instant::now();
    ctx.trace_info(format!(
        "HTTP_MULTIPART {} {safe_url} ({} parts) submitted_by={audit_user}",
        config.method,
        config.parts.len()
    ));

    // Build client (shared SSRF-safe resolver + timeout) with execute_http.
    let client = build_client(Duration::from_secs(config.timeout_seconds))?;

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
        let bytes = decode_part_data(&part.data_b64)
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
                "HTTP_MULTIPART BLOCKED (ip) url={safe_url} submitted_by={audit_user}"
            ));
            return crate::redact::redact_urls_in(&err_string);
        }

        let status_info = e
            .status()
            .map(|s| format!(" (HTTP {})", s.as_u16()))
            .unwrap_or_default();

        // reqwest's Display interpolates the request URL — scrub it too.
        let detail = crate::redact::redact_urls_in(&err_string);

        if e.is_timeout() {
            format!(
                "HTTP timeout after {}s{}: {}",
                config.timeout_seconds, status_info, safe_url
            )
        } else if e.is_connect() {
            format!("HTTP connection failed{status_info}: {safe_url} - {detail}")
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
        config.method, status_code, is_ok, response_body.encoding, duration_ms
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
