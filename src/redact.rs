// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! Redaction of credential-bearing text before it reaches a log or an error.
//!
//! A URL is a credential carrier: Azure SAS tokens live entirely in the query
//! string, and `?api-key=`/`?code=` are common elsewhere. The worker's tracing
//! subscriber writes at `info` by default (see `worker::init_tracing`), so an
//! unredacted URL lands in the PostgreSQL server log in cleartext — a sink with
//! no RLS, no `pg_durable.retention_days`, and often a different backup path
//! than the database itself. Error strings are worse still: they are persisted
//! to `df.nodes.result` and into duroxide history.
//!
//! Redaction is deliberately lossy and fails closed: anything that cannot be
//! parsed as a URL is replaced wholesale rather than echoed back.

use url::{Position, Url};

/// Stand-in for any elided value. Deliberately not a fixed-width mask, so the
/// length of the original is not disclosed.
pub const REDACTED: &str = "<redacted>";

/// Redact the values in a raw query string, preserving unambiguous parameter names.
///
/// This splits on `&` and `=` rather than using [`Url::query_pairs`], because
/// `query_pairs` follows the form-urlencoded rules and reports a bare token
/// (`?SEKRIT`, no `=`) as the *name* of a valueless parameter. Emitting that
/// would publish the token verbatim. Bare tokens and pairs with empty or
/// padding-only values are elided whole: `token=` and `token==` could be padded
/// opaque tokens rather than parameters.
fn redact_query(query: &str) -> String {
    let mut out = String::with_capacity(query.len());

    for (i, pair) in query.split('&').enumerate() {
        if i > 0 {
            out.push('&');
        }
        match pair.split_once('=') {
            Some((name, value)) if !value.trim_end_matches('=').is_empty() => {
                out.push_str(name);
                out.push('=');
                out.push_str(REDACTED);
            }
            _ => out.push_str(REDACTED),
        }
    }

    out
}

