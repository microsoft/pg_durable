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
//! now classified by their `Content-Type`: textual types are returned verbatim,
//! everything else is base64-encoded. The envelope's `encoding` field says which
//! happened.
//!
//! The body stays in the `body` field either way. That is deliberate: a caller
//! can feed `$response.body` straight into a multipart part's `data_b64` without
//! branching on the encoding.

use base64::Engine as _;

/// Maximum number of characters of a response body to embed in a 5xx error
/// message. Without a cap, a large binary error response would be base64-encoded
/// into the error string and then persisted in the duroxide history — several
/// times over, since the history records both activity input and output.
const ERROR_BODY_PREVIEW_LIMIT: usize = 512;

/// Report whether a `Content-Type` header value denotes a textual body.
///
/// Absent, empty, or unparseable values are treated as textual, which preserves
/// the behaviour that predates binary support.
pub fn is_textual_content_type(content_type: Option<&str>) -> bool {
    let Some(content_type) = content_type else {
        return true;
    };

    // Strip parameters (`; charset=utf-8`) and normalize.
    let mime = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();

    if mime.is_empty() {
        return true;
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
        if self.body.len() <= ERROR_BODY_PREVIEW_LIMIT {
            return self.body.clone();
        }
        // Slice on a character boundary — a textual body may hold multi-byte
        // characters, and panicking while building an error message would turn a
        // reportable failure into a worker crash.
        let mut end = ERROR_BODY_PREVIEW_LIMIT;
        while end > 0 && !self.body.is_char_boundary(end) {
            end -= 1;
        }
        format!(
            "{}... [truncated, {} bytes total]",
            &self.body[..end],
            self.body.len()
        )
    }
}

/// Read a response body, choosing text or base64 based on `Content-Type`.
pub async fn read_body(response: reqwest::Response) -> Result<ResponseBody, String> {
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    if is_textual_content_type(content_type.as_deref()) {
        let text = response
            .text()
            .await
            .map_err(|e| format!("Failed to read response body: {e}"))?;
        Ok(ResponseBody::text(text))
    } else {
        let bytes = response
            .bytes()
            .await
            .map_err(|e| format!("Failed to read response body: {e}"))?;
        Ok(ResponseBody::base64(&bytes))
    }
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
                is_textual_content_type(Some(ct)),
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
                is_textual_content_type(Some(ct)),
                "expected `{ct}` to be textual"
            );
        }
    }

    #[test]
    fn classifies_binary_types_as_binary() {
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
                !is_textual_content_type(Some(ct)),
                "expected `{ct}` to be binary"
            );
        }
    }

    #[test]
    fn treats_absent_or_empty_content_type_as_textual() {
        // Preserves pre-binary-support behaviour for servers that omit the header.
        assert!(is_textual_content_type(None));
        assert!(is_textual_content_type(Some("")));
        assert!(is_textual_content_type(Some("   ")));
        assert!(is_textual_content_type(Some(";charset=utf-8")));
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
