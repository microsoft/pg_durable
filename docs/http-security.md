# HTTP Security in pg_durable

This document describes the security model for `df.http()` — the durable HTTP
activity that lets workflows make outbound HTTP(S) requests from within the
PostgreSQL background worker.

---

## Table of Contents

1. [Feature Flags](#1-feature-flags)
2. [Two-Layer Security Model](#2-two-layer-security-model)
3. [Layer 1: IP Blocklist (SSRF protection)](#3-layer-1-ip-blocklist-ssrf-protection)
4. [Layer 2: Endpoint Allow-List](#4-layer-2-endpoint-allow-list)
5. [Additional Hardening](#5-additional-hardening)
6. [Audit Logging](#6-audit-logging)
7. [Error Messages](#7-error-messages)
8. [Out of Scope](#8-out-of-scope)

---

## 1. Feature Flags

Outbound HTTP access is controlled entirely by Cargo features at build time.
The database cannot override these choices — they cannot be changed with GUCs
or SQL.

| Feature | What is allowed | Use case |
|---------|-----------------|----------|
| *(none)* | Nothing — `df.http()` errors immediately at DSL time **and** at execution time | Deployments that don't need HTTP |
| `http-allow-azure-domains` | Subdomains of the Azure allow-list only; bare IPs blocked; redirects blocked | Production |
| `http-allow-test-domains` | Everything in `http-allow-azure-domains` **plus** `api.github.com` and `httpbingo.org` | E2E testing; implies `http-allow-azure-domains` |
| `http-allow-all` | All URLs; SSRF IP blocklist and allow-list are both disabled | Local development only |

The scripts and CI use `http-allow-test-domains` so that the HTTP E2E tests
pass.  The production `Dockerfile` uses `http-allow-azure-domains`.

### When no feature is set

`df.http()` **fails at the point `df.http()` is called in SQL** with:

```
df.http() is disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable outbound HTTP requests.
```

Because `df.nodes` rows can be inserted by hand (bypassing the DSL), the same
block is enforced again at execution time inside `execute_http.rs` via
`validate_url_allowlist`.

---

## 2. Two-Layer Security Model

```
┌──────────────────────────────────────────────────────────┐
│  Layer 1: IP Blocklist (SSRF protection)                 │
│                                                          │
│  • Private/reserved IP ranges blocked after DNS          │
│  • IPv4-mapped IPv6 (::ffff:A.B.C.D) unwrapped + checked │
│  • IP literals in URLs blocked before DNS                │
│  • DNS rebinding prevented via inline resolver check     │
│  • Disabled only under http-allow-all                    │
│                                                          │
├──────────────────────────────────────────────────────────┤
│  Layer 2: Endpoint Allow-List                            │
│                                                          │
│  • Bare IPv4/IPv6 addresses always rejected              │
│  • Hostname must match an approved suffix or exact name  │
│  • Disabled (allow everything) under http-allow-all      │
│  • Empty (block everything) when no http feature set     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

Both layers run inside `execute_http.rs` before the request is sent.  There is
no GUC, no table, no superuser override.

---

## 3. Layer 1: IP Blocklist (SSRF protection)

### 3.1 Blocked IPv4 ranges

| CIDR | Description |
|------|-------------|
| `0.0.0.0/8` | "This" network |
| `10.0.0.0/8` | RFC 1918 private |
| `127.0.0.0/8` | Loopback |
| `169.254.0.0/16` | Link-local — includes cloud metadata at `169.254.169.254` |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |

### 3.2 Blocked IPv6 ranges

| Range | Description |
|-------|-------------|
| `::/128` | Unspecified |
| `::1/128` | Loopback |
| `fe80::/10` | Link-local |
| `fc00::/7` | Unique local (ULA) |

### 3.3 IPv4-mapped IPv6 handling

Addresses of the form `::ffff:A.B.C.D` are unwrapped to their embedded IPv4
before the blocklist check, preventing bypasses like `::ffff:169.254.169.254`.

### 3.4 DNS rebinding prevention

The SSRF-safe DNS resolver (`SsrfSafeResolver`) wraps the system resolver and
filters blocked IPs **inline** — the same IP that passes the check is the one
used for the TCP connection.  There is no window for a rebinding attack.

Only the single IP address that `reqwest` actually connects to is checked.  If
DNS returns multiple A/AAAA records, the others are not checked because they
are never used.  This is intentional, not a gap — checking unused addresses
would create false positives without any security benefit.

### 3.5 IP literals in URL

Bare IP literals in URLs (e.g. `http://169.254.169.254/...`) bypass DNS
entirely — `reqwest` connects directly without calling the resolver.
`validate_url_host` catches these before the request is built.

---

## 4. Layer 2: Endpoint Allow-List

### 4.1 Azure domains (always present with `http-allow-azure-domains`)

Only subdomains of the following suffixes are permitted.  Apex domains (e.g.
`blob.core.windows.net` without a subdomain label) are rejected.

| Suffix | Service |
|--------|---------|
| `.blob.core.windows.net` | Azure Blob Storage |
| `.blob.storage.azure.net` | Azure Blob Storage (secondary) |
| `.queue.core.windows.net` | Azure Queue Storage |
| `.table.core.windows.net` | Azure Table Storage |
| `.file.core.windows.net` | Azure Files |
| `.azurewebsites.net` | Azure App Service |
| `.azure-api.net` | Azure API Management |
| `.documents.azure.com` | Azure Cosmos DB |
| `.servicebus.windows.net` | Azure Service Bus |
| `.openai.azure.com` | Azure OpenAI |
| `.cognitiveservices.azure.com` | Azure Cognitive Services |
| `.vault.azure.net` | Azure Key Vault |
| `.redis.cache.windows.net` | Azure Cache for Redis |
| `.database.windows.net` | Azure SQL Database |
| `.kusto.windows.net` | Azure Data Explorer |
| `.azurefd.net` | Azure Front Door |
| `.azureedge.net` | Azure CDN |
| `.azure-devices.net` | Azure IoT Hub |
| `.trafficmanager.net` | Azure Traffic Manager |
| `.cloudapp.azure.com` | Azure Cloud App |

### 4.2 Test domains (additional with `http-allow-test-domains`)

| Domain | Purpose |
|--------|---------|
| `api.github.com` | GitHub API (used in HTTP E2E tests) |
| `httpbingo.org` | HTTP echo service (used in HTTP E2E tests) |

### 4.3 Bare IP rejection

All bare IPv4 and IPv6 addresses are rejected by `validate_url_allowlist`
regardless of feature flag — even under `http-allow-azure-domains`.  This
provides defence in depth against IP literals that might slip past
`validate_url_host`.

---

## 5. Additional Hardening

### 5.1 Scheme restriction

Only `http://` and `https://` are accepted.  All other schemes (`file://`,
`ftp://`, `gopher://`, etc.) are rejected before any DNS resolution or
connection attempt.

### 5.2 Redirect blocking

`reqwest` is built with `Policy::none()` (no redirect following).  This
prevents redirect-based bypasses where an attacker hosts a public server that
returns a `302 Location: http://169.254.169.254/...` — since the redirect
target is an IP literal, the DNS resolver would never be called.

---

## 6. Audit Logging

Every HTTP attempt (allowed or blocked) is logged via `ctx.trace_info` with:

- `submitted_by` — the role that called `df.start()` at the time the node was
  created (captured as `current_user` in the DSL and stored in `FunctionNode`)
- `url` — the requested URL
- Block reason tag — `(scheme)`, `(allowlist)`, or `(ip)` in the log prefix

Resolved IP addresses are **not** included in error messages or logs to avoid
leaking internal network topology to potentially malicious users.

---

## 7. Error Messages

| Scenario | Message |
|----------|---------|
| HTTP disabled (no feature) | `Blocked: outbound HTTP requests are disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable them.` |
| Unsupported scheme | `Blocked: unsupported URL scheme '{scheme}'. Only http and https are allowed.` |
| Bare IP address | `Blocked: requests to bare IP addresses are not permitted. Use an approved Azure service hostname instead.` |
| Non-allowed domain | `Blocked: '{host}' is not in the allowed endpoint list. Only requests to approved Azure service domains are permitted.` |
| Blocked IP (literal or DNS) | `Blocked: the resolved IP address for '{host}' is in a restricted range. df.http() cannot access private or internal network addresses.` |
| DSL-time (no feature) | `df.http() is disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable outbound HTTP requests.` |

---

## 8. Out of Scope

These items are deferred to a future customer-level access control spec:

| Item | Notes |
|------|-------|
| `REVOKE EXECUTE` on `df.http()` | Standard PostgreSQL permission model |
| Per-role HTTP permissions | Customer policy |
| URL/domain allowlists configurable by admins | GUC or table-driven |
| Rate limiting | DoS mitigation, not SSRF |
| Response size limits | Resource management |
| Port restrictions | Low value at this layer |
| Egress filtering to attacker-controlled domains | Separate threat (T9) |
| **Azure Private Endpoint** | Private Endpoints assign private RFC 1918 addresses to Azure services, which the IP blocklist currently blocks. Supporting Private Endpoints requires a targeted exemption mechanism that does not open all private ranges. Design is deferred to a future spec. |