/// Redact the credential-bearing parts of a single URL.
///
/// Preserved: scheme, host, port, path. Elided: userinfo, every query-parameter
/// value, and the fragment.
///
/// The output is rebuilt from the parsed components rather than by mutating the
/// [`Url`], because the setters percent-encode `<` and `>` and would turn the
/// marker into `%3Credacted%3E`.
pub fn redact_url(url: &str) -> String {
    let Ok(parsed) = Url::parse(url) else {
        // Not parseable — never echo it back.
        return REDACTED.to_string();
    };

    let mut out = String::with_capacity(url.len());
    out.push_str(&parsed[..Position::BeforeUsername]);

    // Keep only the fact that credentials were present, not which.
    if !parsed.username().is_empty() || parsed.password().is_some() {
        out.push_str(REDACTED);
        out.push('@');
    }

    out.push_str(&parsed[Position::BeforeHost..Position::AfterPath]);

    if let Some(query) = parsed.query().filter(|q| !q.is_empty()) {
        out.push('?');
        out.push_str(&redact_query(query));
    }

    if parsed.fragment().is_some() {
        out.push('#');
        out.push_str(REDACTED);
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_sas_token_query_string() {
        let redacted = redact_url(
            "https://acct.blob.core.windows.net/c/b?sv=2022-11-02&ss=b&sig=abc%2Fdef%3D",
        );
        assert_eq!(
            redacted,
            "https://acct.blob.core.windows.net/c/b?sv=<redacted>&ss=<redacted>&sig=<redacted>"
        );
        assert!(!redacted.contains("abc"));
    }

    #[test]
    fn redacts_query_values_regardless_of_parameter_name() {
        for name in [
            "api-version",
            "API-Version",
            "apiversion",
            "comp",
            "restype",
        ] {
            assert_eq!(
                redact_url(&format!("https://h/p?{name}=SEKRIT")),
                format!("https://h/p?{name}=<redacted>")
            );
        }
    }

    #[test]
    fn preserves_scheme_host_port_and_path() {
        assert_eq!(
            redact_url("https://host.example.com:8443/a/b/c"),
            "https://host.example.com:8443/a/b/c"
        );
    }

    #[test]
    fn redacts_userinfo_but_keeps_host() {
        assert_eq!(
            redact_url("https://user:pa%40ss@host.example.com/p"),
            "https://<redacted>@host.example.com/p"
        );
    }

    #[test]
    fn redacts_fragment() {
        assert_eq!(
            redact_url("https://h/p#access_token=SEKRIT"),
            "https://h/p#<redacted>"
        );
        assert_eq!(
            redact_url("https://h/p?a=1#access_token=SEKRIT"),
            "https://h/p?a=<redacted>#<redacted>"
        );
    }

    #[test]
    fn preserves_urls_without_authority() {
        assert_eq!(
            redact_url("mailto:alice@example.com?body=SEKRIT#SEKRIT"),
            "mailto:alice@example.com?body=<redacted>#<redacted>"
        );
    }

    #[test]
    fn handles_bracketed_ipv6_authority() {
        assert_eq!(
            redact_url("http://[2001:db8::1]:8080/p?k=v"),
            "http://[2001:db8::1]:8080/p?k=<redacted>"
        );
    }

    #[test]
    fn handles_authority_only_urls() {
        // An empty path normalizes to "/" per the WHATWG URL spec.
        assert_eq!(redact_url("https://host"), "https://host/");
        assert_eq!(redact_url("https://host?k=v"), "https://host/?k=<redacted>");
        assert_eq!(redact_url("https://host#f"), "https://host/#<redacted>");
        assert_eq!(redact_url("https://host/"), "https://host/");
    }

    #[test]
    fn empty_query_does_not_emit_question_mark() {
        assert_eq!(redact_url("https://h/p?"), "https://h/p");
    }

    #[test]
    fn redacts_empty_valued_query_pairs() {
        assert_eq!(
            redact_url("https://h/p?a=&b=SEKRIT&="),
            "https://h/p?<redacted>&b=<redacted>&<redacted>"
        );
    }

    #[test]
    fn padded_query_tokens_are_not_treated_as_parameter_names() {
        for token in ["c2VjcmV0=", "c2VjcmV0MQ=="] {
            assert_eq!(
                redact_url(&format!("https://h/p?{token}")),
                "https://h/p?<redacted>"
            );
            assert_eq!(
                redact_url(&format!("https://h/p?a=1&{token}&b=2")),
                "https://h/p?a=<redacted>&<redacted>&b=<redacted>"
            );
            assert_eq!(
                redact_url(&format!("https://h/p?token={token}")),
                "https://h/p?token=<redacted>"
            );
        }
    }

    #[test]
    fn fails_closed_on_non_url_input() {
        assert_eq!(redact_url(""), REDACTED);
        assert_eq!(redact_url("not a url"), REDACTED);
        assert_eq!(redact_url("/relative/path?sig=SEKRIT"), REDACTED);
    }

    #[test]
    fn keeps_unsubstituted_placeholders_legible() {
        // A URL whose {var} placeholders were never substituted still reaches
        // redaction. Nothing is lost: the host keeps its placeholder verbatim
        // and the path is percent-encoded, so the mistake is still diagnosable.
        assert_eq!(
            redact_url("https://{kv_host}/secrets/{name}?api-version=7.4"),
            "https://{kv_host}/secrets/%7Bname%7D?api-version=<redacted>"
        );
    }

    #[test]
    fn bare_query_token_is_not_treated_as_a_parameter_name() {
        // Url::query_pairs follows the form-urlencoded rules and reports a bare
        // token as the NAME of a valueless parameter. Rebuilding the query from
        // those pairs would publish the token verbatim, which is why
        // redact_query splits on '&'/'=' itself. Pin the hazard so a future
        // refactor to query_pairs fails loudly here.
        let parsed = Url::parse("https://h/p?SEKRIT").unwrap();
        let names: Vec<_> = parsed.query_pairs().map(|(k, _)| k.into_owned()).collect();
        assert_eq!(names, vec!["SEKRIT".to_string()]);

        assert_eq!(redact_url("https://h/p?SEKRIT"), "https://h/p?<redacted>");
    }

    #[test]
    fn redacts_query_values_containing_url_punctuation() {
        for punctuation in [",", "(", ")", "'", "<", ">", "\\", "^", "`", "|", "\""] {
            assert_eq!(
                redact_url(&format!("https://h/p?sig=FIRST{punctuation}LAST")),
                "https://h/p?sig=<redacted>"
            );
        }
    }

    #[test]
    fn reqwest_errors_can_remove_sensitive_urls() {
        let url = Url::parse("https://user:password@h/p?sig=FIRST,(LAST)#SEKRIT").unwrap();
        let error = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(url.clone())
            .header("invalid header name", "value")
            .build()
            .unwrap_err()
            .with_url(url);
        assert!(error.to_string().contains("FIRST,(LAST)"));

        let error = error.without_url();
        assert!(error.is_builder());
        assert!(error.url().is_none());
        assert_eq!(error.to_string(), "builder error");
    }

    #[test]
    fn redaction_is_idempotent() {
        for url in [
            "https://h/p?sig=SEKRIT",
            "https://user:pa%40ss@h/p?sig=SEKRIT#SEKRIT",
            "https://h/p?SEKRIT",
            "https://h/p?a=&b=SEKRIT&=",
            "https://h/p?c2VjcmV0=",
            "https://h/p?c2VjcmV0MQ==",
            "mailto:alice@example.com?body=SEKRIT#SEKRIT",
        ] {
            let once = redact_url(url);
            assert_eq!(redact_url(&once), once);
        }
    }
}
