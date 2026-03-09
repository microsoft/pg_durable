//! SSRF protection for df.http() — dataplane IP blocklist
//!
//! When the `ssrf-protection` Cargo feature is enabled (default), all HTTP
//! requests are validated against a blocklist of private/reserved IP ranges.
//! This prevents users from reaching internal network services, cloud metadata
//! endpoints, or localhost from within the PostgreSQL background worker.
//!
//! The blocklist is hardcoded and cannot be bypassed by any database user,
//! including superusers.  See docs/spec-ssrf-protection.md for the full spec.

#[cfg(feature = "ssrf-protection")]
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Check if an IP address is in a blocked (private/reserved) range.
/// Returns `Some(reason)` if blocked, `None` if allowed.
#[cfg(feature = "ssrf-protection")]
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

#[cfg(feature = "ssrf-protection")]
fn check_blocked_ipv4(ip: Ipv4Addr) -> Option<&'static str> {
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

#[cfg(feature = "ssrf-protection")]
fn check_blocked_ipv6(ip: Ipv6Addr) -> Option<&'static str> {
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
// SSRF-safe DNS resolver — wraps the default resolver and filters out blocked IPs
// ---------------------------------------------------------------------------

#[cfg(feature = "ssrf-protection")]
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

#[cfg(feature = "ssrf-protection")]
pub use resolver::SsrfSafeResolver;

// ---------------------------------------------------------------------------
// Default (system) DNS resolver — needed as the "inner" for SsrfSafeResolver
// ---------------------------------------------------------------------------

#[cfg(feature = "ssrf-protection")]
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

#[cfg(feature = "ssrf-protection")]
pub use system_resolver::SystemResolver;

// ============================================================================
// Tests
// ============================================================================

#[cfg(all(test, feature = "ssrf-protection"))]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    // --- IPv4 blocked ranges ---

    #[test]
    fn blocks_loopback() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(127, 255, 255, 255))).is_some());
    }

    #[test]
    fn blocks_rfc1918_10() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(10, 255, 255, 255))).is_some());
    }

    #[test]
    fn blocks_rfc1918_172() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 16, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 31, 255, 255))).is_some());
        // Edge: 172.15.x.x is NOT private
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 15, 255, 255))).is_none());
        // Edge: 172.32.x.x is NOT private
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(172, 32, 0, 0))).is_none());
    }

    #[test]
    fn blocks_rfc1918_192_168() {
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 255, 255))).is_some());
    }

    #[test]
    fn blocks_link_local() {
        // Cloud metadata endpoint
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 169, 254))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 0, 0))).is_some());
        assert!(check_blocked_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 255, 255))).is_some());
    }

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

    #[test]
    fn blocks_ipv6_loopback() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::LOCALHOST)).is_some());
    }

    #[test]
    fn blocks_ipv6_unspecified() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::UNSPECIFIED)).is_some());
    }

    #[test]
    fn blocks_ipv6_link_local() {
        assert!(check_blocked_ip(IpAddr::V6(Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1))).is_some());
    }

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

    #[test]
    fn blocks_ipv4_mapped_ipv6_loopback() {
        // ::ffff:127.0.0.1
        let ip: IpAddr = "::ffff:127.0.0.1".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
    }

    #[test]
    fn blocks_ipv4_mapped_ipv6_link_local() {
        // ::ffff:169.254.169.254 (cloud metadata)
        let ip: IpAddr = "::ffff:169.254.169.254".parse().unwrap();
        assert!(check_blocked_ip(ip).is_some());
    }

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
}
