# HTTP Security in pg_durable

This document describes the security model for `df.http()` — the durable HTTP
activity that lets workflows make outbound HTTP(S) requests from within the
PostgreSQL background worker.

The same HTTP policy applies to `df.http_multipart`, which has its own function
privilege check. For endpoint credentials, see
[the credential security contract](spec-security-model.md#44-endpoint-credentials).

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
| `http-allow-azure-domains` | HTTPS to subdomains of the Azure allow-list plus `api.github.com`; bare IPs blocked; redirects blocked | Production |
| `http-allow-test-domains` | HTTPS to everything in `http-allow-azure-domains` **plus** `httpbingo.org` | E2E testing; implies `http-allow-azure-domains` |
| `http-allow-all` | HTTP and HTTPS to all URLs; SSRF IP blocklist and allow-list are both disabled | Local development only |

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
`validate_allowlist`.

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
and no other effective grant remains, the next execution attempt fails before
sending a request. Revocation does not cancel a request already in progress.

### 3.2 Mechanism

`execute_http` runs the following check before any network activity:

```sql
SELECT has_function_privilege($submitted_by::regrole,
    'df.http(text,text,text,jsonb,integer)'::regprocedure,
    'EXECUTE')
```

`has_function_privilege` honours PostgreSQL's standard privilege model:
superusers always return `true`; regular roles return `true` only when an
effective grant exists, whether direct, inherited from another role or granted
to `PUBLIC`.

Multipart activities perform the corresponding check on
`df.http_multipart(text,text,jsonb,jsonb,integer)`. Restricting one function does
not restrict the other.

`df.with_http_options(text,jsonb)` is a node modifier, not a network operation.
Like other combinators, it uses ordinary `df` schema access and default PUBLIC
`EXECUTE`. Wrapping a hand-crafted HTTP node does not bypass the activity's
privilege check. Supported keys are `secret_bindings` and `form_fields`, described
in [Explicit secret bindings](#37-explicit-secret-bindings). SQL `NULL` and `{}`
preserve the original node text.

### 3.3 Managing access

HTTP access is **opt-in** and separate from general `df` access.

#### Granting access

Use `df.grant_usage()` with `include_http => true` to grant both HTTP functions:

```sql
SELECT df.grant_usage('my_role', include_http => true);
```

Or grant directly:

```sql
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO my_role;
GRANT EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) TO my_role;
```

`df.grant_usage('my_role')` (without `include_http`) grants all standard `df`
privileges but does not grant either HTTP function. The helper is **additive**:
`include_http => false` does not revoke previously granted or inherited HTTP
access. Ordinary helpers retain PostgreSQL's default `PUBLIC EXECUTE`; schema
`USAGE` is their access gate. Sensitive functions are granted explicitly.

#### Revoking access

To remove HTTP access without removing all `df` access:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM my_role;
REVOKE EXECUTE ON FUNCTION df.http_multipart(text, text, jsonb, jsonb, integer) FROM my_role;
```

Once no effective HTTP grant remains, later execution attempts fail with a
privilege error. Other `df` functions remain accessible. Check for grants through
`PUBLIC` or inherited roles: revoking a direct grant does not remove those paths.

`df.revoke_usage('my_role')` also revokes standard `df` access and sensitive
function grants within the caller's grant authority. It does not erase
independent grants through `PUBLIC` or other roles.

#### PUBLIC grant and upgrades

Fresh installs (v0.2.0+) have `EXECUTE` on `df.http()` revoked from `PUBLIC`
at `CREATE EXTENSION` time.  Installs that upgraded from v0.1.1 **retain** the
PUBLIC grant that v0.1.1 issued — the upgrade script does not revoke it.

If an upgraded install should enforce opt-in HTTP permissions, the admin must
run manually:

```sql
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;
```

Calling `df.grant_usage(role, include_http => false)` does not revoke the legacy
grant or warn about residual access. Use `has_function_privilege` to check the
role's effective permissions after changing grants.

### 3.4 Admin function protection

`df.grant_usage()` and `df.revoke_usage()` are admin-only functions.
`EXECUTE` is revoked from `PUBLIC` at `CREATE EXTENSION` time, but administration
can be delegated. A role must have permission to call a helper, and its operations
are additionally constrained by PostgreSQL's native grant authority because the
helpers run as `SECURITY INVOKER`.

`df.grant_usage(..., with_grant => true)` grants privileges with `WITH GRANT
OPTION`, including execution of the grant/revoke helpers. Such a delegated admin
can grant only privileges it has authority to grant; execution permission alone
does not confer the extension owner's privileges.

`df.grant_usage` issues explicit schema, table and sensitive-function grants.
It does not use a blanket function grant followed by revocations. When granting
HTTP access, the caller must be able to grant both HTTP functions; otherwise the
call fails rather than silently skipping the HTTP grant.

### 3.5 Feature-flag interaction

The privilege check runs regardless of which HTTP Cargo feature is enabled.
When no HTTP feature is compiled in, the request is still blocked later by the
DSL-time guard and by execution-time URL validation, but the privilege check
remains compiled in and still runs before any network activity.

---

### 3.6 Endpoint requests

An endpoint reference does not grant authority. Normal and multipart activities
first check their existing HTTP function grant, then resolve the foreign server
and the submitting role's user mapping on a connection authenticated as that role.
Server `USAGE` is mandatory. Catalogs are in the control database selected by
`pg_durable.database`, regardless of the workflow's SQL target. Caller-supplied
database/identity fields in node JSON cannot select another credential catalog or
override the trusted submitting identity.

One request uses one read-only `REPEATABLE READ` snapshot for endpoint configuration
and all referenced mappings, including bindings from other servers. Catalog rows
are reused within the attempt, not cached across attempts. This prevents atomic
catalog updates from producing mixed destination/credential generations. The
caller connection acquires the same admission slot as SQL execution and is closed,
releasing the slot, before network I/O. Requests without catalog references open
no caller connection.

Server owners must be trusted with credentials sent through their endpoints:
changing a destination can redirect subsequent authenticated requests, even when
the owner's catalog view cannot reveal the caller's mapping values.

Path composition preserves the base URL's authority and path prefix. Traversal,
protocol-relative paths and encoded path separators are rejected after variable
substitution as well as at construction. The final URL, including any credential
query parameters, passes the same scheme, allow-list and DNS protections as a raw
URL. Endpoint requests cannot supply `Host`, duplicate a configured credential
header, or override credential query parameter names. Headers carrying resolved
credentials are added only after destination validation.

Only the server name and path template enter node configuration and recorded
request inputs. Resolved credentials stay within the activity. Request diagnostics
redact the composed URL; response echoes and response secrets remain outside that
guarantee. Request bodies are not scanned for secret markers. See
[Calling an Endpoint](../USER_GUIDE.md#calling-an-endpoint) for the API and catalog
requirements.

---

### 3.7 Explicit secret bindings

`df.secret(server, key)` returns a JSONB reference, not a value or an embeddable
marker. Only named header/query/form slots in `secret_bindings` interpret these
references. Ordinary request fields, literal `form_fields`, multipart bytes and
resolved strings are never searched for secret markers. Binding maps are trusted
workflow configuration, not untrusted payload data. Credential-bearing destinations
must also be trusted; a reference's server name selects the credential namespace,
not a restriction on which destination can receive it.

Activities validate field shapes, reject conflicts with ordinary fields and
endpoint authentication, and resolve each referenced server under `submitted_by`
in the request's control-database snapshot after destination policy checks.
Server `USAGE` and a caller-owned mapping are
required even for `auth_scheme 'none'`. Named values come only from individual
`"secret.<key>"` user-mapping options, not ambient identity, endpoint-authentication
options or server options. The prefix is a credential namespace, not an instruction
to interpret the value. Native `ADD`, `SET` and `DROP` update one credential
without rewriting unrelated options.

Header values are validated and marked sensitive. Query/form names and values
are form-urlencoded; query insertion cannot change the destination authority.
Form mode owns body framing/content type, rejects raw body/multipart combinations,
and leaves ordinary field values literal. Missing secrets fail without fallback
or values in error messages. Request URL diagnostics are redacted after secret
query insertion; response credentials remain outside this guarantee.

See [Explicit Secret Bindings](../USER_GUIDE.md#explicit-secret-bindings) for API
examples and deferred general-composition cases.

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

Restricted builds disable reqwest's system and environment proxy discovery.
An HTTP proxy resolves the destination itself, outside `SsrfSafeResolver`, so
inheriting `HTTP_PROXY`, `HTTPS_PROXY`, or platform proxy settings would bypass
the destination-IP check.

Only the single IP address that `reqwest` actually connects to is checked.  If
DNS returns multiple A/AAAA records, the others are not checked because they
are never used.  This is intentional, not a gap — checking unused addresses
would create false positives without any security benefit.

### 4.5 IP literals in URL

Bare IP literals in URLs (e.g. `http://169.254.169.254/...`) bypass DNS
entirely — `reqwest` connects directly without calling the resolver.
`validate_allowlist` blocks all bare IPs unconditionally, so these never
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

### 5.2 Exact-match domains (always present with `http-allow-azure-domains`)

Matched exactly — subdomains and lookalikes are rejected.

| Domain | Purpose |
|--------|---------|
| `api.github.com` | GitHub API |

### 5.3 Test domains (additional with `http-allow-test-domains`)

| Domain | Purpose |
|--------|---------|
| `httpbingo.org` | HTTP echo service (used in HTTP E2E tests) |

### 5.4 Bare IP rejection

All bare IPv4 and IPv6 addresses are rejected by `validate_allowlist`
regardless of feature flag — even under `http-allow-azure-domains`.
Because the allowlist blocks all bare IPs, there is no separate IP-literal
check; the allowlist is the definitive gate for IP-literal URLs.

### 5.4 One parse, one URL

The host judged by the allow-list is read from the `url::Url` that is then
handed to `reqwest`, never from the caller's string. Comparing a separately
parsed host against the allow-list would let the two parsers disagree: WHATWG
ends the authority of an `http(s)` URL at `\`, so in
`https://evil.example\@acct.blob.core.windows.net/` the host is
`evil.example` and the allow-listed name is merely path. A scan that read the
name after the last `@` would approve a request aimed elsewhere — and with an
IP literal in that position it would also clear the bare-IP rule, the only
gate for targets that skip DNS.

Judging the parsed host means the allow-list follows canonicalisation as
`reqwest` performs it: percent-encoded host characters are decoded,
non-dotted IPv4 notation (`http://2130706433/`) becomes an IP literal, and
internationalised names are compared in their Punycode form.

---

## 6. Additional Hardening

### 6.1 Scheme restriction

Restricted builds accept only `https://`. This prevents credentials and request
bodies from being transmitted over plaintext connections. Plaintext `http://`
is available only with the development-only `http-allow-all` feature.

All other schemes (`file://`, `ftp://`, `gopher://`, etc.) are rejected before
any DNS resolution or connection attempt. Scheme validation runs both when the
DSL node is created and when the canonical parsed URL is executed.

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
- `url` — the requested URL, **redacted** (see below)
- Block reason tag — `(scheme)`, `(allowlist)`, or `(ip)` in the log prefix

Resolved IP addresses are **not** included in error messages or logs to avoid
leaking internal network topology to potentially malicious users.

### 7.1 URL redaction

A URL is a credential carrier: an Azure SAS token lives entirely in the query
string, and `?api-key=` / `?code=` are common elsewhere. Worker request diagnostics
redact these values before logging URLs or including them in errors. The server
log has no RLS or `pg_durable.retention_days`, and frequently has a separate
shipping and backup path.

| Component | Treatment |
|-----------|-----------|
| Scheme, host, port, path | Preserved. The URL is reparsed, so a logged line may be normalized (host lowercased, default port dropped) relative to what the workflow supplied. |
| Query parameter *names* | Preserved except for ambiguous pairs below |
| Query parameter *values* | Replaced with `<redacted>` |
| Bare query tokens and pairs with empty or padding-only values | Replaced whole: `token`, `token=`, and `token==` can all be opaque credentials |
| `userinfo@` | Replaced with `<redacted>@`, keeping the host |
| Fragment | Replaced whole |
| Unparseable input | Replaced whole — redaction fails closed and never echoes back a string it could not parse |

Parsing uses the `url` crate, so IPv6 authorities, percent-encoding, default
ports and userinfo follow the spec rather than ad-hoc string splitting.

The HTTP client's attached request URL is removed before formatting its errors,
including response-body read failures. Explicitly reported request URLs are
redacted as above. This matters because failed nodes store their error in
`df.nodes.result` and durable execution history, not just in the log.

Do not put credentials in paths or parameter names: those can remain visible.
Request headers and bodies are not directly included in request traces, but an
endpoint can echo them in its response.

> **Not covered:** stored request inputs, response headers and response bodies.
> A workflow's final result is logged, and response-body previews appear in 5xx
> errors. A response containing a credential, including an echoed request URL or
> a token returned by an endpoint, can still expose it in logs and stored results.
> URL redaction does not make `df.vars` secret storage; see
> [Variables and secrets](../USER_GUIDE.md#variables-and-secrets).

---

## 8. Error Messages

| Scenario | Message |
|----------|---------|
| No EXECUTE privilege on df.http() | `Blocked: role '{role}' does not have EXECUTE privilege on df.http(). Grant EXECUTE ON FUNCTION df.http(text,text,text,jsonb,integer) TO {role} to allow HTTP requests.` |
| HTTP disabled (no feature) | `Blocked: outbound HTTP requests are disabled. Rebuild with the 'http-allow-azure-domains' Cargo feature to enable them.` |
| Plaintext HTTP in a restricted build | `Blocked: plaintext HTTP is not permitted in restricted builds. HTTPS is required.` |
| Unsupported scheme | `Blocked: unsupported URL scheme. Only {allowed} is allowed.` where `{allowed}` is `https` in restricted builds or `http and https` with `http-allow-all` |
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
