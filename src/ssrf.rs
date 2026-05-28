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
//! | `http-allow-azure-domains` | SSRF IP blocklist active, bare IPs blocked, redirects blocked, only Azure suffixes allowed. |
//! | `http-allow-test-domains` | Same as `http-allow-azure-domains` **plus** `api.github.com` and `httpbingo.org` (for E2E tests). Implies `http-allow-azure-domains`. |
//! | `http-allow-all` | All SSRF protections disabled — any URL is allowed (development only). |
//!
//! The blocklist and allow-list are hardcoded and cannot be bypassed by any
//! database user, including superusers.  See docs/http-security.md for details.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

// ---------------------------------------------------------------------------
// Endpoint allow-list — compile-time constant
// ---------------------------------------------------------------------------

/// Returns `true` when *any* HTTP feature is enabled (azure, test, or all).
pub const fn http_enabled() -> bool {
    cfg!(any(
        feature = "http-allow-azure-domains",
        feature = "http-allow-test-domains",
        feature = "http-allow-all"
    ))
}

/// Hard-coded Azure endpoint allow-list (data-plane only).
///
/// Populated when `http-allow-azure-domains` (or `http-allow-test-domains`,
/// which implies it) is enabled.  When `http-allow-all` is set the allow-list
/// is bypassed entirely so its contents don't matter.
///
/// Each entry starts with `.` so that a simple `ends_with` check naturally
/// requires at least one subdomain label (the apex domain itself never matches).
#[cfg(any(
    feature = "http-allow-azure-domains",
    feature = "http-allow-test-domains"
))]
pub(crate) const AZURE_DOMAIN_SUFFIXES: &[&str] = &[
    ".blob.core.windows.net",
    ".blob.storage.azure.net",
    ".queue.core.windows.net",
    ".table.core.windows.net",
    ".file.core.windows.net",
    ".azurewebsites.net",
    ".azure-api.net",
    ".documents.azure.com",
    ".servicebus.windows.net",
    ".openai.azure.com",
    ".cognitiveservices.azure.com",
    ".vault.azure.net",
    ".redis.cache.windows.net",
    ".database.windows.net",
    ".kusto.windows.net",
    ".azurefd.net",
    ".azureedge.net",
    ".azure-devices.net",
    ".trafficmanager.net",
    ".cloudapp.azure.com",
];

/// Fully-qualified test domains (exact match, not suffix).
#[cfg(feature = "http-allow-test-domains")]
pub(crate) const TEST_EXACT_DOMAINS: &[&str] = &["api.github.com", "httpbin.org", "httpbingo.org"];

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

/// Validate a URL scheme. Only `http` and `https` are permitted.
/// Returns `Err` with a user-facing message if the scheme is disallowed.
pub fn validate_url_scheme(url: &str) -> Result<(), String> {
    let scheme = url.split("://").next().unwrap_or("").to_ascii_lowercase();
    match scheme.as_str() {
        "http" | "https" => Ok(()),
        other => Err(format!(
            "Blocked: unsupported URL scheme '{other}'. Only http and https are allowed."
        )),
    }
}

// ---------------------------------------------------------------------------
// Endpoint allow-list validation
// ---------------------------------------------------------------------------

/// Validate a URL against the endpoint allow-list.
///
/// Behaviour depends on Cargo features (most to least restrictive):
///
/// * *(none)* — all requests blocked, regardless of domain.
/// * `http-allow-azure-domains` — bare IPs blocked; only Azure suffixes allowed.
/// * `http-allow-test-domains` — same as above **plus** `api.github.com` and
///   `httpbingo.org` (for E2E tests).
/// * `http-allow-all` — allow-list check is skipped entirely; all domains pass.
pub fn validate_url_allowlist(url: &str) -> Result<(), String> {
    // http-allow-all: skip all domain checks.
    #[cfg(feature = "http-allow-all")]
    {
        let _ = url;
        Ok(())
    }

    #[cfg(not(feature = "http-allow-all"))]
    {
        // No http feature at all — block everything.
        #[cfg(not(any(
            feature = "http-allow-azure-domains",
            feature = "http-allow-test-domains",
        )))]
        {
            let _ = url;
            Err("Blocked: outbound HTTP requests are disabled. \
                 Rebuild with the 'http-allow-azure-domains' Cargo feature to enable them."
                .to_string())
        }

        // http-allow-azure-domains or http-allow-test-domains: enforce allow-list.
        #[cfg(any(
            feature = "http-allow-azure-domains",
            feature = "http-allow-test-domains",
        ))]
        {
            let host = extract_host(url)
                .ok_or_else(|| "Blocked: unable to extract hostname from URL.".to_string())?;

            let host_lower = host.to_ascii_lowercase();

            // Block ALL bare IP addresses (IPv4 and IPv6).
            if host_lower.parse::<IpAddr>().is_ok() {
                return Err("Blocked: requests to bare IP addresses are not permitted. \
                     Use an approved Azure service hostname instead."
                    .to_string());
            }

            // Check Azure suffixes (always present when either azure or test feature is on).
            for suffix in AZURE_DOMAIN_SUFFIXES {
                if host_lower.ends_with(suffix) {
                    return Ok(());
                }
            }

            // Additional test domains (only with http-allow-test-domains).
            #[cfg(feature = "http-allow-test-domains")]
            for exact in TEST_EXACT_DOMAINS {
                if host_lower == *exact {
                    return Ok(());
                }
            }

            Err(format!(
                "Blocked: '{}' is not in the allowed endpoint list. \
                 Only requests to approved Azure service domains are permitted.",
                host
            ))
        }
    }
}

