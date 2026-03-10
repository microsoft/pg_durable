# Spec: SSRF Protection for `df.http()`

**Status**: Completed  
**Threat**: T8 in [spec-security-model.md](spec-security-model.md)  
**Severity**: CRITICAL

---

## Table of Contents

1. [Overview](#1-overview)
2. [Threat Model](#2-threat-model)
3. [Design Decisions](#3-design-decisions)
4. [Two-Layer Security Model](#4-two-layer-security-model)
5. [Dataplane Protection (This Spec)](#5-dataplane-protection-this-spec)
6. [Implementation](#6-implementation)
7. [Testing](#7-testing)
8. [Out of Scope](#8-out-of-scope)

---

## 1. Overview

`df.http()` allows durable functions to make HTTP requests from within the PostgreSQL background worker. In a PG-as-a-service deployment, this creates a dataplane escape vector: a malicious customer can probe or attack the hosting infrastructure's local network (cloud metadata endpoints, internal APIs, localhost services).

This spec defines the **dataplane protection layer** — a compile-time IP blocklist that prevents HTTP requests to private/internal network addresses. This layer is hardcoded and cannot be bypassed by any database user, including superusers.

---

## 2. Threat Model

### Attack Scenarios

**Cloud metadata exfiltration:**
```sql
SELECT df.start(
    df.http('GET', 'http://169.254.169.254/latest/meta-data/iam/security-credentials/'),
    'steal-creds'
);
```

**Localhost service probing:**
```sql
SELECT df.start(
    df.http('GET', 'http://127.0.0.1:8500/v1/agent/members'),
    'probe-consul'
);
```

**Internal network scanning:**
```sql
SELECT df.start(
    df.http('GET', 'http://10.0.0.1:9090/api/v1/targets'),
    'probe-prometheus'
);
```

**IPv4-mapped IPv6 bypass:**
```sql
-- Same as 169.254.169.254 but via IPv6 notation
SELECT df.start(
    df.http('GET', 'http://[::ffff:169.254.169.254]/latest/meta-data/'),
    'ipv6-bypass'
);
```

### Impact

A successful SSRF attack from within the PG dataplane can:
- Steal cloud instance credentials (IAM roles, managed identity tokens)
- Access internal service discovery and configuration
- Pivot to internal services not exposed to the internet
- Exfiltrate customer data to attacker-controlled endpoints (addressed by T9, not this spec)

---

## 3. Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Two layers: compile-time dataplane + future customer-level controls | Dataplane protection is non-negotiable and must not be bypassable. Customer-level controls (allowlists, REVOKE) are a separate concern. |
| D2 | HTTP and HTTPS only — block all other schemes | `file://`, `ftp://`, `gopher://` etc. have no legitimate use case and expand the attack surface. |
| D3 | Port restrictions: out of scope for now | All ports are allowed for HTTP/HTTPS. Port-based restrictions may be added in the customer-level spec. |
| D4 | Handle IPv4-mapped IPv6 (`::ffff:A.B.C.D`) | Must extract the embedded IPv4 address and check it against the blocklist. |
| D5 | Check only the selected IP, not all A records | DNS may return multiple addresses. Only the one `reqwest` actually connects to needs to pass the blocklist. Document this explicitly. |
| D6 | No DNS domain allowlist at this layer | Allowlists are a customer-level concern. The dataplane layer only blocks; it never allows based on domain. |
| D7 | Rate limiting: deferred | Deferred. |
| D8 | Response size limits: deferred | Deferred. |
| D9 | Log `submitted_by` and `login_role` for HTTP requests | Audit trail for who initiated the request. |

---

## 4. Two-Layer Security Model

```
┌──────────────────────────────────────────────────────────┐
│                  Layer 1: Dataplane Protection            │
│                  (this spec)                              │
│                                                          │
│  • Cargo feature: no-ssrf-protection (opt-in to disable) │
│  • Blocks private/reserved IP ranges                     │
│  • Cannot be bypassed by superusers or GUCs              │
│  • Protects the hosting infrastructure                   │
│                                                          │
├──────────────────────────────────────────────────────────┤
│                  Layer 2: Customer-Level Controls         │
│                  (future spec)                            │
│                                                          │
│  • REVOKE EXECUTE on df.http() from PUBLIC               │
│  • URL/domain allowlists (GUC or table)                  │
│  • Per-role HTTP permissions                             │
│  • Rate limiting                                         │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Layer 1 runs **inside** the HTTP activity, before the request is sent. It is always active unless the `no-ssrf-protection` feature is explicitly compiled in. There is no GUC, no table, no superuser override.

Layer 2 is orthogonal and additive. It will be specified separately and can be configured by database administrators.

---

## 5. Dataplane Protection (This Spec)

### 5.1 Scheme Validation

Only `http://` and `https://` schemes are permitted. All other schemes are rejected **before** any DNS resolution or connection attempt.

Reject with: `"Blocked: unsupported URL scheme '{scheme}'. Only http and https are allowed."`

### 5.2 Blocked IP Ranges

After DNS resolution, the resolved IP address is checked against these CIDR ranges:

| CIDR | Description |
|------|-------------|
| `127.0.0.0/8` | IPv4 loopback |
| `::1/128` | IPv6 loopback |
| `10.0.0.0/8` | RFC 1918 private |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |
| `169.254.0.0/16` | Link-local (includes cloud metadata at `169.254.169.254`) |
| `fe80::/10` | IPv6 link-local |
| `fc00::/7` | IPv6 unique local address (ULA) |
| `0.0.0.0/8` | "This" network |
| `::/128` | Unspecified address |

### 5.3 IPv4-Mapped IPv6 Handling

IPv4-mapped IPv6 addresses (`::ffff:A.B.C.D`) must be recognized and the embedded IPv4 address extracted before checking against the blocklist. For example:

- `::ffff:127.0.0.1` → extract `127.0.0.1` → blocked (loopback)
- `::ffff:169.254.169.254` → extract `169.254.169.254` → blocked (link-local)
- `::ffff:10.0.0.1` → extract `10.0.0.1` → blocked (RFC 1918)
- `::ffff:93.184.216.34` → extract `93.184.216.34` → allowed (public)

### 5.4 DNS Resolution and IP Check

The protection follows this sequence:

```
URL received
  │
  ├─ Parse scheme → reject if not http/https
  │
  ├─ Extract hostname
  │
  ├─ Resolve hostname via DNS → get list of IPs
  │
  ├─ reqwest selects one IP to connect to
  │
  ├─ Check selected IP against blocklist
  │     ├─ If IPv4-mapped IPv6: extract IPv4, check IPv4 blocklist
  │     └─ If blocked: reject request
  │
  └─ Send request
```

**Important**: Only the single IP address that `reqwest` actually connects to is checked. If DNS returns multiple A/AAAA records, the others are not checked because they are never used. This is documented behavior, not a gap — checking unused IPs would create false positives without security benefit.

#### DNS Rebinding Protection

A DNS rebinding attack works by returning a public IP on first lookup (passing the blocklist check) and a private IP on a subsequent lookup (used for the actual connection). To prevent this:

- DNS resolution and the IP blocklist check must happen on the **same resolved address** that is used for the connection.
- The implementation must use a custom `reqwest` `resolve` strategy or a connect callback that intercepts the resolved IP before the TCP connection is established, ensuring the blocklist check and the connection use the same IP.
- Caching DNS results and checking them separately from the connection is **not sufficient** — the check must be inline with the connect path.

### 5.5 Cargo Feature Gate

```toml
[features]
default = ["pg17"]
no-ssrf-protection = []
```

SSRF protection is **on by default** — no feature flag needed. The `no-ssrf-protection` feature is an opt-in escape hatch. When compiled with it (e.g., for local development or testing), all IP blocklist checks are skipped.

The blocklist logic is gated with `#[cfg(not(feature = "no-ssrf-protection"))]`:
- Default (feature absent): IP blocklist is enforced, no override possible.
- With `no-ssrf-protection` enabled: all URLs are allowed (development/testing only).

### 5.6 Error Messages

When a request is blocked, return a clear error without leaking internal network topology:

- Scheme violation: `"Blocked: unsupported URL scheme '{scheme}'. Only http and https are allowed."`
- IP blocklist: `"Blocked: the resolved IP address for '{hostname}' is in a restricted range. df.http() cannot access private or internal network addresses."`

Do **not** include the resolved IP in the error message — this would leak infrastructure details to a potentially malicious user.

### 5.7 Audit Logging

All HTTP requests (both allowed and blocked) must be logged with:

- `submitted_by`: the role that called `df.start()`
- `login_role`: the authenticated connection role
- `url`: the requested URL
- `blocked`: whether the request was blocked by SSRF protection
- `reason`: if blocked, the reason (scheme/IP range)

These fields are already available on `FunctionNode` (`submitted_by`, `login_role`) and must be threaded through to the HTTP activity.

---

## 6. Implementation

### 6.1 New Module: `src/ssrf.rs`

Create a module with the blocklist validation logic:

```rust
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Check if an IP address is in a blocked range.
/// Returns Some(reason) if blocked, None if allowed.
#[cfg(not(feature = "no-ssrf-protection"))]
pub fn check_blocked_ip(ip: IpAddr) -> Option<&'static str> {
    // Handle IPv4-mapped IPv6: extract the embedded IPv4
    let ip = match ip {
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                IpAddr::V4(v4)
            } else {
                IpAddr::V6(v6)
            }
        }
        other => other,
    };

    match ip {
        IpAddr::V4(v4) => check_blocked_ipv4(v4),
        IpAddr::V6(v6) => check_blocked_ipv6(v6),
    }
}

fn check_blocked_ipv4(ip: Ipv4Addr) -> Option<&'static str> {
    let octets = ip.octets();
    match octets {
        [127, ..] => Some("loopback"),
        [10, ..] => Some("private (10.0.0.0/8)"),
        [172, b, ..] if (16..=31).contains(&b) => Some("private (172.16.0.0/12)"),
        [192, 168, ..] => Some("private (192.168.0.0/16)"),
        [169, 254, ..] => Some("link-local"),
        [0, ..] => Some("reserved (0.0.0.0/8)"),
        _ => None,
    }
}

fn check_blocked_ipv6(ip: Ipv6Addr) -> Option<&'static str> {
    if ip.is_loopback() {
        return Some("loopback (::1)");
    }
    let segments = ip.segments();
    if segments[0] == 0xfe80 {
        return Some("link-local (fe80::/10)");
    }
    if segments[0] & 0xfe00 == 0xfc00 {
        return Some("unique local (fc00::/7)");
    }
    if ip.is_unspecified() {
        return Some("unspecified (::)");
    }
    None
}
```

### 6.2 DNS Resolution with Inline Check

Use `reqwest`'s `resolve` callback or `hickory-dns` to perform DNS resolution and check the IP before the connection:

```rust
use reqwest::dns::{Resolve, Resolving, Addrs};
use std::net::SocketAddr;

struct SsrfSafeResolver {
    inner: Arc<dyn Resolve>,
}

impl Resolve for SsrfSafeResolver {
    fn resolve(&self, name: hyper::client::connect::dns::Name) -> Resolving {
        let inner = self.inner.clone();
        Box::pin(async move {
            let addrs = inner.resolve(name).await?;
            let filtered: Vec<SocketAddr> = addrs
                .filter(|addr| check_blocked_ip(addr.ip()).is_none())
                .collect();
            if filtered.is_empty() {
                return Err("all resolved IPs are in blocked ranges".into());
            }
            Ok(Box::new(filtered.into_iter()) as Addrs)
        })
    }
}
```

> **Note**: The exact integration point depends on `reqwest` 0.12's DNS resolver API. The implementation may need to use a `tower` layer or connect callback instead. The key requirement is that the IP check happens **after** DNS resolution and **before** TCP connect, on the same address.

### 6.3 Changes to `execute_http.rs`

The activity gains three changes:

1. **Scheme check** before building the client (always, regardless of feature flag).
2. **SSRF-safe resolver** injected into the `reqwest::Client::builder()` (when feature enabled).
3. **Audit log fields** (`submitted_by`, `login_role`) passed through from `FunctionNode` and logged.

### 6.4 Changes to `HttpConfig`

Add audit context fields:

```rust
pub struct HttpConfig {
    pub url: String,
    pub method: String,
    pub body: Option<String>,
    pub headers: Option<serde_json::Value>,
    pub timeout_seconds: u64,
    // Audit context (populated from FunctionNode)
    pub submitted_by: Option<String>,
    pub login_role: Option<String>,
}
```

These are populated when building the `HttpConfig` from the `FunctionNode` in the orchestration, not by the user's DSL call.

---

## 7. Testing

### 7.1 Unit Tests

Test `check_blocked_ip()` against all blocked ranges:

- All RFC 1918 ranges (10.x, 172.16-31.x, 192.168.x)
- Loopback (127.0.0.1, ::1)
- Link-local (169.254.169.254)
- IPv4-mapped IPv6 variants of all the above
- Public IPs that must be allowed (e.g., 8.8.8.8, 93.184.216.34)
- Edge cases: 172.15.255.255 (allowed), 172.16.0.0 (blocked), 172.31.255.255 (blocked), 172.32.0.0 (allowed)

### 7.2 E2E Tests

Create a test that verifies blocked requests fail with the expected error message:

```sql
-- Test: SSRF protection blocks link-local addresses
SELECT df.start(
    df.http('GET', 'http://169.254.169.254/latest/meta-data/'),
    'test-ssrf-blocked'
);
-- Poll until failed, verify error contains "restricted range"
```

### 7.3 Feature Flag Test

Verify that building with `no-ssrf-protection` allows all IPs (for development):

```bash
cargo build --features pg17,no-ssrf-protection
```

---

## 8. Out of Scope

These items are explicitly deferred to the customer-level access control spec (Layer 2):

| Item | Rationale |
|------|-----------|
| URL/domain allowlists | Customer policy, not infrastructure protection |
| `REVOKE EXECUTE` on `df.http()` | Standard PG permission model, not SSRF-specific |
| Per-role HTTP permissions | Customer policy |
| Rate limiting | DoS mitigation, not SSRF |
| Response size limits | Resource management, not SSRF |
| Port restrictions | Low value at dataplane layer; all ports may host legitimate services |
| Egress filtering (block outbound to attacker domains) | Addressed by T9 |
