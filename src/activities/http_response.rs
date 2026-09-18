// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Shared response handling for the HTTP activities.
//!
//! `execute_http` and `execute_multipart` return the same envelope, so the
//! construction lives here rather than being duplicated in both. Sharing it is
//! not merely tidiness: a response-handling difference between the two would be
//! a silent correctness gap, since which activity a workflow reaches for is an
//! implementation detail of the endpoint being called, not of the payload.
//!
//! ## Text vs. binary bodies
//!
//! Response bodies were historically decoded as UTF-8 unconditionally, which
//! corrupts any non-text payload — audio, images, archives, protobuf. Bodies are
//! now classified in two stages, because neither the header nor the bytes alone
//! are enough:
//!
//! 1. A `Content-Type` that *declares* a textual type is decoded as text, using
//!    the charset the server named. This has to come first: a body declared
//!    `text/plain; charset=iso-8859-1` is not UTF-8, and inspecting its bytes
//!    would wrongly conclude it is binary.
//! 2. Everything else — an unrecognised type, or no type at all — is decided by
//!    its bytes rather than its label. Labels are unreliable in both directions:
//!    servers omit the header for binary downloads, emit `application/octet-stream`
//!    for JSON, and use textual types that no allowlist will ever cover in full
//!    (`application/jwt`, `application/x-ndjson`).
//!
//! The envelope's `encoding` field says which happened.
//!
//! The body stays in the `body` field either way, so a caller always knows where
//! to look. Feeding it straight into a multipart part's `data_b64` is valid only
//! when `encoding` is `base64`; a textual body is not base64 and will be
//! rejected by the part decoder.

use base64::Engine as _;
use sha2::{Digest, Sha256};
use sqlx::Connection;
use std::time::Duration;
use tokio::sync::Semaphore;

use crate::types::{
    HttpBodyOptions, HttpResponseHeaderPreset, HttpResponseHeaders, HttpResponseMode,
};

const SAFE_RESPONSE_HEADERS: &[&str] = &[
    "content-type",
    "content-length",
    "etag",
    "last-modified",
    "x-ms-request-id",
    "x-ms-version",
    "x-request-id",
    "content-md5",
    "x-ms-content-crc64",
    "x-ms-blob-content-md5",
    "digest",
    "content-digest",
    "repr-digest",
];

/// Maximum number of bytes of a response body to embed in a 5xx error message.
/// Without a cap, a large binary error response would be base64-encoded into the
/// error string and then persisted in the duroxide history — several times over,
/// since the history records both activity input and output.
const ERROR_BODY_PREVIEW_BYTES: usize = 512;

/// Report whether a `Content-Type` header value *declares* a textual body.
///
/// A `false` here does not mean the body is binary — only that the header does
/// not vouch for it being text. Absent, empty, and unparseable values fall into
/// that bucket and are settled by inspecting the bytes; see [`text_from_bytes`].
pub fn is_declared_textual(content_type: Option<&str>) -> bool {
    let Some(content_type) = content_type else {
        return false;
    };

    // Strip any secondary value (a proxy folding duplicate headers can emit
    // `text/html, application/octet-stream`) and then parameters
    // (`; charset=utf-8`), and normalize.
    let mime = content_type
        .split(',')
        .next()
        .unwrap_or("")
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();

    if mime.is_empty() {
        return false;
    }

    if mime.starts_with("text/") {
        return true;
    }

    // Structured syntax suffixes (RFC 6839): application/vnd.api+json,
    // image/svg+xml, and friends are text despite their top-level type.
    if mime.ends_with("+json") || mime.ends_with("+xml") || mime.ends_with("+yaml") {
        return true;
    }

    matches!(
        mime.as_str(),
        "application/json"
            | "application/xml"
            | "application/javascript"
            | "application/ecmascript"
            | "application/x-www-form-urlencoded"
            | "application/graphql"
            | "application/yaml"
            | "application/x-yaml"
    )
}

