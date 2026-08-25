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
//! to `df.nodes.error` and into duroxide history.
//!
//! Redaction is deliberately lossy and fails closed: anything that cannot be
//! parsed as a URL is replaced wholesale rather than echoed back.

/// Stand-in for any elided value. Deliberately not a fixed-width mask, so the
/// length of the original is not disclosed.
pub const REDACTED: &str = "<redacted>";

/// Query parameters whose values carry no credential and are worth keeping for
/// diagnosis. Matched case-insensitively against the parameter name.
const SAFE_QUERY_PARAMS: &[&str] = &["api-version", "apiversion", "comp", "restype"];

/// Characters that cannot appear inside a URL, used to find where an embedded
/// URL ends when scanning free-form text.
///
/// `{` and `}` are deliberately absent: `${secret:name}` markers and `{var}`
/// placeholders appear in unsubstituted URLs and are not credentials, so
/// keeping them intact makes the redacted output far easier to read.
const URL_TERMINATORS: &[char] = &['"', '\'', '<', '>', '\\', '^', '`', '|', '(', ')', ','];

fn is_safe_query_param(name: &str) -> bool {
    SAFE_QUERY_PARAMS
        .iter()
        .any(|safe| name.eq_ignore_ascii_case(safe))
}

/// Redact the credential-bearing parts of a single URL.
///
/// Preserved: scheme, host, port, path. Elided: userinfo, every query-parameter
/// value except [`SAFE_QUERY_PARAMS`], and the fragment.
///
/// Parameter *names* are preserved — `sig`, `code` and friends are not secret,
/// and keeping them makes a redacted log line diagnosable. A bare parameter with
/// no `=` is elided whole, because a lone token is indistinguishable from a name.
pub fn redact_url(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else {
        // Not a URL shape we recognise — never echo it back.
        return REDACTED.to_string();
    };

    // The authority ends at the first '/', '?' or '#'. Splitting on all three
    // matters: `https://host?x=1` and `https://host#f` have no path at all.
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let after_authority = &rest[authority_end..];

    let mut out = String::with_capacity(url.len());
    out.push_str(scheme);
    out.push_str("://");

    // userinfo may be `user:password`; keep only the fact that one was present.
    // rfind, not find: a password may itself contain an encoded '@'.
    match authority.rfind('@') {
        Some(at) => {
            out.push_str(REDACTED);
            out.push('@');
            out.push_str(&authority[at + 1..]);
        }
        None => out.push_str(authority),
    }

    let path_end = after_authority
        .find(['?', '#'])
        .unwrap_or(after_authority.len());
    out.push_str(&after_authority[..path_end]);

    let tail = &after_authority[path_end..];
    let mut query = "";
    let mut has_fragment = false;
    if let Some(after_question) = tail.strip_prefix('?') {
        match after_question.find('#') {
            Some(hash) => {
                query = &after_question[..hash];
                has_fragment = true;
            }
            None => query = after_question,
        }
    } else if tail.starts_with('#') {
        has_fragment = true;
    }

    if !query.is_empty() {
        out.push('?');
        for (i, pair) in query.split('&').enumerate() {
            if i > 0 {
                out.push('&');
            }
            match pair.split_once('=') {
                // An empty value has nothing to elide, and leaving it alone is
                // what makes redaction idempotent: re-redacting `sig=<redacted>`
                // must not append a second marker.
                Some((_, "")) => out.push_str(pair),
                Some((name, _)) if is_safe_query_param(name) => out.push_str(pair),
                Some((name, _)) => {
                    out.push_str(name);
                    out.push('=');
                    out.push_str(REDACTED);
                }
                None => out.push_str(REDACTED),
            }
        }
    }

    if has_fragment {
        out.push('#');
        out.push_str(REDACTED);
    }

    out
}

