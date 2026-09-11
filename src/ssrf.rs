// Copyright (c) Microsoft Corporation.
// Licensed under the PostgreSQL License.

//! SSRF protection for df.http() — dataplane IP blocklist + endpoint allow-list
//!
//! Three Cargo features control outbound HTTP access (from most to least
//! restrictive):
//!
//! | Feature | Behaviour |
//! |---------|-----------|
//! | *(none)* | **All** outbound HTTP is blocked — at DSL time and at execution time. |
//! | `http-allow-azure-domains` | SSRF IP blocklist active, bare IPs blocked, redirects blocked, GUC allow-list defaults to Azure suffixes plus `api.github.com`. |
//! | `http-allow-test-domains` | Same as `http-allow-azure-domains`, defaulting to **also** allow `httpbingo.org`. Implies `http-allow-azure-domains`. |
//! | `http-allow-all` | All SSRF protections disabled — any URL is allowed (development only). |
//!
//! `pg_durable.http_allowed_domains` replaces the restricted builds' domain
//! allow-list at server startup. It cannot disable the hardcoded IP blocklist
//! or override the HTTP feature gates. See docs/http-security.md for details.
//!
//! Every check that inspects a URL runs on the [`Url`] produced by
//! [`parse_request_url`], and that same value is handed to reqwest.  A second,
//! independent parser would reintroduce the differential described there.

use reqwest::Url;
use std::ffi::CStr;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

// ---------------------------------------------------------------------------
// Endpoint allow-list configuration
// ---------------------------------------------------------------------------

/// Returns `true` when *any* HTTP feature is enabled (azure, test, or all).
pub const fn http_enabled() -> bool {
    cfg!(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all"
    ))
}

// Keep the production and test defaults sourced from the same list.
macro_rules! azure_domain_defaults {
    ($extra:literal) => {
        concat!(
            "*.blob.core.windows.net,",
            "*.blob.storage.azure.net,",
            "*.queue.core.windows.net,",
            "*.table.core.windows.net,",
            "*.file.core.windows.net,",
            "*.azurewebsites.net,",
            "*.azure-api.net,",
            "*.documents.azure.com,",
            "*.servicebus.windows.net,",
            "*.openai.azure.com,",
            "*.cognitiveservices.azure.com,",
            "*.vault.azure.net,",
            "*.redis.cache.windows.net,",
            "*.database.windows.net,",
            "*.kusto.windows.net,",
            "*.azurefd.net,",
            "*.azureedge.net,",
            "*.azure-devices.net,",
            "*.trafficmanager.net,",
            "*.cloudapp.azure.com,",
            "api.github.com",
            $extra,
            "\0"
        )
        .as_bytes()
    };
}

pub(crate) const DEFAULT_HTTP_ALLOWED_DOMAINS: &CStr =
    match CStr::from_bytes_with_nul(if cfg!(feature = "http-allow-test-domains") {
        azure_domain_defaults!(",httpbingo.org")
    } else if cfg!(feature = "http-allow-azure-domains") {
        azure_domain_defaults!("")
    } else {
        b"\0"
    }) {
        Ok(value) => value,
        Err(_) => panic!("HTTP domain defaults must form a C string"),
    };

/// An immutable, canonically parsed hostname policy. Empty means deny all.
#[derive(Debug, Default)]
pub struct DomainAllowlist {
    exact_domains: Vec<String>,
    domain_suffixes: Vec<String>,
}

impl DomainAllowlist {
    pub fn parse(value: &str) -> Result<Self, String> {
        let mut allowlist = Self::default();
        if value.trim().is_empty() {
            return Ok(allowlist);
        }

        for (index, entry) in value.split(',').enumerate() {
            let entry = entry.trim();
            let invalid = |reason: &str| format!("entry {} ({entry:?}): {reason}", index + 1);
            let subdomains = entry.strip_prefix("*.");
            let domain = subdomains.unwrap_or(entry);
            if domain.contains('%') {
                return Err(invalid("percent-encoded hostnames are not permitted"));
            }

            let host = match url::Host::parse(domain)
                .map_err(|_| invalid("expected a hostname or *.hostname"))?
            {
                url::Host::Domain(host) => host,
                url::Host::Ipv4(_) | url::Host::Ipv6(_) => {
                    return Err(invalid("IP addresses are not permitted"));
                }
            };

            if host.len() > 253
                || host.split('.').any(|label| {
                    label.is_empty()
                        || label.len() > 63
                        || label.starts_with('-')
                        || label.ends_with('-')
                        || !label
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                })
            {
                return Err(invalid("expected a DNS hostname without a trailing dot"));
            }

            if subdomains.is_some() {
                allowlist.domain_suffixes.push(format!(".{host}"));
            } else {
                allowlist.exact_domains.push(host);
            }
        }
        Ok(allowlist)
    }

    fn validate(&self, url: &Url) -> Result<(), String> {
        // WHATWG canonicalises decimal, octal and IPv4-mapped forms into IP
        // variants. They must not bypass the resolver's IP protection.
        let host = match url.host() {
            Some(url::Host::Domain(domain)) => domain,
            Some(url::Host::Ipv4(_)) | Some(url::Host::Ipv6(_)) => {
                return Err("Blocked: requests to bare IP addresses are not permitted. \
                     Use an approved service hostname instead."
                    .to_string());
            }
            None => return Err("Blocked: unable to extract hostname from URL.".to_string()),
        };

        if self.exact_domains.iter().any(|domain| host == domain)
            || self
                .domain_suffixes
                .iter()
                .any(|suffix| host.len() > suffix.len() && host.ends_with(suffix))
        {
            return Ok(());
        }

        Err(format!(
            "Blocked: '{host}' is not in the allowed endpoint list. \
             Configure pg_durable.http_allowed_domains to allow this hostname."
        ))
    }
}

impl TryFrom<&CStr> for DomainAllowlist {
    type Error = String;

