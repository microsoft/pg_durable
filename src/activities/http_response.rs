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

/// Read a response body as text or base64, preferring the declared type and
/// falling back to inspecting the bytes.
pub async fn read_body(response: reqwest::Response) -> Result<ResponseBody, String> {
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    // A declared textual type is decoded by reqwest, which honours the `charset`
    // parameter. Decoding these ourselves would silently narrow them to UTF-8.
    if is_declared_textual(content_type.as_deref()) {
        let text = response
            .text()
            .await
            .map_err(|e| format!("Failed to read response body: {e}"))?;
        return Ok(ResponseBody::text(text));
    }

    let bytes = response
        .bytes()
        .await
        .map_err(|e| format!("Failed to read response body: {e}"))?;
    Ok(match text_from_bytes(&bytes) {
        Some(text) => ResponseBody::text(text),
        None => ResponseBody::base64(&bytes),
    })
}

/// Collect response headers into a JSON object, skipping any that are not valid
/// UTF-8.
pub fn collect_headers(response: &reqwest::Response) -> serde_json::Map<String, serde_json::Value> {
    response
        .headers()
        .iter()
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
    body: &ResponseBody,
    headers: serde_json::Map<String, serde_json::Value>,
    is_ok: bool,
    duration_ms: u64,
) -> serde_json::Value {
    serde_json::json!({
        "status": status_code,
        "body": body.body,
        "encoding": body.encoding,
        "headers": headers,
        "ok": is_ok,
        "duration_ms": duration_ms
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let envelope = build_envelope(200, &body, serde_json::Map::new(), true, 12);
        assert_eq!(envelope["status"], 200);
        assert_eq!(envelope["encoding"], "base64");
        assert_eq!(envelope["ok"], true);
        assert_eq!(envelope["duration_ms"], 12);
        assert!(envelope["body"].is_string());
    }
}