/// Redact every URL embedded in free-form text.
///
/// Needed because `reqwest::Error`'s `Display` interpolates the request URL, so
/// wrapping a transport error without scrubbing it would reintroduce the very
/// query string [`redact_url`] was applied to remove.
pub fn redact_urls_in(text: &str) -> String {
    if !text.contains("://") {
        return text.to_string();
    }

    let mut out = String::with_capacity(text.len());
    let mut rest = text;

    while let Some(sep) = rest.find("://") {
        // Walk back over the scheme, which must be alphanumeric with `+-.`.
        let scheme_start = rest[..sep]
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.'))
            .map_or(0, |i| i + 1);

        if scheme_start == sep {
            // `://` with no scheme in front of it — not a URL.
            out.push_str(&rest[..sep + 3]);
            rest = &rest[sep + 3..];
            continue;
        }

        out.push_str(&rest[..scheme_start]);

        let candidate = &rest[scheme_start..];
        let end = candidate
            .find(|c: char| c.is_whitespace() || URL_TERMINATORS.contains(&c))
            .unwrap_or(candidate.len());

        out.push_str(&redact_url(&candidate[..end]));
        rest = &candidate[end..];
    }

    out.push_str(rest);
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
    fn keeps_safe_query_params() {
        assert_eq!(
            redact_url("https://v.vault.azure.net/secrets/s?api-version=7.4&code=SEKRIT"),
            "https://v.vault.azure.net/secrets/s?api-version=7.4&code=<redacted>"
        );
    }

    #[test]
    fn safe_query_param_match_is_case_insensitive() {
        assert_eq!(
            redact_url("https://h/p?API-Version=7.4"),
            "https://h/p?API-Version=7.4"
        );
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
    fn redacts_bare_query_token_whole() {
        assert_eq!(redact_url("https://h/p?SEKRIT"), "https://h/p?<redacted>");
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
        assert_eq!(redact_url("https://host"), "https://host");
        assert_eq!(redact_url("https://host?k=v"), "https://host?k=<redacted>");
        assert_eq!(redact_url("https://host#f"), "https://host#<redacted>");
        assert_eq!(redact_url("https://host/"), "https://host/");
    }

    #[test]
    fn empty_query_does_not_emit_question_mark() {
        assert_eq!(redact_url("https://h/p?"), "https://h/p");
    }

    #[test]
    fn empty_parameter_value_is_left_alone() {
        assert_eq!(
            redact_url("https://h/p?a=&b=SEKRIT"),
            "https://h/p?a=&b=<redacted>"
        );
    }

    #[test]
    fn fails_closed_on_non_url_input() {
        assert_eq!(redact_url(""), REDACTED);
        assert_eq!(redact_url("not a url"), REDACTED);
        assert_eq!(redact_url("/relative/path?sig=SEKRIT"), REDACTED);
    }

    #[test]
    fn leaves_placeholders_readable() {
        assert_eq!(
            redact_url("https://{kv_host}/secrets/{name}?api-version=7.4"),
            "https://{kv_host}/secrets/{name}?api-version=7.4"
        );
    }

    #[test]
    fn redacts_url_embedded_in_error_text() {
        let scrubbed = redact_urls_in(
            "error sending request for url (https://h/p?sig=SEKRIT): connection closed",
        );
        assert_eq!(
            scrubbed,
            "error sending request for url (https://h/p?sig=<redacted>): connection closed"
        );
        assert!(!scrubbed.contains("SEKRIT"));
    }

    #[test]
    fn redacts_every_url_in_text() {
        let scrubbed = redact_urls_in("from https://a/x?k=S1 to https://b/y?k=S2 failed");
        assert!(!scrubbed.contains("S1"));
        assert!(!scrubbed.contains("S2"));
        assert_eq!(
            scrubbed,
            "from https://a/x?k=<redacted> to https://b/y?k=<redacted> failed"
        );
    }

    #[test]
    fn leaves_text_without_urls_untouched() {
        assert_eq!(redact_urls_in("plain error, no url"), "plain error, no url");
        assert_eq!(redact_urls_in(""), "");
    }

    #[test]
    fn tolerates_bare_scheme_separator() {
        assert_eq!(redact_urls_in("weird :// text"), "weird :// text");
    }

    #[test]
    fn redaction_is_idempotent() {
        let once = redact_url("https://h/p?sig=SEKRIT");
        assert_eq!(redact_url(&once), once);
        let once_in_text = redact_urls_in("url (https://h/p?sig=SEKRIT)");
        assert_eq!(redact_urls_in(&once_in_text), once_in_text);
    }
}