    fn try_from(value: &CStr) -> Result<Self, Self::Error> {
        Self::parse(value.to_str().map_err(|_| {
            "value must be valid UTF-8; ASCII/punycode hostnames are always supported".to_string()
        })?)
    }
}

#[pgrx::pg_guard]
pub(crate) unsafe extern "C-unwind" fn check_http_allowed_domains(
    newval: *mut *mut std::ffi::c_char,
    _extra: *mut *mut std::ffi::c_void,
    _source: pgrx::pg_sys::GucSource::Type,
) -> bool {
    let result = if unsafe { (*newval).is_null() } {
        Err("value must not be NULL".to_string())
    } else {
        DomainAllowlist::try_from(unsafe { CStr::from_ptr(*newval) })
    };
    match result {
        Ok(_) => true,
        Err(error) => {
            // During preload, PostgreSQL otherwise only warns and restores the
            // default when rejecting a placeholder, potentially widening policy.
            if unsafe { pgrx::pg_sys::process_shared_preload_libraries_in_progress } {
                pgrx::error!(
                    "invalid value for parameter \"pg_durable.http_allowed_domains\": {error}"
                );
            }
            unsafe {
                pgrx::pg_sys::GUC_check_errdetail_string =
                    pgrx::PgMemoryContexts::ErrorContext.pstrdup(&error);
            }
            false
        }
    }
}

// ---------------------------------------------------------------------------
// IP blocklist
// ---------------------------------------------------------------------------
/// Returns `Some(reason)` if blocked, `None` if allowed.
///
/// When compiled with the `http-allow-all` feature, always returns `None`.
pub fn check_blocked_ip(ip: IpAddr) -> Option<&'static str> {
    // Handle IPv4-mapped IPv6 (::ffff:A.B.C.D) — extract the embedded IPv4
    let ip = match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(v6),
        },
        other => other,
    };

    match ip {
        IpAddr::V4(v4) => check_blocked_ipv4(v4),
        IpAddr::V6(v6) => check_blocked_ipv6(v6),
    }
}

fn check_blocked_ipv4(ip: Ipv4Addr) -> Option<&'static str> {
    #[cfg(feature = "http-allow-all")]
    {
        let _ = ip;
        None
    }
    #[cfg(not(feature = "http-allow-all"))]
    {
        let octets = ip.octets();
        match octets {
            [0, ..] => Some("reserved (0.0.0.0/8)"),
            [10, ..] => Some("private (10.0.0.0/8)"),
            [100, b, ..] if (64..=127).contains(&b) => Some("shared/CGNAT (100.64.0.0/10)"),
            [127, ..] => Some("loopback (127.0.0.0/8)"),
            [169, 254, ..] => Some("link-local (169.254.0.0/16)"),
            [172, b, ..] if (16..=31).contains(&b) => Some("private (172.16.0.0/12)"),
            [192, 168, ..] => Some("private (192.168.0.0/16)"),
            _ => None,
        }
    }
}

fn check_blocked_ipv6(ip: Ipv6Addr) -> Option<&'static str> {
    #[cfg(feature = "http-allow-all")]
    {
        let _ = ip;
        None
    }
    #[cfg(not(feature = "http-allow-all"))]
    {
        if ip.is_unspecified() {
            return Some("unspecified (::)");
        }
        if ip.is_loopback() {
            return Some("loopback (::1)");
        }
        let segments = ip.segments();
        // fe80::/10 — IPv6 link-local
        if segments[0] & 0xffc0 == 0xfe80 {
            return Some("link-local (fe80::/10)");
        }
        // fc00::/7 — IPv6 unique local address
        if segments[0] & 0xfe00 == 0xfc00 {
            return Some("unique local (fc00::/7)");
        }
        None
    }
}

/// DSL-time scheme pre-check, so `df.http('file:///etc/passwd')` fails at
/// definition time instead of at execution time.
///
/// This is advisory only — it runs on a raw string that may still contain
/// unsubstituted variables. [`validate_scheme`] is the enforcing check.
pub fn precheck_url_scheme(url: &str) -> Result<(), String> {
    let scheme = url.split("://").next().unwrap_or("").to_ascii_lowercase();
    validate_scheme_value(&scheme)
}

