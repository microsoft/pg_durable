# HTTP Security in pg_durable

This document describes the security model for `df.http()` — the durable HTTP
activity that lets workflows make outbound HTTP(S) requests from within the
PostgreSQL background worker.

---

## Table of Contents

1. [Feature Flags](#1-feature-flags)
2. [Three-Layer Security Model](#2-three-layer-security-model)
3. [Layer 0: PostgreSQL Privilege Check](#3-layer-0-postgresql-privilege-check)
4. [Layer 1: IP Blocklist (SSRF protection)](#4-layer-1-ip-blocklist-ssrf-protection)
5. [Layer 2: Endpoint Allow-List](#5-layer-2-endpoint-allow-list)
6. [Additional Hardening](#6-additional-hardening)
7. [Audit Logging](#7-audit-logging)
8. [Error Messages](#8-error-messages)
9. [Out of Scope](#9-out-of-scope)

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
pass — this includes the source-built `Dockerfile` used for local dev and CI.
The released Debian packages are built with `http-allow-azure-domains`, so the
published Docker image (`Dockerfile.release`, which installs that package)
inherits the `http-allow-azure-domains` policy.

### When no feature is set

`df.http()` **fails at the point `df.http()` is called in SQL** with:

```
df.http() is disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable outbound HTTP requests.
```

Because `df.nodes` rows can be inserted by hand (bypassing the DSL), the same
block is enforced again at execution time inside `execute_http.rs` via
`validate_url_allowlist`.

---

## 2. Three-Layer Security Model

```
┌──────────────────────────────────────────────────────────┐
│  Layer 0: PostgreSQL Privilege Check                     │
│                                                          │
│  • submitted_by role must have EXECUTE on df.http()      │
│  • Checked at execution time against the live catalog    │
│  • Blocks bypass via raw df.start() JSON injection       │
│  • Runs before any network activity                      │
│                                                          │
├──────────────────────────────────────────────────────────┤
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

All three layers run inside `execute_http.rs` before the request is sent.
There is no GUC, no table override, no superuser bypass for Layers 1 and 2.

---

## 3. Layer 0: PostgreSQL Privilege Check

### 3.1 Purpose

A user granted `df.grant_usage()` can call `df.start()` directly with a
hand-crafted `Durofut` JSON string, inserting an HTTP node without ever calling
`df.http()`.  The DSL-time guard inside `df.http()` does not run in that path.

To close this gap, `execute_http` checks at execution time whether the
`submitted_by` role recorded in the node still holds `EXECUTE` privilege on
`df.http()`.  If the role's grant has been revoked since the node was created,
the node fails immediately.

### 3.2 Mechanism

`execute_http` runs the following check before any network activity:

```sql
SELECT has_function_privilege($submitted_by::regrole,
    'df.http(text,text,text,jsonb,integer)'::regprocedure,
    'EXECUTE')
```

`has_function_privilege` honours PostgreSQL's standard privilege model:
superusers always return `true`; regular roles return `true` only when an
explicit `GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO <role>` (or a role that
inherits one) is in effect.

### 3.3 Managing access

HTTP access is **opt-in** and separate from general `df` access.

#### Granting access

Use `df.grant_usage()` with `include_http => true`:

```sql
SELECT df.grant_usage('my_role', include_http => true);
```

Or grant directly:

```sql
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO my_role;
```

`df.grant_usage('my_role')` (without `include_http`) grants all standard `df`
privileges but **not** `df.http()`.  HTTP access must be explicitly opted in to.

#### Revoking access

To remove HTTP access without removing all `df` access:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM my_role;
```

After this, any existing or future HTTP nodes submitted by `my_role` will fail
at execution time with a "permission denied" error.  All other `df` functions
remain accessible.

`df.revoke_usage('my_role')` removes all `df` access, including `df.http()`.

#### PUBLIC grant and upgrades

Fresh installs (v0.2.0+) have `EXECUTE` on `df.http()` revoked from `PUBLIC`
at `CREATE EXTENSION` time.  Installs that upgraded from v0.1.1 **retain** the
PUBLIC grant that v0.1.1 issued — the upgrade script does not revoke it.

If an upgraded install should enforce opt-in HTTP permissions, the admin must
run manually:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;
```

When `df.grant_usage(role, include_http => false)` is called and the role still
has effective HTTP access via the PUBLIC grant (or another inherited grant), a
`WARNING` is emitted to signal that the revocation had no net effect.

### 3.4 Admin function protection

`df.grant_usage()` and `df.revoke_usage()` are admin-only functions.
`EXECUTE` is revoked from `PUBLIC` at `CREATE EXTENSION` time, so only
superusers can call them.

> **Caution:** `df.grant_usage()` internally runs
> `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df`, which temporarily includes
> `df.grant_usage()` and `df.revoke_usage()` themselves before the function
> immediately revokes them from the target role.  If an admin replicates the
> blanket `GRANT` manually without the matching `REVOKE`s, the target role
> will gain access to these admin helpers.  Always use `df.grant_usage()`
> rather than hand-crafting the equivalent `GRANT` statements.

### 3.5 Feature-flag interaction

The privilege check runs regardless of which HTTP Cargo feature is enabled.
When no HTTP feature is compiled in, the request is still blocked later by the
DSL-time guard and by execution-time URL validation, but the privilege check
remains compiled in and still runs before any network activity.

---

## 4. Layer 1: IP Blocklist (SSRF protection)

### 4.1 Blocked IPv4 ranges

| CIDR | Description |
|------|-------------|
| `0.0.0.0/8` | "This" network |
| `10.0.0.0/8` | RFC 1918 private |
| `127.0.0.0/8` | Loopback |
| `169.254.0.0/16` | Link-local — includes cloud metadata at `169.254.169.254` |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |

### 4.2 Blocked IPv6 ranges

| Range | Description |
|-------|-------------|
| `::/128` | Unspecified |
| `::1/128` | Loopback |
| `fe80::/10` | Link-local |
| `fc00::/7` | Unique local (ULA) |

### 4.3 IPv4-mapped IPv6 handling

Addresses of the form `::ffff:A.B.C.D` are unwrapped to their embedded IPv4
before the blocklist check, preventing bypasses like `::ffff:169.254.169.254`.

### 4.4 DNS rebinding prevention

The SSRF-safe DNS resolver (`SsrfSafeResolver`) wraps the system resolver and
filters blocked IPs **inline** — the same IP that passes the check is the one
used for the TCP connection.  There is no window for a rebinding attack.

Only the single IP address that `reqwest` actually connects to is checked.  If
DNS returns multiple A/AAAA records, the others are not checked because they
are never used.  This is intentional, not a gap — checking unused addresses
would create false positives without any security benefit.

### 4.5 IP literals in URL

Bare IP literals in URLs (e.g. `http://169.254.169.254/...`) bypass DNS
entirely — `reqwest` connects directly without calling the resolver.
`validate_url_allowlist` blocks all bare IPs unconditionally, so these never
reach the resolver.

---

## 5. Layer 2: Endpoint Allow-List

### 5.1 Azure domains (always present with `http-allow-azure-domains`)

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

### 5.2 Test domains (additional with `http-allow-test-domains`)

| Domain | Purpose |
|--------|---------|
| `api.github.com` | GitHub API (used in HTTP E2E tests) |
| `httpbingo.org` | HTTP echo service (used in HTTP E2E tests) |

### 5.3 Bare IP rejection

All bare IPv4 and IPv6 addresses are rejected by `validate_url_allowlist`
regardless of feature flag — even under `http-allow-azure-domains`.
Because the allowlist blocks all bare IPs, there is no separate IP-literal
check; the allowlist is the definitive gate for IP-literal URLs.

---

## 6. Additional Hardening

### 6.1 Scheme restriction

Only `http://` and `https://` are accepted.  All other schemes (`file://`,
`ftp://`, `gopher://`, etc.) are rejected before any DNS resolution or
connection attempt.

### 6.2 Redirect blocking

`reqwest` is built with `Policy::none()` (no redirect following).  This
prevents redirect-based bypasses where an attacker hosts a public server that
returns a `302 Location: http://169.254.169.254/...` — since the redirect
target is an IP literal, the DNS resolver would never be called.

---

## 7. Audit Logging

Every HTTP attempt (allowed or blocked) is logged via `ctx.trace_info` with:

- `submitted_by` — the role that called `df.start()` at the time the node was
  created (captured as `current_user` in the DSL and stored in `FunctionNode`)
- `url` — the requested URL
- Block reason tag — `(scheme)`, `(allowlist)`, or `(ip)` in the log prefix

Resolved IP addresses are **not** included in error messages or logs to avoid
leaking internal network topology to potentially malicious users.

---

## 8. Error Messages

| Scenario | Message |
|----------|---------|
| No EXECUTE privilege on df.http() | `Blocked: role '{role}' does not have EXECUTE privilege on df.http(). Grant EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer) TO {role} to allow HTTP requests.` |
| HTTP disabled (no feature) | `Blocked: outbound HTTP requests are disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable them.` |
| Unsupported scheme | `Blocked: unsupported URL scheme '{scheme}'. Only http and https are allowed.` |
| Bare IP address | `Blocked: requests to bare IP addresses are not permitted. Use an approved Azure service hostname instead.` |
| Non-allowed domain | `Blocked: '{host}' is not in the allowed endpoint list. Only requests to approved Azure service domains are permitted.` |
| Blocked IP (literal or DNS) | `Blocked: the resolved IP address for '{host}' is in a restricted range. df.http() cannot access private or internal network addresses.` |
| DSL-time (no feature) | `df.http() is disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable outbound HTTP requests.` |

---

## 9. Out of Scope

These items are deferred to a future customer-level access control spec:

| Item | Notes |
|------|-------|
| Per-role URL/domain allowlists configurable by admins | GUC or table-driven |
| Rate limiting | DoS mitigation, not SSRF |
| Response size limits | Resource management |
| Port restrictions | Low value at this layer |
| Egress filtering to attacker-controlled domains | Separate threat (T9) |
| **Azure Private Endpoint** | Private Endpoints assign private RFC 1918 addresses to Azure services, which the IP blocklist currently blocks. Supporting Private Endpoints requires a targeted exemption mechanism that does not open all private ranges. Design is deferred to a future spec. |