// ---------------------------------------------------------------------------
// Host extraction helper
// ---------------------------------------------------------------------------

/// Extract the hostname (without port or brackets) from a URL.
///
/// Returns `None` for malformed URLs or URLs without a `://` scheme separator.
#[cfg(not(feature = "http-allow-all"))]
fn extract_host(url: &str) -> Option<String> {
    // Strip scheme
    let after_scheme = url.find("://").map(|i| &url[i + 3..])?;
    // Strip path, query, and fragment — isolate authority (host + optional port).
    // Per RFC 3986 / WHATWG URL, the authority is terminated by '/', '?', or '#'.
    // Splitting only on '/' would let an attacker embed '?' or '#' to smuggle a
    // fake suffix past our allowlist while reqwest connects to the real host.
    let authority = after_scheme
        .split(['/', '?', '#'])
        .next()
        .unwrap_or(after_scheme);
    // Strip userinfo (user:pass@)
    let host_port = match authority.rfind('@') {
        Some(i) => &authority[i + 1..],
        None => authority,
    };
    // Extract host, handling bracketed IPv6 like [::1]:8080
    let host = if host_port.starts_with('[') {
        // IPv6 literal in brackets
        let end = host_port.find(']')?;
        &host_port[1..end]
    } else {
        // IPv4 or hostname — strip port
        match host_port.rfind(':') {
            Some(i) => &host_port[..i],
            None => host_port,
        }
    };

    if host.is_empty() {
        return None;
    }

    Some(host.to_string())
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

    #[test]
    fn allows_http_https() {
        assert!(validate_url_scheme("http://example.com").is_ok());
        assert!(validate_url_scheme("https://example.com").is_ok());
        assert!(validate_url_scheme("HTTP://EXAMPLE.COM").is_ok());
        assert!(validate_url_scheme("HTTPS://example.com").is_ok());
    }

    #[test]
    fn blocks_file_scheme() {
        assert!(validate_url_scheme("file:///etc/passwd").is_err());
    }

    #[test]
    fn blocks_ftp_scheme() {
        assert!(validate_url_scheme("ftp://ftp.example.com").is_err());
    }

    #[test]
    fn blocks_gopher_scheme() {
        assert!(validate_url_scheme("gopher://evil.com").is_err());
    }

    #[test]
    fn blocks_empty_and_malformed() {
        assert!(validate_url_scheme("").is_err());
        assert!(validate_url_scheme("no-scheme").is_err());
    }

    // --- extract_host helper ---

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn extract_host_basic() {
        assert_eq!(
            extract_host("http://example.com/path"),
            Some("example.com".into())
        );
        assert_eq!(
            extract_host("https://foo.blob.core.windows.net/c"),
            Some("foo.blob.core.windows.net".into())
        );
        assert_eq!(extract_host("http://host:8080/p"), Some("host".into()));
        assert_eq!(extract_host("http://[::1]:80/p"), Some("::1".into()));
        assert_eq!(extract_host("http://user:pass@host/p"), Some("host".into()));
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn extract_host_query_and_fragment() {
        // Query-only URL (no path slash after authority)
        assert_eq!(
            extract_host("https://myaccount.blob.core.windows.net?comp=list"),
            Some("myaccount.blob.core.windows.net".into())
        );
        // Fragment-only URL
        assert_eq!(
            extract_host("https://example.com#section"),
            Some("example.com".into())
        );
        // Query before path — authority must stop at '?'
        assert_eq!(
            extract_host("https://evil.com?.blob.core.windows.net/exfil"),
            Some("evil.com".into())
        );
        // Fragment before path
        assert_eq!(
            extract_host("https://evil.com#.blob.core.windows.net"),
            Some("evil.com".into())
        );
        // Userinfo confusion via query — '@' is in the query, not the authority
        assert_eq!(
            extract_host("https://evil.com?@myaccount.blob.core.windows.net"),
            Some("evil.com".into())
        );
    }

    #[cfg(not(feature = "http-allow-all"))]
    #[test]
    fn extract_host_none_cases() {
        assert_eq!(extract_host("no-scheme"), None);
        assert_eq!(extract_host(""), None);
    }

    // --- Endpoint allow-list validation ---

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
        assert!(validate_url_allowlist("https://api.github.com/repos").is_err());
        assert!(validate_url_allowlist("https://evil.com/steal").is_err());
        assert!(validate_url_allowlist("https://management.azure.com/sub").is_err());
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
    fn allowlist_blocks_percent_encoded_host() {
        // %2E is a percent-encoded '.'; our parser does no decoding so the
        // encoded form never matches the suffix — the request is blocked.
        // This locks the safe current behavior against accidental URL decoding.
        assert!(validate_url_allowlist("https://foo%2Eblob%2Ecore%2Ewindows%2Enet/c").is_err());
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

    // --- Test domains (only with http-allow-test-domains) ---

    #[cfg(feature = "http-allow-test-domains")]
    #[test]
    fn allowlist_allows_test_domains() {
        assert!(validate_url_allowlist("https://api.github.com/repos").is_ok());
        assert!(validate_url_allowlist("https://httpbingo.org/get").is_ok());
    }

    #[cfg(feature = "http-allow-test-domains")]
    #[test]
    fn allowlist_still_blocks_arbitrary_domains() {
        assert!(validate_url_allowlist("https://example.com/path").is_err());
        assert!(validate_url_allowlist("https://evil.com/steal").is_err());
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