/// The decoded body of a response, along with how it was encoded for transport
/// through the (text-only) result pipeline.
pub struct ResponseBody {
    pub body: String,
    pub encoding: &'static str,
}

impl ResponseBody {
    fn text(body: String) -> Self {
        Self {
            body,
            encoding: "text",
        }
    }

    fn base64(bytes: &[u8]) -> Self {
        Self {
            body: base64::engine::general_purpose::STANDARD.encode(bytes),
            encoding: "base64",
        }
    }

    /// A bounded excerpt suitable for embedding in an error message.
    pub fn error_preview(&self) -> String {
        if self.body.len() <= ERROR_BODY_PREVIEW_BYTES {
            return self.body.clone();
        }
        // Slice on a character boundary — a textual body may hold multi-byte
        // characters, and panicking while building an error message would turn a
        // reportable failure into a worker crash.
        let mut end = ERROR_BODY_PREVIEW_BYTES;
        while end > 0 && !self.body.is_char_boundary(end) {
            end -= 1;
        }
        // Name the unit: for a base64 body this is the encoded length, which is
        // ~4/3 of the response size, and reporting it unqualified would mislead
        // whoever is reading the failure back out of the history.
        let unit = if self.encoding == "base64" {
            "base64 characters"
        } else {
            "bytes"
        };
        format!(
            "{}... [truncated, {} {} total]",
            &self.body[..end],
            self.body.len(),
            unit
        )
    }
}

/// Decode `bytes` as text, or return `None` if they cannot be carried as text.
///
/// Valid UTF-8 is necessary but not sufficient: PostgreSQL's `text` type cannot
/// hold a NUL byte, so a NUL-containing body has to travel as base64 even though
/// `str::from_utf8` accepts it. Without this check a body of mostly-zero bytes —
/// silence in an uncompressed audio file, padding in a disk image — would be
/// classified as text and then fail on the way into the result row, far from the
/// decision that caused it.
fn text_from_bytes(bytes: &[u8]) -> Option<String> {
    if bytes.contains(&0) {
        return None;
    }
    std::str::from_utf8(bytes).ok().map(str::to_string)
}

pub struct ResponseContent {
    inline: Option<ResponseBody>,
    bytes: u64,
    sha256: Option<String>,
    sink_body: Option<Vec<u8>>,
    sink: Option<StoredResponse>,
}

struct StoredResponse {
    table: String,
    key: uuid::Uuid,
    database: String,
}

fn sink_error(operation: &str, error: sqlx::Error) -> String {
    match error.as_database_error().and_then(|error| error.code()) {
        Some(code) => format!("HTTP response sink {operation} failed (SQLSTATE {code})"),
        None => format!("HTTP response sink {operation} failed (connection or protocol error)"),
    }
}