fn validate_scheme_value(scheme: &str) -> Result<(), String> {
    let allows_plaintext = cfg!(feature = "http-allow-all")
        || !cfg!(any(
            feature = "http-allow-azure-domains",
            feature = "http-allow-test-domains"
        ));

    match scheme {
        "https" => Ok(()),
        "http" if allows_plaintext => Ok(()),
        "http" => Err(
            "Blocked: plaintext HTTP is not permitted in restricted builds. HTTPS is required."
                .to_string(),
        ),
        _ => {
            let allowed = if allows_plaintext {
                "http and https"
            } else {
                "https"
            };
            Err(format!(
                "Blocked: unsupported URL scheme. Only {allowed} is allowed."
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Canonical URL parsing
// ---------------------------------------------------------------------------

/// Parse `url` into the exact value that will be handed to reqwest.
///
/// Callers must validate *this* value and then send *this* value. Validating
/// the raw string with a second parser opens a parser differential: WHATWG
/// treats `\` as a path separator for http(s), so in
/// `https://evil.example\@acct.blob.core.windows.net/` the authority is
/// `evil.example` and the rest is path — while a hand-rolled authority scan
/// reads the trailing allow-listed name and approves the request.
pub fn parse_request_url(url: &str) -> Result<Url, String> {
    Url::parse(url).map_err(|e| format!("Blocked: malformed URL ({e})."))
}

/// Validate the scheme of a canonically parsed URL against the build's
/// outbound HTTP policy.
pub fn validate_scheme(url: &Url) -> Result<(), String> {
    validate_scheme_value(url.scheme())
}

// ---------------------------------------------------------------------------
// Endpoint allow-list validation
// ---------------------------------------------------------------------------

/// Validate a canonically parsed URL against the endpoint allow-list.
///
/// Takes the parsed [`Url`] rather than a string so the host checked here is
/// the host reqwest will connect to.
///
/// Behaviour depends on Cargo features (most to least restrictive):
///
/// * *(none)* — all requests blocked, regardless of domain.
/// * `http-allow-azure-domains` / `http-allow-test-domains` — bare IPs blocked;
///   the worker's `pg_durable.http_allowed_domains` snapshot is enforced.
/// * `http-allow-all` — allow-list check is skipped entirely; all domains pass.
pub fn validate_allowlist(url: &Url, allowlist: &DomainAllowlist) -> Result<(), String> {
    if cfg!(feature = "http-allow-all") {
        return Ok(());
    }
    if !http_enabled() {
        return Err("Blocked: outbound HTTP requests are disabled. \
             Rebuild with the 'http-allow-azure-domains' Cargo feature to enable them."
            .to_string());
    }
    allowlist.validate(url)
}

// Keep this marker in sync with the error message in SsrfSafeResolver::resolve().
const SSRF_BLOCK_MARKER: &str = "Blocked:";
const SSRF_RESTRICTED_MARKER: &str = "restricted";

/// Returns `true` if `err_msg` looks like an SSRF IP-blocklist rejection
/// produced by [`SsrfSafeResolver`].  Both marker strings are defined here,
/// next to the resolver that emits them, so changes stay in sync.
pub fn is_ssrf_block_error(err_msg: &str) -> bool {
    err_msg.contains(SSRF_BLOCK_MARKER) && err_msg.contains(SSRF_RESTRICTED_MARKER)
}

// ---------------------------------------------------------------------------
// SSRF-safe DNS resolver — wraps the default resolver and filters out blocked IPs
// ---------------------------------------------------------------------------

mod resolver {
    use super::check_blocked_ip;
    use reqwest::dns::{Addrs, Name, Resolve, Resolving};
    use std::sync::Arc;

    /// A DNS resolver wrapper that filters blocked IPs from resolution results.
    /// This ensures the blocklist check and the connection use the same address,
    /// preventing DNS rebinding attacks.
    pub struct SsrfSafeResolver {
        inner: Arc<dyn Resolve>,
    }

    impl SsrfSafeResolver {
        pub fn wrapping(inner: Arc<dyn Resolve>) -> Self {
            Self { inner }
        }
    }

    impl Resolve for SsrfSafeResolver {
        fn resolve(&self, name: Name) -> Resolving {
            let hostname = name.as_str().to_owned();
            let inner_future = self.inner.resolve(name);
            Box::pin(async move {
                let addrs = inner_future.await?;
                let filtered: Vec<std::net::SocketAddr> = addrs
                    .filter(|addr| check_blocked_ip(addr.ip()).is_none())
                    .collect();
                if filtered.is_empty() {
                    return Err(format!(
                        "Blocked: the resolved IP address for '{hostname}' is in a restricted \
                         range. df.http() cannot access private or internal network addresses."
                    )
                    .into());
                }
                Ok(Box::new(filtered.into_iter()) as Addrs)
            })
        }
    }
}

pub use resolver::SsrfSafeResolver;

// ---------------------------------------------------------------------------
// Default (system) DNS resolver — needed as the "inner" for SsrfSafeResolver
// ---------------------------------------------------------------------------

mod system_resolver {
    use reqwest::dns::{Addrs, Name, Resolve, Resolving};
    use std::net::ToSocketAddrs;

    /// Simple blocking DNS resolver that delegates to the OS via `ToSocketAddrs`.
    pub struct SystemResolver;

    impl Resolve for SystemResolver {
        fn resolve(&self, name: Name) -> Resolving {
            let host = name.as_str().to_owned();
            Box::pin(async move {
                let host_port = format!("{host}:0");
                let addrs: Vec<std::net::SocketAddr> =
                    tokio::task::spawn_blocking(move || host_port.to_socket_addrs())
                        .await
                        .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { Box::new(e) })?
                        .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { Box::new(e) })?
                        .collect();
                Ok(Box::new(addrs.into_iter()) as Addrs)
            })
        }
    }
}

pub use system_resolver::SystemResolver;

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    // --- IPv4 blocked ranges ---
    // Under http-allow-all the blocklist is disabled; these tests only run without it.

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_loopback() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(127, 255, 255, 255))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_rfc1918_10() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(10, 255, 255, 255))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_rfc1918_172() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 16, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 31, 255, 255))).is_some());
        // Edge: 172.15.x.x is NOT private
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 15, 255, 255))).is_none());
        // Edge: 172.32.x.x is NOT private
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 32, 0, 0))).is_none());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_rfc1918_192_168() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 255, 255))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_link_local() {
        // Cloud metadata endpoint
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 169, 254))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 255, 255))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_this_network() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(0, 255, 255, 255))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_cgnat_rfc6598() {
        // 100.64.0.0/10 — Carrier-Grade NAT (RFC 6598)
        // Used by cloud providers for internal routing / metadata
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 100, 100, 100))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 127, 255, 255))).is_some());
        // Edge: 100.63.x.x is NOT CGNAT
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 63, 255, 255))).is_none());
        // Edge: 100.128.x.x is NOT CGNAT
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(100, 128, 0, 0))).is_none());
    }

    // --- IPv4 allowed (public) ---

    #[test]
    fn allows_public_ipv4() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))).is_none());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(93, 184, 216, 34))).is_none());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))).is_none());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1))).is_none());
    }

    // --- IPv6 blocked ranges ---
    // Under http-allow-all the blocklist is disabled; these tests only run without it.

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv6_loopback() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::LOCALHOST)).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv6_unspecified() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::UNSPECIFIED)).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv6_link_local() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1))).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv6_ula() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::new(0xfc00, 0, 0, 0, 0, 0, 0, 1))).is_some());
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 1))).is_some());
    }

    // --- IPv6 allowed (public) ---

    #[test]
    fn allows_public_ipv6() {
        // Google DNS
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::new(
            0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888
        )))
        .is_none());
    }

    // --- IPv4-mapped IPv6 ---
    // Under http-allow-all the blocklist is disabled; these tests only run without it.

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv4_mapped_ipv6_loopback() {
        // ::ffff:127.0.0.1
        let ip: IpAddr = "::ffff:127.0.0.1".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv4_mapped_ipv6_link_local() {
        // ::ffff:169.254.169.254 (cloud metadata)
        let ip: IpAddr = "::ffff:169.254.169.254".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn blocks_ipv4_mapped_ipv6_private() {
        let ip: IpAddr = "::ffff:10.0.0.1".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
        let ip: IpAddr = "::ffff:192.168.1.1".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
        let ip: IpAddr = "::ffff:172.16.0.1".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
    }

    #[test]
    fn allows_ipv4_mapped_ipv6_public() {
        // ::ffff:93.184.216.34
        let ip: IpAddr = "::ffff:93.184.216.34".parse().unwrap();
        assert!(check_blocked_ip(ip).is_none());
    }

    // --- URL scheme validation ---

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn restricted_builds_require_https() {
        assert!(precheck_url_scheme("https://example.com").is_ok());
        assert!(precheck_url_scheme("HTTPS://example.com").is_ok());
        assert!(precheck_url_scheme("http://example.com")
            .unwrap_err()
            .contains("HTTPS is required"));
        assert!(precheck_url_scheme("HTTP://EXAMPLE.COM")
            .unwrap_err()
            .contains("HTTPS is required"));
        assert!(validate_scheme(&parse_request_url("https://example.com").unwrap()).is_ok());
        assert!(
            validate_scheme(&parse_request_url("http://example.com").unwrap())
                .unwrap_err()
                .contains("HTTPS is required")
        );
    }

    #[cfg(feature = "http-allow-all")]
    #[test]
    fn allow_all_builds_accept_http_and_https() {
        assert!(precheck_url_scheme("http://example.com").is_ok());
        assert!(precheck_url_scheme("https://example.com").is_ok());
        assert!(precheck_url_scheme("HTTP://EXAMPLE.COM").is_ok());
        assert!(precheck_url_scheme("HTTPS://example.com").is_ok());
        assert!(validate_scheme(&parse_request_url("http://example.com").unwrap()).is_ok());
        assert!(validate_scheme(&parse_request_url("HTTPS://example.com").unwrap()).is_ok());
    }

    #[cfg(not(any(
        feature = "http-allow-all",
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    )))]
    #[test]
    fn disabled_builds_defer_http_rejection_to_feature_policy() {
        assert!(precheck_url_scheme("http://example.com").is_ok());
        assert!(precheck_url_scheme("https://example.com").is_ok());
    }

    #[test]
    fn blocks_file_scheme() {
        assert!(precheck_url_scheme("file:///etc/passwd").is_err());
        assert!(validate_scheme(&parse_request_url("file:///etc/passwd").unwrap()).is_err());
    }

    #[test]
    fn blocks_ftp_scheme() {
        assert!(precheck_url_scheme("ftp://ftp.example.com").is_err());
        assert!(validate_scheme(&parse_request_url("ftp://ftp.example.com").unwrap()).is_err());
    }

    #[test]
    fn blocks_gopher_scheme() {
        assert!(precheck_url_scheme("gopher://evil.com").is_err());
        assert!(validate_scheme(&parse_request_url("gopher://evil.com").unwrap()).is_err());
    }

    #[test]
    fn blocks_empty_and_malformed() {
        assert!(precheck_url_scheme("").is_err());
        assert!(precheck_url_scheme("no-scheme").is_err());
    }

    #[test]
    fn malformed_scheme_errors_do_not_echo_credentials() {
        for url in ["https:/h/p?sig=query_token", "invalid?sig=query_token://h"] {
            let error = precheck_url_scheme(url).unwrap_err();
            assert!(error.contains("unsupported URL scheme"), "{error}");
            assert!(!error.contains("query_token"), "{error}");
        }
    }

    // --- Canonical URL parsing ---

    // Exercise domain matching independently of feature gates; their precedence
    // is covered separately with both custom and empty lists.
    fn validate_url_allowlist(url: &str) -> Result<(), String> {
        DomainAllowlist::try_from(DEFAULT_HTTP_ALLOWED_DOMAINS)?.validate(&parse_request_url(url)?)
    }

    #[test]
    fn parse_request_url_canonicalises_authority() {
        let u = parse_request_url("http://user:pass@Host:8080/p").unwrap();
        assert_eq!(u.host_str(), Some("host"));
        assert_eq!(u.port(), Some(8080));
        assert_eq!(
            parse_request_url("https://myaccount.blob.core.windows.net?comp=list")
                .unwrap()
                .host_str(),
            Some("myaccount.blob.core.windows.net")
        );
    }

    #[test]
    fn parse_request_url_treats_backslash_as_path_separator() {
        // The authority ends at the backslash, so the '@' and everything after
        // it are path — this is the differential the allow-list must not see.
        let u = parse_request_url(r"https://evil.example\@api.github.com/repos").unwrap();
        assert_eq!(u.host_str(), Some("evil.example"));
        assert_eq!(u.path(), "/@api.github.com/repos");
    }

    #[test]
    fn parse_request_url_rejects_malformed() {
        assert!(parse_request_url("no-scheme").is_err());
        assert!(parse_request_url("").is_err());
    }

    // --- Endpoint allow-list validation ---

    #[test]
    fn allowlist_defaults_match_build() {
        assert_eq!(
            validate_url_allowlist("https://api.github.com/").is_ok(),
            cfg!(feature = "http-allow-azure-domains")
        );
        assert_eq!(
            validate_url_allowlist("https://account.blob.core.windows.net/").is_ok(),
            cfg!(feature = "http-allow-azure-domains")
        );
        assert_eq!(
            validate_url_allowlist("https://httpbingo.org/").is_ok(),
            cfg!(feature = "http-allow-test-domains")
        );
    }

    #[test]
    fn configured_allowlist_matches_exact_names_and_subdomain_boundaries() {
        let allowlist = DomainAllowlist::parse(" API.GitHub.COM ,\n *.Example.COM \t").unwrap();
        for url in [
            "https://api.github.com/",
            "https://API.GITHUB.COM/",
            "https://a.example.com/",
            "https://a.b.c.example.com:8443/",
            "https://a%2Eexample%2Ecom/",
        ] {
            assert!(
                allowlist.validate(&parse_request_url(url).unwrap()).is_ok(),
                "{url}"
            );
        }
        for url in [
            "https://github.com/",
            "https://evil.api.github.com/",
            "https://evilapi.github.com/",
            "https://example.com/",
            "https://.example.com/",
            "https://a.example.com.evil.net/",
            "https://api.github.com./",
            "https://a.example.com./",
            "https://evil.net?@a.example.com/",
            r"https://evil.net\@a.example.com/",
            "https://8.8.8.8/",
            "https://[2001:4860:4860::8888]/",
        ] {
            assert!(
                parse_request_url(url)
                    .and_then(|url| allowlist.validate(&url))
                    .is_err(),
                "{url}"
            );
        }
    }

    #[test]
    fn configured_allowlist_replaces_all_default_domains() {
        let allowlist = DomainAllowlist::parse("example.com").unwrap();
        assert!(allowlist
            .validate(&parse_request_url("https://example.com/").unwrap())
            .is_ok());
        for url in [
            "https://api.github.com/",
            "https://httpbingo.org/",
            "https://account.blob.core.windows.net/",
        ] {
            let error = allowlist
                .validate(&parse_request_url(url).unwrap())
                .unwrap_err();
            assert!(error.contains("pg_durable.http_allowed_domains"), "{error}");
        }
    }

    #[test]
    fn configured_allowlist_normalizes_idna_without_homograph_matches() {
        let allowlist =
            DomainAllowlist::parse("B\u{dc}CHER.example, *.ma\u{f1}ana.example").unwrap();
        for url in [
            "https://b\u{fc}cher.example/",
            "https://xn--bcher-kva.example/",
            "https://a.b.ma\u{f1}ana.example/",
            "https://a.xn--maana-pta.example/",
        ] {
            assert!(
                allowlist.validate(&parse_request_url(url).unwrap()).is_ok(),
                "{url}"
            );
        }
        for url in [
            "https://bucher.example/",
            "https://a.manana.example/",
            "https://ma\u{f1}ana.example/",
            "https://xn--bcher-kva.example./",
        ] {
            assert!(
                allowlist
                    .validate(&parse_request_url(url).unwrap())
                    .is_err(),
                "{url}"
            );
        }
    }

    #[test]
    fn empty_configured_allowlist_denies_all_domains() {
        for value in ["", " \t\r\n "] {
            let allowlist = DomainAllowlist::parse(value).unwrap();
            for url in [
                "https://api.github.com/",
                "https://httpbingo.org/",
                "https://account.blob.core.windows.net/",
            ] {
                assert!(allowlist
                    .validate(&parse_request_url(url).unwrap())
                    .is_err());
            }
        }
    }

    #[test]
    fn malformed_domain_configuration_is_rejected_as_a_whole() {
        for value in [
            ",",
            ",example.com",
            "example.com,",
            "example.com,,example.net",
            "*",
            "*.",
            "**.example.com",
            "api.*.example.com",
            ".example.com",
            "example.com.",
            "example..com",
            "-api.example.com",
            "api-.example.com",
            "api_example.com",
            "https://example.com",
            "example.com:443",
            "example.com/path",
            "user@example.com",
            "example.com?query",
            "example.com#fragment",
            r"example.com\path",
            "\"example.com\"",
            "'example.com'",
            "exa mple.com",
            "example%2ecom",
            "8.8.8.8",
            "0x7f.1",
            "2130706433",
            "[::1]",
            "::ffff:127.0.0.1",
            "*.127.0.0.1",
            "10.0.0.0/8",
        ] {
            let error = DomainAllowlist::parse(value).unwrap_err();
            assert!(error.contains("entry "), "{value:?}: {error}");
        }
        let error = DomainAllowlist::parse("example.com, https://example.net").unwrap_err();
        assert!(error.contains("entry 2"), "{error}");
    }

    #[test]
    fn configured_allowlist_enforces_dns_lengths_not_sql_identifier_lengths() {
        let long_hostname = format!(
            "{}.{}.{}.{}",
            "a".repeat(63),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(61)
        );
        let allowlist = DomainAllowlist::parse(&long_hostname).unwrap();
        assert!(allowlist
            .validate(&parse_request_url(&format!("https://{long_hostname}/")).unwrap())
            .is_ok());
        assert!(DomainAllowlist::parse(&format!("{long_hostname}d")).is_err());
        assert!(DomainAllowlist::parse(&format!("{}.example.com", "a".repeat(64))).is_err());
    }

    #[test]
    fn configured_allowlist_rejects_non_utf8_without_lossy_conversion() {
        let value = c"\xff.example";
        assert!(DomainAllowlist::try_from(value)
            .unwrap_err()
            .contains("UTF-8"));
    }

    #[test]
    fn http_feature_gates_take_precedence_over_configured_domains() {
        let allowed = parse_request_url("https://example.com/").unwrap();
        let unlisted = parse_request_url("https://example.net/").unwrap();
        let ip = parse_request_url("https://8.8.8.8/").unwrap();
        let custom = DomainAllowlist::parse("example.com").unwrap();
        let empty = DomainAllowlist::parse("").unwrap();
        if cfg!(feature = "http-allow-all") {
            for allowlist in [&custom, &empty] {
                for url in [&allowed, &unlisted, &ip] {
                    assert!(validate_allowlist(url, allowlist).is_ok());
                }
            }
        } else if http_enabled() {
            assert!(validate_allowlist(&allowed, &custom).is_ok());
            assert!(validate_allowlist(&unlisted, &custom).is_err());
            assert!(validate_allowlist(&ip, &custom).is_err());
            assert!(validate_allowlist(&allowed, &empty).is_err());
        } else {
            for allowlist in [&custom, &empty] {
                assert!(validate_allowlist(&allowed, allowlist)
                    .unwrap_err()
                    .contains("outbound HTTP requests are disabled"));
            }
        }
    }

    // These "blocks_*" tests are only meaningful when some http feature is
    // enabled (otherwise the no-feature path blocks everything anyway).
    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_bare_ipv4() {
        assert!(validate_url_allowlist("http://8.8.8.8/path").is_err());
        assert!(validate_url_allowlist("https://93.184.216.34/page").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_bare_ipv6() {
        assert!(validate_url_allowlist("http://[2001:4860:4860::8888]/dns").is_err());
        assert!(validate_url_allowlist("http://[::1]/path").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_private_ips() {
        assert!(validate_url_allowlist("http://127.0.0.1/path").is_err());
        assert!(validate_url_allowlist("http://169.254.169.254/meta").is_err());
        assert!(validate_url_allowlist("http://10.0.0.1/admin").is_err());
    }

    // Non-Azure domains blocked when only azure-domains (not test-domains) is enabled.
    #[cfg(all(
        feature = "http-allow-azure-domains",
        not(feature = "http-allow-test-domains"),
        not(feature = "http-allow-all"),
    ))]
    #[test]
    fn allowlist_blocks_non_azure_domains() {
        assert!(validate_url_allowlist("https://example.com/path").is_err());
        assert!(validate_url_allowlist("https://httpbingo.org/get").is_err());
        assert!(validate_url_allowlist("https://evil.com/steal").is_err());
        assert!(validate_url_allowlist("https://management.azure.com/sub").is_err());
    }

    // api.github.com is allowed in the azure-domains tier (and above).
    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_allows_api_github_com() {
        assert!(validate_url_allowlist("https://api.github.com/repos").is_ok());
        assert!(validate_url_allowlist("https://API.GITHUB.COM/repos").is_ok());
        // Exact match only — subdomains and lookalikes stay blocked.
        assert!(validate_url_allowlist("https://evil.api.github.com/repos").is_err());
        assert!(validate_url_allowlist("https://api.github.com.evil.com/repos").is_err());
        assert!(validate_url_allowlist("https://github.com/repos").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_apex_domains() {
        // Apex domains (exact suffix without subdomain) must be rejected
        assert!(validate_url_allowlist("https://blob.core.windows.net/test").is_err());
        assert!(validate_url_allowlist("https://azurewebsites.net/app").is_err());
        assert!(validate_url_allowlist("https://vault.azure.net/secrets").is_err());
        assert!(validate_url_allowlist("https://openai.azure.com/api").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_allows_azure_blob_storage() {
        assert!(
            validate_url_allowlist("https://myaccount.blob.core.windows.net/container/blob")
                .is_ok()
        );
        assert!(validate_url_allowlist("https://myaccount.z1.blob.storage.azure.net/c").is_ok());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_allows_azure_services() {
        assert!(validate_url_allowlist("https://myqueue.queue.core.windows.net/q").is_ok());
        assert!(validate_url_allowlist("https://mytable.table.core.windows.net/t").is_ok());
        assert!(validate_url_allowlist("https://myshare.file.core.windows.net/s").is_ok());
        assert!(validate_url_allowlist("https://myapp.azurewebsites.net/api").is_ok());
        assert!(validate_url_allowlist("https://myapi.azure-api.net/v1").is_ok());
        assert!(validate_url_allowlist("https://mydb.documents.azure.com/dbs").is_ok());
        assert!(validate_url_allowlist("https://mybus.servicebus.windows.net/topic").is_ok());
        assert!(validate_url_allowlist("https://myoai.openai.azure.com/v1/chat").is_ok());
        assert!(validate_url_allowlist("https://mycog.cognitiveservices.azure.com/v1").is_ok());
        assert!(validate_url_allowlist("https://myvault.vault.azure.net/secrets/s").is_ok());
        assert!(validate_url_allowlist("https://myredis.redis.cache.windows.net/").is_ok());
        assert!(validate_url_allowlist("https://mydb.database.windows.net/db").is_ok());
        assert!(validate_url_allowlist("https://mycluster.kusto.windows.net/q").is_ok());
        assert!(validate_url_allowlist("https://myfd.azurefd.net/path").is_ok());
        assert!(validate_url_allowlist("https://mycdn.azureedge.net/asset").is_ok());
        assert!(validate_url_allowlist("https://myhub.azure-devices.net/d").is_ok());
        assert!(validate_url_allowlist("https://myapp.trafficmanager.net/h").is_ok());
        assert!(validate_url_allowlist("https://myapp.cloudapp.azure.com/api").is_ok());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_allows_deep_subdomains() {
        // Multiple subdomain labels should still match
        assert!(validate_url_allowlist("https://a.b.c.blob.core.windows.net/x").is_ok());
        assert!(validate_url_allowlist("https://my.app.region.azurewebsites.net/").is_ok());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_case_insensitive() {
        assert!(validate_url_allowlist("https://MY.BLOB.CORE.WINDOWS.NET/c").is_ok());
        assert!(validate_url_allowlist("https://MyVault.Vault.Azure.Net/s").is_ok());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_suffix_lookalikes() {
        // Domains that contain the suffix but as part of a different TLD
        assert!(validate_url_allowlist("https://blob.core.windows.net.evil.com/x").is_err());
        assert!(
            validate_url_allowlist("https://evil-blob.core.windows.net.attacker.io/x").is_err()
        );
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_malformed_urls() {
        assert!(validate_url_allowlist("").is_err());
        assert!(validate_url_allowlist("not-a-url").is_err());
    }

    // --- Parser-differential attack vectors (Finding 11 regression tests) ---

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_follows_percent_decoded_host() {
        // %2E is a percent-encoded '.'. WHATWG decodes it during host parsing,
        // so the request really does go to the allow-listed host and the verdict must
        // match that — the allow-list judges the host reqwest will connect to,
        // never the spelling the caller used.
        assert!(validate_url_allowlist("https://foo%2Eblob%2Ecore%2Ewindows%2Enet/c").is_ok());
        assert!(validate_url_allowlist("https://evil%2Ecom/steal").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_unicode_homograph_suffix() {
        // IDN homograph attack: the suffix portion contains a Unicode lookalike
        // (e.g. Cyrillic 'о' \u{043E} in place of ASCII 'o').  ends_with() does
        // byte comparison so the non-ASCII bytes never match the ASCII suffix.
        assert!(validate_url_allowlist(
            "https://evil.\u{0431}l\u{043E}\u{0431}.c\u{043E}re.wind\u{043E}ws.net/x"
        )
        .is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_trailing_dot_fqdn_is_blocked() {
        // Trailing dot is a valid FQDN terminator but our parser does not strip
        // it, so the suffix check fails (e.g. "net." ≠ "net").  This is
        // fail-safe (blocks rather than allows) and documents current behavior.
        // If Finding 9 is fixed (strip trailing dot), this test must be updated
        // to assert Ok(()) instead.
        assert!(validate_url_allowlist("https://foo.blob.core.windows.net./c").is_err());
    }

    // --- Query/fragment allowlist bypass vectors (Finding 1 regression tests) ---

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_query_bypass() {
        // Attacker tries to smuggle a suffix via '?' so reqwest connects to evil.com
        assert!(validate_url_allowlist("https://evil.com?.blob.core.windows.net/exfil").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_fragment_bypass() {
        assert!(validate_url_allowlist("https://evil.com#.blob.core.windows.net").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_blocks_userinfo_query_bypass() {
        // '@' appears after '?' so it's in the query, not userinfo
        assert!(validate_url_allowlist("https://evil.com?@acct.blob.core.windows.net").is_err());
    }

    #[cfg(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains"
    ))]
    #[test]
    fn allowlist_allows_azure_query_only_url() {
        // Legitimate Azure URL with query but no path slash
        assert!(
            validate_url_allowlist("https://myaccount.blob.core.windows.net?comp=list").is_ok()
        );
    }

    // --- Backslash authority-termination vectors ---
    //
    // WHATWG ends the authority of an http(s) URL at '\', so the allow-listed
    // name after the backslash is path, not host. Any parser that misses this
    // approves a request aimed somewhere else entirely.

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn allowlist_blocks_backslash_userinfo_bypass() {
        assert!(
            validate_url_allowlist(r"https://evil.example\@acct.blob.core.windows.net/c").is_err()
        );
        assert!(
            validate_url_allowlist(r"https://evil.example\@acct.queue.core.windows.net/s").is_err()
        );
        assert!(
            validate_url_allowlist(r"https://evil.example:443\@acct.file.core.windows.net/")
                .is_err()
        );
        // No userinfo marker at all — the whole tail is path.
        assert!(
            validate_url_allowlist(r"https://evil.example\acct.blob.core.windows.net/").is_err()
        );
    }

    // The bare-IP rule is the only gate for IP-literal targets: reqwest skips
    // DNS for them, so SsrfSafeResolver never runs. These must never pass.
    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn allowlist_blocks_backslash_ip_literal_bypass() {
        assert!(validate_url_allowlist(
            r"http://169.254.169.254\@acct.blob.core.windows.net/../metadata/instance"
        )
        .is_err());
        assert!(
            validate_url_allowlist(r"http://127.0.0.1:5432\@acct.queue.core.windows.net/").is_err()
        );
        assert!(validate_url_allowlist(r"http://[::1]\@acct.blob.core.windows.net/").is_err());
    }

    // Bare IPs written in non-dotted notation are canonicalised by WHATWG, so
    // they reach the connector as IP literals and must be caught as such.
    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn allowlist_blocks_non_dotted_ip_notation() {
        assert!(validate_url_allowlist("http://2130706433/").is_err());
        assert!(validate_url_allowlist("http://0x7f.1/").is_err());
    }

    // --- Test domains (only with http-allow-test-domains) ---

    #[cfg(feature = "http-allow-test-domains")]
    #[test]
    fn allowlist_allows_test_domains() {
        assert!(validate_url_allowlist("https://httpbingo.org/get").is_ok());
    }

    #[cfg(feature = "http-allow-test-domains")]
    #[test]
    fn allowlist_still_blocks_arbitrary_domains() {
        assert!(validate_url_allowlist("https://example.com/path").is_err());
        assert!(validate_url_allowlist("https://evil.com/steal").is_err());
    }

    // The exact-match branch is no safer than the suffix branch when the host
    // itself is taken from the wrong parse, so it gets the same coverage.
    #[cfg(feature = "http-allow-test-domains")]
    #[test]
    fn allowlist_blocks_backslash_bypass_of_exact_domains() {
        assert!(validate_url_allowlist(r"https://evil.example\@api.github.com/repos").is_err());
        assert!(validate_url_allowlist(r"https://user\name@api.github.com/repos").is_err());
        assert!(validate_url_allowlist(
            r"http://169.254.169.254\@api.github.com/../metadata/instance"
        )
        .is_err());
    }

    // --- SsrfSafeResolver behavioral tests ---
    //
    // These tests drive the resolver directly with a mock inner resolver so we
    // don't need real DNS.  They cover the DNS-rebinding scenario: a hostname
    // that passes the allowlist but resolves to a private IP at connect-time.

    #[cfg(not(feature = "http-allow-all"))]
    mod resolver_tests {
        use super::super::{is_ssrf_block_error, SsrfSafeResolver};
        use reqwest::dns::{Addrs, Name, Resolve, Resolving};
        use std::net::SocketAddr;
        use std::sync::Arc;

        /// A mock resolver that returns a fixed list of socket addresses.
        struct MockResolver(Vec<SocketAddr>);

        impl Resolve for MockResolver {
            fn resolve(&self, _name: Name) -> Resolving {
                let addrs = self.0.clone();
                Box::pin(async move { Ok(Box::new(addrs.into_iter()) as Addrs) })
            }
        }

        async fn resolve_with(addrs: Vec<SocketAddr>) -> Result<Vec<SocketAddr>, String> {
            let mock = Arc::new(MockResolver(addrs));
            let safe = SsrfSafeResolver::wrapping(mock);
            let name: Name = "rebind.example.com".parse().unwrap();
            use reqwest::dns::Resolve;
            safe.resolve(name)
                .await
                .map(|a| a.collect())
                .map_err(|e| e.to_string())
        }

        /// DNS rebinding: hostname resolves exclusively to a private IP → blocked.
        #[tokio::test]
        async fn resolver_blocks_private_ip() {
            let private: SocketAddr = "10.0.0.1:80".parse().unwrap();
            let result = resolve_with(vec![private]).await;
            assert!(result.is_err(), "expected error, got {result:?}");
            let msg = result.unwrap_err();
            assert!(
                is_ssrf_block_error(&msg),
                "error should be detected as SSRF block: {msg}"
            );
        }

        /// DNS rebinding via link-local (cloud metadata endpoint).
        #[tokio::test]
        async fn resolver_blocks_link_local_ip() {
            let metadata: SocketAddr = "169.254.169.254:80".parse().unwrap();
            let result = resolve_with(vec![metadata]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }

        /// Mixed results: private IP filtered out, public IP passes through.
        #[tokio::test]
        async fn resolver_filters_private_allows_public() {
            let private: SocketAddr = "192.168.1.1:443".parse().unwrap();
            let public: SocketAddr = "93.184.216.34:443".parse().unwrap();
            let result = resolve_with(vec![private, public]).await;
            let addrs = result.expect("should succeed when at least one public IP remains");
            assert_eq!(addrs.len(), 1);
            assert_eq!(addrs[0], public);
        }

        /// Public IP only: resolver passes it through unchanged.
        #[tokio::test]
        async fn resolver_allows_public_ip() {
            let public: SocketAddr = "8.8.8.8:53".parse().unwrap();
            let result = resolve_with(vec![public]).await;
            let addrs = result.expect("public IP should be allowed");
            assert_eq!(addrs.len(), 1);
            assert_eq!(addrs[0], public);
        }

        /// Loopback (127.0.0.1) is blocked.
        #[tokio::test]
        async fn resolver_blocks_loopback() {
            let loopback: SocketAddr = "127.0.0.1:80".parse().unwrap();
            let result = resolve_with(vec![loopback]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }

        /// 172.16.0.0/12 range is blocked.
        #[tokio::test]
        async fn resolver_blocks_rfc1918_172() {
            let private: SocketAddr = "172.16.0.1:443".parse().unwrap();
            let result = resolve_with(vec![private]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }

        /// IPv6 loopback (::1) is blocked.
        #[tokio::test]
        async fn resolver_blocks_ipv6_loopback() {
            let loopback: SocketAddr = "[::1]:80".parse().unwrap();
            let result = resolve_with(vec![loopback]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }

        /// IPv6 link-local (fe80::/10) is blocked.
        #[tokio::test]
        async fn resolver_blocks_ipv6_link_local() {
            let link_local: SocketAddr = "[fe80::1]:80".parse().unwrap();
            let result = resolve_with(vec![link_local]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }

        /// IPv4-mapped IPv6 private address (::ffff:192.168.x.x) is blocked.
        #[tokio::test]
        async fn resolver_blocks_ipv4_mapped_ipv6_private() {
            let mapped: SocketAddr = "[::ffff:192.168.1.1]:443".parse().unwrap();
            let result = resolve_with(vec![mapped]).await;
            assert!(result.is_err());
            assert!(is_ssrf_block_error(&result.unwrap_err()));
        }
    }

    // --- is_ssrf_block_error ---
    //
    // These tests act as a regression guard: if the resolver's error message
    // format or the marker strings ever diverge, one assertion will fail and
    // force both sides to be updated in sync.

    #[test]
    fn is_ssrf_block_error_matches_resolver_message() {
        // Exact format emitted by SsrfSafeResolver::resolve() when all
        // resolved addresses are in a blocked range (DNS-rebinding scenario).
        let resolver_msg = "Blocked: the resolved IP address for 'evil.azurewebsites.net' \
                            is in a restricted range. df.http() cannot access private or \
                            internal network addresses.";
        assert!(is_ssrf_block_error(resolver_msg));
    }

    #[test]
    fn is_ssrf_block_error_rejects_unrelated_errors() {
        assert!(!is_ssrf_block_error(
            "HTTP connection failed: connection refused"
        ));
        assert!(!is_ssrf_block_error(
            "HTTP timeout after 30s: https://example.com"
        ));
        assert!(!is_ssrf_block_error(""));
    }

    #[test]
    fn is_ssrf_block_error_requires_both_markers() {
        // "Blocked:" alone (allowlist rejection) must not match — those errors
        // are caught before request.send() and have their own audit path.
        assert!(!is_ssrf_block_error(
            "Blocked: requests to bare IP addresses are not permitted."
        ));
        assert!(!is_ssrf_block_error(
            "Blocked: 'example.com' is not in the allowed endpoint list."
        ));
        // "restricted" alone, without the "Blocked:" prefix, must not match.
        assert!(!is_ssrf_block_error("The IP is in a restricted range."));
    }
}