async fn store_response(
    table: &str,
    body: &[u8],
    sha256: &str,
    submitted_by: &str,
    database: Option<&str>,
    semaphore: &Semaphore,
    timeout: Duration,
) -> Result<StoredResponse, String> {
    let _permit = crate::types::acquire_execution_permit(
        semaphore,
        crate::types::get_execution_acquire_timeout(),
        crate::types::get_max_user_connections(),
    )
    .await?;
    let mut connection = crate::types::connect_as_user(submitted_by, database).await?;
    let mut transaction = connection
        .begin()
        .await
        .map_err(|error| sink_error("transaction", error))?;
    sqlx::query(
        "SELECT pg_catalog.set_config('synchronous_commit', 'on', true),
                pg_catalog.set_config('statement_timeout', $1, true)",
    )
    .bind(format!("{}ms", timeout.as_millis().min(i32::MAX as u128)))
    .execute(&mut *transaction)
    .await
    .map_err(|error| sink_error("transaction setup", error))?;
    let identity_matches: bool = sqlx::query_scalar(
        "SELECT CURRENT_USER::pg_catalog.text OPERATOR(pg_catalog.=) $1
            AND SESSION_USER::pg_catalog.text OPERATOR(pg_catalog.=) $1",
    )
    .bind(submitted_by)
    .fetch_one(&mut *transaction)
    .await
    .map_err(|error| sink_error("identity check", error))?;
    if !identity_matches {
        return Err("HTTP response sink connection does not match the submitting role".into());
    }
    let qualified: Option<String> = sqlx::query_scalar(crate::types::HTTP_SINK_TABLE_NAME_SQL)
        .bind(table)
        .fetch_one(&mut *transaction)
        .await
        .map_err(|error| sink_error("table name validation", error))?;
    let qualified =
        qualified.ok_or("HTTP response sink 'into' must be a schema-qualified table")?;
    sqlx::query(&format!(
        "LOCK TABLE ONLY {qualified} IN ROW EXCLUSIVE MODE"
    ))
    .execute(&mut *transaction)
    .await
    .map_err(|error| sink_error("table lock", error))?;
    let destination: Option<(String, String)> = sqlx::query_as(
        "SELECT pg_catalog.format('%I.%I', namespace.nspname, relation.relname),
                pg_catalog.current_database()::pg_catalog.text
         FROM pg_catalog.pg_class AS relation
         JOIN pg_catalog.pg_namespace AS namespace
           ON namespace.oid OPERATOR(pg_catalog.=) relation.relnamespace
         WHERE relation.oid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)
                     AND (relation.relkind OPERATOR(pg_catalog.=) 'r' OR relation.relkind OPERATOR(pg_catalog.=) 'p')
                     AND relation.relpersistence OPERATOR(pg_catalog.=) 'p'",
    )
    .bind(&qualified)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(|error| sink_error("table validation", error))?;
    let (table, database) = destination.ok_or("HTTP response sink requires a permanent table")?;
    let key = uuid::Uuid::new_v4();
    let inserted = sqlx::query(&format!(
        "INSERT INTO {table} (sink_key, body) VALUES ($1::pg_catalog.uuid, $2::pg_catalog.bytea)"
    ))
    .bind(key)
    .bind(body)
    .execute(&mut *transaction)
    .await
    .map_err(|error| sink_error("insert", error))?;
    if inserted.rows_affected() != 1 {
        return Err("HTTP response sink did not insert exactly one row".into());
    }
    sqlx::query("SET CONSTRAINTS ALL IMMEDIATE")
        .execute(&mut *transaction)
        .await
        .map_err(|error| sink_error("constraint check", error))?;
    let matches: bool = sqlx::query_scalar(&format!(
        "SELECT pg_catalog.count(*) OPERATOR(pg_catalog.=) 1
            AND COALESCE(pg_catalog.bool_and(
                pg_catalog.encode(pg_catalog.sha256(stored.body), 'hex')
                    OPERATOR(pg_catalog.=) $2::pg_catalog.text
                AND relation.relpersistence OPERATOR(pg_catalog.=) 'p'
                AND relation.relkind OPERATOR(pg_catalog.=) 'r'), false)
         FROM {table} AS stored
         JOIN pg_catalog.pg_class AS relation ON relation.oid OPERATOR(pg_catalog.=) stored.tableoid
         WHERE stored.sink_key OPERATOR(pg_catalog.=) $1::pg_catalog.uuid"
    ))
    .bind(key)
    .bind(sha256)
    .fetch_one(&mut *transaction)
    .await
    .map_err(|error| sink_error("stored body verification", error))?;
    if !matches {
        return Err(
            "HTTP response sink row is missing, not durable, or its key or body was changed".into(),
        );
    }
    sqlx::query("SET LOCAL synchronous_commit = on")
        .execute(&mut *transaction)
        .await
        .map_err(|error| sink_error("commit setup", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| sink_error("commit", error))?;
    connection
        .close()
        .await
        .map_err(|error| sink_error("connection close", error))?;
    Ok(StoredResponse {
        table,
        key,
        database,
    })
}

impl ResponseContent {
    pub fn encoding(&self) -> &'static str {
        self.inline.as_ref().map_or("omitted", |body| body.encoding)
    }

    pub fn error_preview(&self) -> String {
        self.inline.as_ref().map_or_else(
            || format!("response body omitted ({} bytes)", self.bytes),
            ResponseBody::error_preview,
        )
    }

    pub async fn store_in_sink(
        &mut self,
        options: &HttpBodyOptions,
        submitted_by: &str,
        database: Option<&str>,
        semaphore: &Semaphore,
        timeout: Duration,
    ) -> Result<(), String> {
        let Some(body) = self.sink_body.as_deref() else {
            return Ok(());
        };
        let table = options
            .into
            .as_deref()
            .ok_or("HTTP response sink is missing 'into'")?;
        let sha256 = self
            .sha256
            .as_deref()
            .ok_or("HTTP response sink is missing its digest")?;
        let stored = tokio::time::timeout(
            timeout,
            store_response(
                table,
                body,
                sha256,
                submitted_by,
                database,
                semaphore,
                timeout,
            ),
        )
        .await
        .map_err(|_| "HTTP response sink timed out before completion")??;
        self.sink = Some(stored);
        self.sink_body = None;
        Ok(())
    }
}

pub async fn read_body(
    mut response: reqwest::Response,
    options: &HttpBodyOptions,
) -> Result<ResponseContent, String> {
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .cloned();
    let mode = options.response.unwrap_or_default();
    let limit = options.max_response_bytes.unwrap_or(u64::MAX);
    let exceeded = || format!("HTTP response body exceeds max_response_bytes ({limit} bytes)");
    if response
        .content_length()
        .is_some_and(|length| length > limit)
    {
        return Err(exceeded());
    }

    let mut bytes = Vec::new();
    let mut total_bytes = 0;
    let mut sha256 =
        matches!(mode, HttpResponseMode::Metadata | HttpResponseMode::Sink).then(Sha256::new);
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| format!("Failed to read response body: {}", error.without_url()))?
    {
        if chunk.len() as u64 > limit - total_bytes {
            return Err(exceeded());
        }
        total_bytes += chunk.len() as u64;
        if matches!(mode, HttpResponseMode::Inline | HttpResponseMode::Sink) {
            bytes.extend_from_slice(&chunk);
        }
        if let Some(hasher) = &mut sha256 {
            hasher.update(&chunk);
        }
    }
    let sink_body = (mode == HttpResponseMode::Sink).then(|| std::mem::take(&mut bytes));
    let inline = if mode != HttpResponseMode::Inline {
        None
    } else if is_declared_textual(content_type.as_ref().and_then(|value| value.to_str().ok())) {
        let mut buffered = http::Response::new(bytes);
        if let Some(content_type) = content_type {
            buffered
                .headers_mut()
                .insert(reqwest::header::CONTENT_TYPE, content_type);
        }
        let text = reqwest::Response::from(buffered)
            .text()
            .await
            .map_err(|error| format!("Failed to read response body: {}", error.without_url()))?;
        Some(ResponseBody::text(text))
    } else {
        Some(match text_from_bytes(&bytes) {
            Some(text) => ResponseBody::text(text),
            None => ResponseBody::base64(&bytes),
        })
    };
    Ok(ResponseContent {
        inline,
        bytes: total_bytes,
        sha256: sha256.map(|hasher| format!("{:x}", hasher.finalize())),
        sink_body,
        sink: None,
    })
}

/// Collect response headers into a JSON object, skipping any that are not valid
/// UTF-8.
pub fn collect_headers(
    response: &reqwest::Response,
    options: &HttpBodyOptions,
) -> serde_json::Map<String, serde_json::Value> {
    response
        .headers()
        .iter()
        .filter(|(name, _)| match &options.response_headers {
            None | Some(HttpResponseHeaders::Preset(HttpResponseHeaderPreset::All)) => true,
            Some(HttpResponseHeaders::Preset(HttpResponseHeaderPreset::Safe)) => {
                SAFE_RESPONSE_HEADERS.contains(&name.as_str())
            }
            Some(HttpResponseHeaders::AllowList(names)) => names
                .iter()
                .any(|allowed| allowed.eq_ignore_ascii_case(name.as_str())),
        })
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|s| (k.to_string(), serde_json::Value::String(s.to_string())))
        })
        .collect()
}

/// Build the JSON envelope returned by both HTTP activities.
pub fn build_envelope(
    status_code: u16,
    content: &ResponseContent,
    headers: serde_json::Map<String, serde_json::Value>,
    is_ok: bool,
    duration_ms: u64,
) -> serde_json::Value {
    if let Some(body) = &content.inline {
        return serde_json::json!({
            "status": status_code,
            "body": body.body,
            "encoding": body.encoding,
            "headers": headers,
            "ok": is_ok,
            "duration_ms": duration_ms
        });
    }
    let mut envelope = serde_json::json!({
        "status": status_code,
        "ok": is_ok,
        "bytes": content.bytes,
        "headers": headers,
        "duration_ms": duration_ms,
    });
    if let Some(sha256) = &content.sha256 {
        envelope["sha256"] = serde_json::Value::String(sha256.clone());
    }
    if let Some(sink) = &content.sink {
        envelope["sink"] = serde_json::Value::String(sink.table.clone());
        envelope["sink_key"] = serde_json::Value::String(sink.key.to_string());
        envelope["sink_database"] = serde_json::Value::String(sink.database.clone());
    }
    envelope
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sink_buffers_raw_bytes_without_decoding_or_error_previews() {
        let bytes = b"\0\xffHTTP_SINK_PRIVATE";
        let response = reqwest::Response::from(
            http::Response::builder()
                .header("content-type", "text/plain; charset=utf-16")
                .body(bytes.to_vec())
                .unwrap(),
        );
        let options = HttpBodyOptions {
            response: Some(HttpResponseMode::Sink),
            into: Some("public.payloads".into()),
            max_response_bytes: Some(bytes.len() as u64),
            ..Default::default()
        };
        let content = read_body(response, &options).await.unwrap();
        assert!(content.inline.is_none());
        assert_eq!(content.sink_body.as_deref(), Some(bytes.as_slice()));
        assert_eq!(content.bytes, bytes.len() as u64);
        assert_eq!(content.sha256, Some(format!("{:x}", Sha256::digest(bytes))));
        assert!(!content.error_preview().contains("HTTP_SINK_PRIVATE"));
        let envelope = build_envelope(200, &content, serde_json::Map::new(), true, 1);
        assert!(envelope.get("body").is_none());
        assert!(envelope.get("encoding").is_none());
        assert!(envelope.get("sink_key").is_none());
    }

    async fn raw_response(wire_bytes: &'static [u8]) -> reqwest::Response {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;
        use std::time::Duration;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (connection, _) = listener.accept().unwrap();
            connection
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut connection = BufReader::new(connection);
            loop {
                let mut line = String::new();
                if connection.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                    break;
                }
            }
            connection.get_mut().write_all(wire_bytes).unwrap();
        });
        let response = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap()
            .get(format!("http://{address}/?sig=PRIVATE"))
            .send()
            .await
            .unwrap();
        server.join().unwrap();
        response
    }

    #[tokio::test]
    async fn bounded_reader_accepts_exact_limit_and_empty_bodies() {
        let response = raw_response(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n",
        )
        .await;
        let options = HttpBodyOptions {
            max_response_bytes: Some(4),
            ..Default::default()
        };
        let content = read_body(response, &options).await.unwrap();
        assert_eq!(content.inline.unwrap().body, "abcd");
        assert_eq!(content.bytes, 4);

        let response = raw_response(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n").await;
        let options = HttpBodyOptions {
            max_response_bytes: Some(0),
            ..Default::default()
        };
        assert!(read_body(response, &options)
            .await
            .unwrap()
            .inline
            .unwrap()
            .body
            .is_empty());
    }

    #[tokio::test]
    async fn bounded_reader_rejects_oversized_bodies_without_finishing_them() {
        for wire_bytes in [
            b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".as_slice(),
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcde\r\n".as_slice(),
            b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabcde".as_slice(),
        ] {
            for mode in [
                HttpResponseMode::Inline,
                HttpResponseMode::Metadata,
                HttpResponseMode::Discard,
                HttpResponseMode::Sink,
            ] {
                let response = raw_response(wire_bytes).await;
                let options = HttpBodyOptions {
                    max_response_bytes: Some(4),
                    response: Some(mode),
                    ..Default::default()
                };
                let error = read_body(response, &options).await.err().unwrap();
                assert_eq!(
                    error,
                    "HTTP response body exceeds max_response_bytes (4 bytes)"
                );
            }
        }
    }

    #[tokio::test]
    async fn metadata_and_discard_omit_bodies_from_results_and_errors() {
        for mode in [HttpResponseMode::Metadata, HttpResponseMode::Discard] {
            let response =
                raw_response(b"HTTP/1.1 500 Error\r\nContent-Length: 3\r\n\r\nabc").await;
            let options = HttpBodyOptions {
                response: Some(mode),
                ..Default::default()
            };
            let content = read_body(response, &options).await.unwrap();
            assert!(content.inline.is_none());
            assert_eq!(content.error_preview(), "response body omitted (3 bytes)");
            let envelope = build_envelope(500, &content, serde_json::Map::new(), false, 1);
            assert_eq!(envelope["bytes"], 3);
            assert!(envelope.get("body").is_none());
            assert!(envelope.get("encoding").is_none());
            if mode == HttpResponseMode::Metadata {
                assert_eq!(
                    envelope["sha256"],
                    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                );
            } else {
                assert!(envelope.get("sha256").is_none());
            }
        }
    }

    #[tokio::test]
    async fn response_limit_counts_decompressed_bytes_in_every_mode() {
        let wire_bytes = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: 24\r\n\r\n\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x33\x30\x18\x58\x00\x00\xe6\x98\x02\x4d\x80\x00\x00\x00";
        for mode in [
            HttpResponseMode::Inline,
            HttpResponseMode::Metadata,
            HttpResponseMode::Discard,
            HttpResponseMode::Sink,
        ] {
            let mut options = HttpBodyOptions {
                max_response_bytes: Some(127),
                response: Some(mode),
                ..Default::default()
            };
            let error = read_body(raw_response(wire_bytes).await, &options)
                .await
                .err()
                .unwrap();
            assert!(error.contains("max_response_bytes (127 bytes)"), "{error}");
            options.max_response_bytes = Some(128);
            let content = read_body(raw_response(wire_bytes).await, &options)
                .await
                .unwrap();
            assert_eq!(content.bytes, 128);
            if mode == HttpResponseMode::Inline {
                assert_eq!(content.inline.unwrap().body, "0".repeat(128));
            } else {
                assert!(content.inline.is_none());
            }
        }
    }

    #[tokio::test]
    async fn response_limit_counts_binary_bytes_before_base64_encoding() {
        let response = reqwest::Response::from(http::Response::new(vec![0u8, 1, 255]));
        let options = HttpBodyOptions {
            max_response_bytes: Some(3),
            ..Default::default()
        };
        let content = read_body(response, &options).await.unwrap();
        assert_eq!(content.bytes, 3);
        let body = content.inline.unwrap();
        assert_eq!(body.encoding, "base64");
        assert_eq!(body.body, "AAH/");
    }

    #[tokio::test]
    async fn bounded_text_decoding_matches_reqwest() {
        for (content_type, bytes) in [
            ("text/plain; charset=iso-8859-1", b"caf\xe9".as_slice()),
            ("text/plain; charset=utf-16le", b"\xff\xfeh\0i\0".as_slice()),
            ("application/json", b"\xef\xbb\xbf{}".as_slice()),
            ("text/plain", b"\xf0\x9f\x98\x80".as_slice()),
        ] {
            let response = || {
                reqwest::Response::from(
                    http::Response::builder()
                        .header(reqwest::header::CONTENT_TYPE, content_type)
                        .body(bytes.to_vec())
                        .unwrap(),
                )
            };
            let expected = response().text().await.unwrap();
            let options = HttpBodyOptions {
                max_response_bytes: Some(bytes.len() as u64),
                ..Default::default()
            };
            let content = read_body(response(), &options).await.unwrap();
            assert_eq!(content.inline.unwrap().body, expected, "{content_type}");
            assert_eq!(content.bytes, bytes.len() as u64);
        }
    }

    #[test]
    fn response_header_filtering_is_explicit_and_case_insensitive() {
        let response = reqwest::Response::from(
            http::Response::builder()
                .header("content-type", "text/plain")
                .header("x-request-id", "request")
                .header("set-cookie", "private")
                .header("x-custom", "custom")
                .body(Vec::<u8>::new())
                .unwrap(),
        );
        for (selection, expected) in [
            (
                serde_json::Value::Null,
                vec!["content-type", "set-cookie", "x-custom", "x-request-id"],
            ),
            (
                serde_json::json!("all"),
                vec!["content-type", "set-cookie", "x-custom", "x-request-id"],
            ),
            (
                serde_json::json!("safe"),
                vec!["content-type", "x-request-id"],
            ),
            (serde_json::json!(["X-Custom"]), vec!["x-custom"]),
            (serde_json::json!([]), vec![]),
        ] {
            let options: HttpBodyOptions = serde_json::from_value(serde_json::json!({
                "response_headers": selection
            }))
            .unwrap();
            options.validate().unwrap();
            let headers = collect_headers(&response, &options);
            let mut names: Vec<_> = headers.keys().map(String::as_str).collect();
            names.sort_unstable();
            assert_eq!(names, expected);
        }
    }

    #[tokio::test]
    async fn response_read_errors_omit_credentials() {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;
        use std::time::Duration;

        for content_type in ["text/plain", "application/octet-stream"] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                let (connection, _) = listener.accept().unwrap();
                connection
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut connection = BufReader::new(connection);
                loop {
                    let mut line = String::new();
                    if connection.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
                        break;
                    }
                }
                write!(
                    connection.get_mut(),
                    "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort"
                )
                .unwrap();
            });

            let response = reqwest::Client::builder()
                .no_proxy()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap()
                .get(format!("http://{address}/?sig=FIRST,(LAST)#SEKRIT"))
                .send()
                .await
                .unwrap();
            let error = read_body(response, &HttpBodyOptions::default())
                .await
                .err()
                .unwrap();
            server.join().unwrap();
            assert!(
                error.starts_with("Failed to read response body:"),
                "{error}"
            );
            assert!(error.contains("error decoding response body"), "{error}");
            assert!(!error.contains("FIRST"), "{error}");
            assert!(!error.contains("SEKRIT"), "{error}");
        }
    }

    #[test]
    fn classifies_text_types_as_textual() {
        for ct in [
            "text/plain",
            "text/plain; charset=utf-8",
            "text/html",
            "TEXT/PLAIN",
            "  text/csv  ",
            "application/json",
            "application/json; charset=utf-8",
            "application/xml",
            "application/javascript",
            "application/x-www-form-urlencoded",
        ] {
            assert!(
                is_declared_textual(Some(ct)),
                "expected `{ct}` to be textual"
            );
        }
    }

    #[test]
    fn classifies_structured_suffixes_as_textual() {
        for ct in [
            "application/vnd.api+json",
            "image/svg+xml",
            "application/problem+json",
        ] {
            assert!(
                is_declared_textual(Some(ct)),
                "expected `{ct}` to be textual"
            );
        }
    }

    #[test]
    fn does_not_declare_binary_types_textual() {
        for ct in [
            "application/octet-stream",
            "audio/mpeg",
            "audio/wav",
            "image/png",
            "application/pdf",
            "application/zip",
            "application/octet-stream; charset=binary",
        ] {
            assert!(
                !is_declared_textual(Some(ct)),
                "expected `{ct}` not to be declared textual"
            );
        }
    }

    #[test]
    fn does_not_declare_absent_or_unparseable_content_type_textual() {
        // These are not assertions that the body is binary — they route it to
        // the sniffing path, which is the only way an untyped binary download
        // avoids being mangled by a UTF-8 decode.
        assert!(!is_declared_textual(None));
        assert!(!is_declared_textual(Some("")));
        assert!(!is_declared_textual(Some("   ")));
        assert!(!is_declared_textual(Some(";charset=utf-8")));
    }

    #[test]
    fn sniffing_accepts_utf8_without_nul() {
        // An unlisted textual type reaches this path; base64-encoding it would
        // be a needless regression for callers already parsing `body`.
        assert_eq!(
            text_from_bytes(b"{\"ok\":true}").as_deref(),
            Some("{\"ok\":true}")
        );
        assert_eq!(
            text_from_bytes("caf\u{e9} \u{1f600}".as_bytes()).as_deref(),
            Some("caf\u{e9} \u{1f600}")
        );
        assert_eq!(text_from_bytes(b"").as_deref(), Some(""));
    }

    #[test]
    fn sniffing_rejects_non_utf8_and_nul_bytes() {
        // Real binary signatures: PNG, and a lone continuation byte.
        assert_eq!(text_from_bytes(&[0x89, b'P', b'N', b'G']), None);
        assert_eq!(text_from_bytes(&[0xff, 0xd8, 0xff]), None);
        // Valid UTF-8, but PostgreSQL cannot store a NUL in `text`.
        assert_eq!(text_from_bytes(b"RIFF\0\0\0\0WAVE"), None);
        assert_eq!(text_from_bytes(&[0u8; 16]), None);
    }

    #[test]
    fn base64_body_round_trips() {
        let bytes: Vec<u8> = (0u8..=255).collect();
        let body = ResponseBody::base64(&bytes);
        assert_eq!(body.encoding, "base64");
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&body.body)
            .unwrap();
        assert_eq!(decoded, bytes);
    }

    #[test]
    fn empty_bodies_are_representable() {
        assert_eq!(ResponseBody::text(String::new()).body, "");
        assert_eq!(ResponseBody::base64(&[]).body, "");
    }

    #[test]
    fn error_preview_passes_short_bodies_through() {
        let body = ResponseBody::text("boom".to_string());
        assert_eq!(body.error_preview(), "boom");
    }

    #[test]
    fn error_preview_truncates_long_bodies() {
        let body = ResponseBody::text("x".repeat(5000));
        let preview = body.error_preview();
        assert!(preview.len() < 700, "preview was {} bytes", preview.len());
        assert!(preview.contains("5000 bytes total"));
    }

    #[test]
    fn error_preview_does_not_split_multibyte_characters() {
        // A body of multi-byte characters whose truncation point falls mid-character.
        let body = ResponseBody::text("é".repeat(1000));
        let preview = body.error_preview();
        assert!(preview.contains("truncated"));
    }

    #[test]
    fn envelope_carries_encoding_alongside_existing_fields() {
        let body = ResponseBody::base64(b"abc");
        let content = ResponseContent {
            inline: Some(body),
            bytes: 3,
            sha256: None,
            sink_body: None,
            sink: None,
        };
        let envelope = build_envelope(200, &content, serde_json::Map::new(), true, 12);
        assert_eq!(envelope["status"], 200);
        assert_eq!(envelope["encoding"], "base64");
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["duration_ms"], 12);
        assert!(envelope["body"].is_string());
    }
}
