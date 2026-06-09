# pg_durable Security Model Specification

**Status**: Implementation in progress  
**Authors**: pg_durable Team  
**Created**: 2025-12-25  
**Last Updated**: 2026-03-11

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals and Non-Goals](#2-goals-and-non-goals)
3. [Threat Model](#3-threat-model)
4. [Functional Requirements](#4-functional-requirements)
5. [Securing df.sql()](#5-securing-dfsql)
6. [Securing df.http()](#6-securing-dfhttp)
    6.7 [Duroxide Background Worker Authentication/Authorization](#67-duroxide-background-worker-authenticationauthorization)
7. [Data Isolation (RLS)](#7-data-isolation-rls)
8. [Implementation Specification](#8-implementation-specification)
9. [User Experience](#9-user-experience)
10. [Test Specification](#10-test-specification)
11. [Open Questions](#11-open-questions)

---

## 1. Executive Summary

pg_durable executes user-submitted SQL durably via a background worker. This creates a security challenge: SQL submitted by User A should execute with User A's privileges, not with elevated background worker privileges.

For a detailed architectural overview of how function graphs are built and executed, please refer to the [Architecture Guide](ARCHITECTURE.md).

**Implemented approach**: The background worker opens a dedicated sqlx connection authenticated directly as `submitted_by` (`current_user` at `df.start()` time). User SQL executes on this per-user connection, inheriting standard PostgreSQL RBAC. Identity is captured at `df.start()` time via `GetUserId()` and stored in `df.instances` and `df.nodes`.

See [User Isolation: Design & Implementation Guide](user-isolation.md) for the full design rationale.

**Alternative considered (SPI + `SetUserIdAndSecContext`)**: An earlier draft of this spec proposed executing user SQL in-process via SPI with C-level security context switching. This would provide slightly stronger escape prevention (immune to `RESET ROLE` at the SQL level) and avoid the `pg_hba.conf` trust-auth requirement. However, the sqlx connection approach was chosen for simplicity, compatibility with the async duroxide runtime, and because it provides equivalent privilege isolation in practice. SPI remains a potential future optimization — see [Section 8.8](#88-spi-as-a-potential-future-optimization) for analysis.

### Key Security Properties

| Property | Guarantee |
|----------|-----------|
| Privilege Isolation | User SQL executes on a connection authenticated as the submitting user |
| Escape Prevention | `RESET ROLE` reverts to `submitted_by` (the authenticated connection identity) — no escalation possible |
| Audit Trail | All executions logged with original user identity (`submitted_by`) |
| Trusted Extension Model | Extension code is trusted; installed by superuser only |

### Security Boundary

**Important**: The pg_durable background worker connects to PostgreSQL as arbitrary users via sqlx, relying on `pg_hba.conf` trust (or peer) authentication for local connections. This is a **trusted code + trusted network** model:

- The extension can connect as ANY local PostgreSQL role (given permissive `pg_hba.conf`)
- Security relies on the extension code being correct and the `pg_hba.conf` configuration being appropriate
- The worker's ambient role (e.g., `duroxide_worker`) is used only for control-plane operations (loading graphs, updating status); user SQL runs on separate per-user connections
- This is similar to how `pg_cron` operates — trusted extension code with elevated capabilities

The security guarantee is: **only superusers can install the extension**, therefore the extension code is trusted.

---

## 2. Goals and Non-Goals

### Goals

1. **G1**: User SQL executes with the privileges of the user who called `df.start()`
2. **G2**: Users cannot escalate privileges through durable function execution
3. **G3**: SQL-level grants to the background worker role follow least privilege (while acknowledging the overall model is a trusted, SUPERUSER-installed extension)
4. **G4**: Clear audit trail of who submitted what
5. **G5**: Simple user experience - no complex grant management for basic use cases
6. **G6**: Compatible with Azure Flexible Server managed environment

### Non-Goals

- **NG1**: Supporting different users for different nodes within a single function graph
- **NG2**: Cross-database durable function execution
- **NG3**: Supporting untrusted extension installation (pg_durable remains SUPERUSER-install)
- **NG4**: Real-time privilege revocation (in-flight executions complete with original privileges)

---

## 3. Threat Model

### 3.1 Actors

| Actor | Trust Level | Capabilities |
|-------|-------------|--------------|
| **DBA/Admin** | Trusted | Installs extension, manages roles, full database access |
| **Application User** | Semi-trusted | Can call `df.*` functions, owns application tables |
| **Attacker** | Untrusted | Compromised application user, attempts privilege escalation |

### 3.2 Threats and Mitigations

#### Implementation Priority Summary

| Threat | Severity | Status | Notes |
|--------|----------|--------|-------|
| **T8**: SSRF via HTTP Activity | **CRITICAL** | Implemented | Dataplane protection — see [http-security.md](http-security.md) |
| **T4**: Information Disclosure via df.* Tables | **HIGH** | Implemented | RLS on `df.instances` and `df.nodes` — see [rls.md](rls.md) |
| **T9**: Unauthorized HTTP Access | **HIGH** | Not implemented | `REVOKE EXECUTE` + admin allowlist (future spec) |
| **T11**: Secret Exfiltration | **HIGH** | Not implemented | Additive feature; no table/API exists yet |
| **T10**: Cross-User Variable Injection | **MEDIUM-HIGH** | Implemented | Per-user `df.vars` scoping via `owner` column + RLS — see [rls.md](rls.md) |
| **T5**: Denial of Service | **MEDIUM** | Not implemented | Rate limiting; deferred |
| **T6**: Worker Code Vulnerability | **MEDIUM** | Mitigated by design | Relies on code review |
| **T0**: SECURITY DEFINER Misuse | **MEDIUM** | Documentation-only | Expected PG behavior |
| **T12**: SQL Injection in Internal SPI Queries | **CRITICAL** | **Implemented** | `df.status()` and `df.result()` now use parameterized SPI queries (`Spi::get_one_with_args`) |
| **T7**: Extension Trustworthiness | **LOW** | Accepted | Standard PG trust model |
| **T13**: `search_path` Manipulation in PL/pgSQL Helpers | **LOW** | Implemented | Helper function definitions set `search_path = pg_catalog, df, pg_temp` |
| **T14**: Extension Object Pre-creation | **LOW** | Accepted | Requires operator error; superuser-only install |
| **T1–T3**: Privilege Escalation | **CRITICAL** | Implemented | Per-user sqlx connections |

---

#### T0: SECURITY DEFINER Invocation Captures Definer Privileges

**Severity**: MEDIUM  |  **Status**: Documentation-only

**Threat**: Calling `df.start()` inside a `SECURITY DEFINER` function captures the definer’s identity (because `GetUserId()`/`current_user` reflect the definer inside the function). Unprivileged callers could cause durable work to run with the definer’s privileges.

**Mitigation (documentation-only)**: This is expected PostgreSQL behavior. The extension does **not** block this pattern. Operators must avoid invoking `df.start()` from `SECURITY DEFINER` unless they explicitly want definer-level execution. Document clearly and, if possible, emit audit logs when df is invoked from SECURITY DEFINER.

**Residual Risk**: High if misused. Safe if used intentionally and documented.

#### T1: Privilege Escalation via RESET ROLE

**Severity**: CRITICAL  |  **Status**: Implemented

**Threat**: User submits SQL containing `RESET ROLE` to escape back to worker's identity.

```sql
-- Malicious durable function
SELECT df.start(
    df.sql('RESET ROLE; DROP TABLE other_users_data;'),
    'attack'
);
```

**Mitigation (implemented)**: User SQL runs on a dedicated sqlx connection authenticated as `submitted_by` (the user's identity at `df.start()` time). `RESET ROLE` on this connection resets the effective role back to `submitted_by` — which is still the user's own authenticated identity. The connection never has the background worker's elevated privileges, so there is nothing to escape to.

**Residual Risk**: None — the connection is authenticated as the user, not the worker.

---

#### T2: Privilege Escalation via SET ROLE

**Severity**: CRITICAL  |  **Status**: Implemented

**Threat**: User attempts to assume a more privileged role.

```sql
SELECT df.start(
    df.sql('SET ROLE postgres; SELECT * FROM pg_shadow;'),
    'attack'
);
```

**Mitigation (implemented)**: The sqlx connection is authenticated as `submitted_by`. Any `SET ROLE` by user SQL requires role membership, checked against `submitted_by`. `SET ROLE postgres` fails unless `submitted_by` is a member of `postgres`. This is standard PostgreSQL RBAC enforced at the connection level.

**Residual Risk**: None — standard PostgreSQL RBAC applies.

---

#### T3: Privilege Escalation via Dynamic SQL

**Severity**: CRITICAL  |  **Status**: Implemented

**Threat**: User obfuscates malicious commands.

```sql
SELECT df.start(
    df.sql($$ DO $x$ BEGIN EXECUTE 'RES' || 'ET ROLE'; END $x$ $$),
    'attack'
);
```

**Mitigation (implemented)**: Dynamic SQL runs on the same sqlx connection, which is authenticated as the user's `submitted_by` role. The connection's authenticated identity cannot be changed by any SQL command — `RESET ROLE` only reverts to `submitted_by` (the user's own identity), and `SET ROLE` requires membership.

**Residual Risk**: None.

---

#### T4: Information Disclosure via df.* Tables

**Severity**: HIGH  |  **Status**: Implemented

**Threat**: User queries `df.instances` or `df.nodes` to see other users' durable functions.

**Mitigation (implemented)**: RLS policies on `df.instances` and `df.nodes` enforce per-user visibility using `submitted_by = current_user::regrole`. Auto-grants provide SELECT+INSERT on both tables and column-level `UPDATE (status, updated_at)` on instances (no DELETE). Ownership checks in `df.cancel()` and `df.signal()` prevent cross-user operations via the duroxide client. Monitoring functions (`df.list_instances()`, `df.instance_info()`, etc.) also enforce ownership.

See [rls.md](rls.md) for the full design, policy definitions, grant strategy, and decisions.

**Residual Risk**: Low — RLS is a well-tested PostgreSQL feature.

---

#### T5: Denial of Service via Resource Exhaustion

**Severity**: MEDIUM  |  **Status**: Not implemented (deferred)

**Threat**: User creates many long-running durable functions to exhaust worker capacity.

**Mitigation**: 
- Rate limiting via `df.max_concurrent_per_user` GUC
- Timeout enforcement via `df.execution_timeout`
- Queue depth limits

**Residual Risk**: Medium - requires monitoring; out of scope for initial implementation.

---

#### T6: Background Worker Code Vulnerability

**Severity**: MEDIUM  |  **Status**: Mitigated by design

**Threat**: Bug in extension code allows attacker to control which user the worker connects as.

**Attack Vector**: If `submitted_by` values used by `connect_as_user()` are derived from user-controlled data, an attacker could forge them to connect as a different user.

**Mitigation (implemented)**:
- `submitted_by` is captured via `GetUserId()` at `df.start()` time in the user's backend process
- It is stored as `REGROLE` in `df.instances` and propagated to `df.nodes` — users cannot write to these columns directly (they are set by the extension's Rust code via SPI during `df.start()`)
- Worker reads role names from `df.nodes` when loading the function graph, and passes them to the `execute_sql` activity
- Code review checklist: verify role name provenance in all paths

**Residual Risk**: Medium — relies on correct implementation. Code review critical.

---

#### T7: Extension Code Trustworthiness

**Severity**: LOW (accepted)  |  **Status**: N/A — inherent to PG extension model

**Threat**: Malicious or buggy extension code abuses its ability to connect as any user.

**Context**: PG's extension architecture has a full trust model - extension code must be safe and correct. Any extension can call C functions, which is stronger than "connect as any user".

**Mitigation**:
- Extension requires superuser to install (`CREATE EXTENSION pg_durable`)
- `pg_hba.conf` must be configured to allow the worker's local connections (trust or peer auth)
- Code is open source and auditable
- Standard trusted extension model (same as pg_cron, postgis, etc.)

**Residual Risk**: Accepted — this is the PostgreSQL trusted extension model. If you install the extension, you trust the code.

---

#### T8: Server-Side Request Forgery (SSRF) via HTTP Activity

**Severity**: CRITICAL  |  **Status**: Implemented

**Threat**: Attacker uses `df.http()` to access internal network services, cloud metadata endpoints, or localhost services from within the PostgreSQL VM. In a PG-as-a-service deployment, this is a dataplane escape.

**Mitigation (implemented)**: Compile-time IP blocklist that blocks all private/reserved IP ranges, with DNS rebinding protection and IPv4-mapped IPv6 handling. The blocklist is hardcoded and cannot be bypassed by any database user, including superusers, for pg_durable's built-in `df.http()` activity path. It does not restrict arbitrary SQL functions, user-defined functions, or third-party Postgres extensions that SQL nodes are permitted to execute.

See [http-security.md](http-security.md) for the full specification, blocked IP ranges, and implementation details.

**Residual Risk**: Low for `df.http()` — hardcoded blocklist cannot be bypassed in that path.

---

#### T9: Unauthorized HTTP Access

**Severity**: HIGH  |  **Status**: Partially implemented

**Threat**: User abuses `df.http()` to access external resources they shouldn't (exfiltrate data, attack external services).

**Mitigation**:
- `df.http()` has `EXECUTE` revoked from `PUBLIC` on fresh installs
- DBA grants HTTP access explicitly, either with `df.grant_usage(role, include_http => true)` or a direct `GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer)`
- The worker re-checks `EXECUTE` at execution time to block raw `df.start()` JSON injection
- Audit logging records HTTP attempts

**Future enhancements**:
- Per-customer or per-role destination controls beyond the current feature-gated allowlist
- Rate limiting

**Residual Risk**: Medium until customer-level controls are implemented. T8 (SSRF/dataplane) protection is independent and addressed first.

---

#### T10: Cross-User Variable Injection via df.vars

**Severity**: MEDIUM-HIGH  |  **Status**: Implemented

**Threat**: `df.vars` is a key-value table. Without per-user scoping, users can override or read each other's variables, potentially redirecting workflows.

**Mitigation (implemented)**: `df.vars` has an `owner REGROLE` column with `DEFAULT current_user::regrole` and a composite primary key `(owner, name)`. RLS policy `vars_user_isolation` restricts each user to their own variables. `df.setvar()` scopes ownership via the column DEFAULT and `ON CONFLICT (owner, name)`; read/delete functions (`df.getvar()`, `df.unsetvar()`, `df.clearvars()`) and `df.start()` vars capture use explicit `WHERE owner = current_user::regrole` filters. This ensures correct scoping even for superusers who bypass RLS. See [rls.md, Decision 5](rls.md).

**Residual Risk**: Low — per-user scoping is enforced at both the RLS and application layers.

---

#### T11: Secret Exfiltration via df.secrets

**Severity**: HIGH  |  **Status**: Not implemented (additive feature)

**Threat**: `df.secrets` are intended to be admin-managed values (API keys, shared tokens) that workflows can use without hard-coding secrets into graphs. If secrets are directly readable by all users, they are not secrets. Without this feature, users must embed credentials directly in function graphs, where they are stored in `df.nodes` and potentially visible in logs.

**Mitigation**:
- Secrets MUST NOT be directly selectable by non-admin users
- Secrets MUST NOT be returned in results or error strings
- Secrets should be resolved only inside the worker execution path and substituted into SQL/HTTP requests at execution time

**Residual Risk**: Medium (by design secrets are high-impact); mitigated by least-privilege, auditing, and never exposing plaintext to users.

---

#### T12: SQL Injection in Internal SPI Queries

**Severity**: CRITICAL  |  **Status**: Implemented

**Threat**: Two extension functions (`df.status()` and `df.result()`) previously interpolated user-supplied `instance_id` directly into SQL without escaping single quotes. That allowed SQL injection to bypass RLS and read other users' instance data.

```sql
-- Attack: bypass RLS to read any user's instance status
SELECT df.status('x'' OR 1=1--');

-- Attack: read results from other users' workflows
SELECT df.result('x'' UNION SELECT secret FROM admin_table--');
```

**Current mitigation** (`src/dsl.rs`):
```rust
// df.status() — parameterized SPI query
let status: Option<String> = Spi::get_one_with_args(
    "SELECT status FROM df.instances WHERE id = $1",
    &[instance_id.into_datum()],
)
.expect("SPI query failed");

// df.result() — parameterized SPI query
let result: Option<String> = Spi::get_one_with_args(
    "SELECT result::text FROM df.nodes\n     WHERE id = (SELECT root_node FROM df.instances WHERE id = $1)\n       AND status = 'completed'",
    &[instance_id.into_datum()],
)
.expect("SPI query failed");
```

**Fix implemented**: Replaced string interpolation with parameterized SPI in `df.status()` and `df.result()` using `Spi::get_one_with_args()`. This removes quote-escaping as a correctness requirement for these call sites. Other internal SPI queries should also prefer parameterization wherever supported; manual escaping is fallback-only for cases where parameters are not available.

**Note on variable substitution**: The `substitute_all_with_options()` function in `src/types.rs` inserts user variables (`{name}`) as-is into SQL without quoting. This is **by design** — variables are intended to be SQL fragments (e.g., table names, expressions). Users choose what to put in their own variables, and the SQL executes with their own privileges on a per-user connection. This is analogous to `psql` variable substitution (`:name`). Result substitution (`$name`) does properly quote string values.

**Residual Risk**: Low. Remaining hardening is to continue migrating any remaining string-formatted SPI lookups to parameterized calls where possible.

See this section and Appendix A checklist for ongoing SPI query hardening work.

---

#### T13: `search_path` Manipulation in PL/pgSQL Helper Functions

**Severity**: LOW  |  **Status**: Implemented

**Threat**: The extension's PL/pgSQL helper functions (`df.if_then_op()`, `df.if_else_op()`, `df.ensure_durofut()`) and SQL wrapper functions (`df.as_op()`, `df.loop_prefix_op()`) do not set a fixed `search_path`. If an attacker can place a malicious function in a schema that appears earlier in `search_path`, they could shadow a built-in or extension function.

**Mitigations (implemented)**:
- All function calls within the helpers are already schema-qualified: `df.ensure_durofut()`, `df.sql()`, `df.if()`, `df.loop()`, `df.as()`
- Built-in functions used (`jsonb_build_object`) are in `pg_catalog`, which is always implicitly first in `search_path`
- The functions are created in the `df` schema (owned by superuser)
- The extension requires superuser to install
- Helper definitions in both fresh install SQL and upgrade SQL include `SET search_path = pg_catalog, df, pg_temp`

**Fix implemented**: Added `SET search_path = pg_catalog, df, pg_temp` to the helper function definitions (`df.if_then_op()`, `df.if_else_op()`, `df.ensure_durofut()`, `df.as_op()`, `df.loop_prefix_op()`) in both install and upgrade paths.

**Residual Risk**: Low — current references are schema-qualified and helper search path is pinned as defense-in-depth.

---

#### T14: Extension Object Pre-creation Attack

**Severity**: LOW  |  **Status**: Accepted risk

**Threat**: The extension uses `CREATE TABLE IF NOT EXISTS` and `CREATE OR REPLACE FUNCTION` patterns. An attacker could pre-create objects with the same names to retain ownership or inject malicious implementations.

**Why this is low risk**:
- All DDL runs inside `extension_sql!()` blocks during `CREATE EXTENSION`, which requires superuser
- The `df` schema is created by pgrx during extension installation — it doesn't exist beforehand
- The `duroxide` schema is created by `sql/duroxide_install.sql` with `SET LOCAL search_path TO duroxide`
- An attacker would need `CREATE TABLE` privilege in a schema controlled by the extension before the extension is installed — this requires the superuser to have manually created the schema and granted access (operator error)
- The `CREATE OR REPLACE FUNCTION` for PL/pgSQL helpers is a standard pgrx convention; the `#[pg_extern]` macro also generates `CREATE OR REPLACE`

**Residual Risk**: Low — requires operator error (manually creating `df` schema and granting usage before installing the extension).

---

## 4. Functional Requirements

### 4.1 Overall Security Requirements

pg_durable follows PostgreSQL's native security patterns wherever possible:

| Mechanism | PostgreSQL Native | pg_durable Usage |
|-----------|-------------------|------------------|
| **Function access** | `GRANT/REVOKE EXECUTE` | Control who can use `df.sql()`, `df.http()`, etc. |
| **Data isolation** | Row-Level Security (RLS) | Users see only their own instances |
| **Configuration** | GUCs (`ALTER SYSTEM SET`) | HTTP allowlists, rate limits, timeouts |
| **Role membership** | `GRANT role TO user` | No custom roles; use standard PostgreSQL |
| **Audit** | PostgreSQL logging | Log with effective user identity |

**Design Principle**: Follow the pg_cron model — use RLS for data isolation, standard function permissions for access control, and GUCs for system-wide settings. No custom permission tables or roles.

---

### 4.2 Security by Activity Type

| Activity | Permission Model | Additional Controls |
|----------|-----------------|---------------------|
| `df.sql()` | PostgreSQL RBAC via per-user sqlx connection | None needed — native |
| `df.http()` | `GRANT EXECUTE` on function | SSRF blocking, URL allowlist GUC |
| `df.start()` | `GRANT EXECUTE` on function | RLS on `df.instances` |
| Future activities | `GRANT EXECUTE` on function | Activity-specific GUCs |

---

### 4.3 Workflow Variables (df.vars)

pg_durable supports workflow variables via `df.setvar()/df.getvar()/df.unsetvar()/df.clearvars()`. Variables are captured at `df.start()` time and passed into the orchestration as an immutable `vars` map.

**Security requirement**: Variables MUST NOT be global, cross-user state.

**Current status**: Implemented. `df.vars` has per-user scoping via an `owner REGROLE` column with RLS. Each user has their own variable namespace. Variables are captured at `df.start()` time from the calling user's namespace only. See [rls.md, Decision 5](rls.md).

---

### 4.4 Shared Secrets (df.secrets)

pg_durable supports shared secrets for workflows.

**Intent**: Provide admin-managed secrets (API keys, bearer tokens, shared credentials) that workflows can reference without embedding secrets in the function graph.

**Key security property**: Secrets are **usable** by workflows but are **not directly readable** by non-admin users.

**API surface (proposed)**:
- `df.setsecret(name text, value text)` (admin-only)
- `df.unsetsecret(name text)` (admin-only)
- `df.clearsecrets()` (admin-only)
- No general-purpose `df.getsecret()` for non-admins

**How users consume secrets**:
- Secrets are referenced by name inside node queries/config and resolved by the worker at execution time.
- Example placeholder (conceptual): `${secret:stripe_api_key}`.

**Permissions**:
- Only admins are granted `EXECUTE` on secret mutators (`df.setsecret`, `df.unsetsecret`, `df.clearsecrets`).
- Non-admins should not have `SELECT` on `df.secrets`.
- The worker (trusted code) may read `df.secrets` to perform substitution.

**Audit**:
- Log secret *name* usage for traceability (never log values).

**Scenarios that this enables**:
- Any user granted `EXECUTE` on `df.http(text, text, text, jsonb, integer)` can run a workflow that calls `df.http()` to an allowed host and uses an Authorization header populated from `df.secrets`.
- Any user can run a workflow that queries an external FDW/API gateway where the credential is provided by the worker.

---

## 5. Securing df.sql()

### 5.1 Overview

SQL execution is the core activity. It uses PostgreSQL's native permission system via dedicated per-user sqlx connections.

```
┌─────────────────────────────────────────────────────────────────┐
│  df.sql() Security Model (Implemented)                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  User calls: df.start(df.sql('SELECT * FROM my_table'), ...)   │
│                                                                 │
│  1. df.start() captures:                                       │
│     • GetUserId() → submitted_by (current_user)                │
│     • Stored as REGROLE in df.instances and df.nodes            │
│                                                                 │
│  2. Background worker executes:                                │
│     • connect_as_user(submitted_by) via sqlx                   │
│       → Authenticates TCP connection as submitted_by           │
│       → SET df.in_workflow = 'true' (guard variable mutations) │
│     • sqlx::query(user_sql) ← runs with user's privileges     │
│     • Connection dropped after execution                       │
│                                                                 │
│  3. PostgreSQL permission checks:                              │
│     • All ACL checks use the connection's effective role        │
│     • RLS policies evaluate against the connected user         │
│     • pg_stat_activity shows the user's identity               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Permission Model

**No additional permissions needed** — PostgreSQL's native RBAC applies:

```sql
-- User A owns their table
CREATE TABLE user_a.my_data (id int, secret text);

-- User A can query it in a durable function
SELECT df.start(df.sql('SELECT * FROM user_a.my_data'), 'my-job');
-- ✓ Succeeds: runs as user_a, who owns the table

-- User B tries to access user_a's table
SET ROLE user_b;
SELECT df.start(df.sql('SELECT * FROM user_a.my_data'), 'steal-data');
-- ✗ Fails: runs as user_b, who has no access
```

### 5.3 Escape Prevention

| Attack | Why It Fails |
|--------|--------------|
| `RESET ROLE` | Reverts to `submitted_by` — still the user's own identity, not the worker's |
| `SET ROLE postgres` | Requires membership in `postgres`; checked against `submitted_by` |
| `EXECUTE 'RESET ROLE'` | Dynamic SQL runs on the same connection — same identity constraints |
| `SELECT my_escape_func()` | Function runs on the same connection — same identity constraints |

### 5.4 Implementation

See [Section 8: Implementation Specification](#8-implementation-specification) for full code.

---

## 6. Securing df.http()

### 6.1 Overview

HTTP requests are guarded by PostgreSQL function privileges plus runtime SSRF defenses. In the current implementation, security is enforced via:

1. **Function-level permission**: `GRANT/REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer)`
2. **Execution-time privilege re-check**: the worker validates that `submitted_by` still has `EXECUTE` before any network activity
3. **SSRF protection**: Block internal IPs at the code level
4. **Compile-time endpoint allowlist**: allowed destinations depend on the HTTP Cargo feature
5. **Redirect handling**: redirects are disabled

```
┌─────────────────────────────────────────────────────────────────┐
│  df.http() Security Model                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Layer 1: Function Permission (PostgreSQL native)              │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ REVOKE EXECUTE ON FUNCTION df.http(text, text, text,      │ │
│  │     jsonb, integer) FROM PUBLIC;                          │ │
│  │ SELECT df.grant_usage('api_users', include_http => true); │ │
│  │ -- or GRANT EXECUTE ON FUNCTION df.http(text, text, text, │ │
│  │ --     jsonb, integer) TO api_users;                      │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  Layer 2: Execution-Time Privilege Check                       │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ submitted_by must still have EXECUTE on df.http(...)      │ │
│  │ Blocks raw df.start() JSON injection bypasses             │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  Layer 3: SSRF Protection + Feature Allowlist                  │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ Block: private/link-local/loopback ranges                │ │
│  │ Allow only feature-approved hostnames                    │ │
│  │ No redirects                                              │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Permission Model

**Function-level access control** (PostgreSQL native):

```sql
-- Fresh installs: HTTP disabled by default
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;

-- DBA enables HTTP for specific roles
SELECT df.grant_usage('etl_service', include_http => true);
SELECT df.grant_usage('webhook_handler', include_http => true);

-- Regular app users cannot use HTTP
SET ROLE app_user;
SELECT df.start(df.http('https://example.com', 'GET'), 'test');
-- ERROR: permission denied for function df.http
```

### 6.3 GUC Configuration

The current implementation does not expose HTTP allowlists or rate limits via
GUCs. Allowed destinations are compiled in through Cargo features and the
execution-time permission model is documented in [http-security.md](http-security.md).

### 6.4 SSRF Protection

SSRF protection is implemented as a compile-time IP blocklist that blocks all private/reserved IP ranges (RFC 1918, link-local, loopback, IPv6 ULA, etc.), with DNS rebinding protection and IPv4-mapped IPv6 handling.

See [http-security.md](http-security.md) for the full specification including blocked ranges, implementation architecture, and testing.

### 6.5 Implementation

See [http-security.md](http-security.md) for the implemented privilege check,
SSRF protections, and feature-gated hostname allowlist.

### 6.6 User Experience

```sql
-- DBA setup (one-time)
SELECT df.grant_usage('etl_service', include_http => true);

-- User with permission
SET ROLE etl_service;
SELECT df.start(
    df.http('https://api.company.com/webhook', 'POST', '{"event": "done"}'),
    'notify-completion'
);
-- ✓ Succeeds

-- User without permission
SET ROLE app_user;
SELECT df.start(
    df.http('https://api.company.com/data', 'GET'),
    'fetch-data'
);
-- ✗ ERROR: permission denied for function df.http

-- SSRF attempt (even with permission)
SET ROLE etl_service;
SELECT df.start(
    df.http('http://169.254.169.254/latest/meta-data/', 'GET'),
    'ssrf-attempt'
);
-- ✗ ERROR: HTTP request blocked: resolves to internal IP
```

### 6.7 Duroxide Background Worker Authentication/Authorization

**Purpose**: Keep the background worker’s control-plane connections passwordless while constraining what the worker can do when it is *not* running `execute_sql` on behalf of a user.

- **Auth (peer over Unix socket + pg_ident mapping)**: Use a Unix socket host and `peer` auth to map the OS user `postgres` → a low-privilege DB role (e.g., `duroxide_worker`). Example:
    - `pg_hba.conf`: `local  postgres  duroxide_worker  peer  map=duroxide_map`
    - `pg_ident.conf`: `duroxide_map  postgres  duroxide_worker`
    - Connection string (sqlx/duroxide store): `postgresql://duroxide_worker@/postgres?host=/var/run/postgresql`
    - Rationale: passwordless, auditable, and scoped to local socket; avoids `trust` on TCP.

- **AuthZ (limit ambient role)**: Grant the worker role only what the control-plane needs:
    - `GRANT USAGE ON SCHEMA df, duroxide TO duroxide_worker;`
    - `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA df, duroxide TO duroxide_worker;`
    - `REVOKE ALL ON SCHEMA public FROM duroxide_worker;` (and avoid grants in other schemas)
    - Future tables: ensure default privileges in those schemas keep the role scoped to df.* and duroxide.

- **Privilege boundary vs execute_sql (implemented)**: The `execute_sql` activity opens a **separate sqlx connection** authenticated as `submitted_by` (the user's `current_user` at `df.start()` time). This connection is completely independent of the worker's control-plane connection. All other worker SQL (loading graphs, updating status) runs on the worker's own pooled connection as the low-privilege `duroxide_worker` role.

- **pg_hba.conf requirement for per-user connections**: The `execute_sql` activity connects as arbitrary users via TCP. This requires `pg_hba.conf` to allow trust (or peer) auth for local connections. In development with pgrx (TCP), the typical configuration is:
    ```
    host    all   all   127.0.0.1/32   trust
    ```

- **Safety notes**:
    - For control-plane connections, prefer socket path (not `127.0.0.1`) for `peer` to apply.
    - This model still assumes trusted extension code; the worker can connect as any user for `execute_sql`, but only that activity should do so.
    - If sockets/`peer` are unavailable (managed services), fall back to client cert or AAD/Managed Identity as a "passwordless" token, while keeping the DB role scoped to df.* + duroxide.

---

## 7. Data Isolation (RLS)

**Status**: Implemented

RLS on `df.instances` and `df.nodes` enforces per-user data isolation. The extension does not grant privileges to PUBLIC — admins must explicitly grant appropriate permissions (schema usage, function execution, table DML) to application roles. The background worker bypasses RLS as a superuser.

See [rls.md](rls.md) for the full design including:
- RLS policy definitions and rationale
- Grant strategy (column-level UPDATE, no DELETE)
- Ownership checks in `df.cancel()`, `df.signal()`, and monitoring functions
- Worker bypass strategy
- Deferred `df.vars` scoping (Phase 2)

---

## 8. Implementation Specification

### 8.1 Schema Changes

#### df.instances Table Updates

```sql
-- df.instances (implemented)
-- submitted_by is created as part of the table definition in src/lib.rs
-- submitted_by: REGROLE NOT NULL — effective role (current_user) when df.start() was called

-- df.nodes (implemented)
-- submitted_by: REGROLE — nullable, set when node is linked to an instance by df.start()
```

**Note on earlier draft**: An earlier version of this spec proposed `submitted_by OID` and a `security_context JSONB` column. The implemented design uses `REGROLE` (which stores OIDs but displays as role names) and the current v0.2.0 line tracks a single `submitted_by` column. The released v0.1.1 schema also carried a second column, `login_role`, for the session user identity; the v0.2.0 work removes that column and simplifies the model. See [user-isolation.md](user-isolation.md) for the full design and upgrade caveats.

#### df.vars Table Updates (per-user scoping) — Deferred

Per-user scoping of `df.vars` (adding an `owner` column + RLS) is deferred to a follow-up PR. See [rls.md, Decision 5](rls.md) for the design.

#### df.secrets Table (admin-managed, workflow-usable)

`df.secrets` stores shared secrets that are referenced by workflows but not directly readable by non-admins.

```sql
CREATE TABLE IF NOT EXISTS df.secrets (
    name  TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by REGROLE NOT NULL DEFAULT current_user::regrole
);

-- Permissions
REVOKE ALL ON TABLE df.secrets FROM PUBLIC;
-- Only the worker and admins can read to perform substitution
GRANT SELECT ON TABLE df.secrets TO duroxide;
-- Secret mutators are admin-only
REVOKE EXECUTE ON FUNCTION df.setsecret(name text, value text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.unsetsecret(name text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION df.clearsecrets() FROM PUBLIC;
```

Additional requirements:
- Secrets must never be returned in results, status, or logs (only secret *names* may be logged for audit).
- If secrets are stored in plaintext, storage must be restricted to trusted roles as above; encrypt-at-rest may be added later but is not assumed by this spec.
- Secret substitution occurs inside the worker; users cannot `SELECT` `df.secrets`.

### 8.2 Function Permissions (Extension Installation)

```sql
-- Called during CREATE EXTENSION pg_durable

-- Default: all df functions require explicit grant
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA df FROM PUBLIC;

-- df.sql() - available to anyone who can use df.start()
-- (actual SQL permission checked via per-user sqlx connection)

-- df.http() - disabled by default, DBA enables per-role
REVOKE EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) FROM PUBLIC;

-- Convenience helper: grant standard df usage, excluding df.http() unless
-- include_http => true is passed.
-- Example: SELECT df.grant_usage('app_role', include_http => true);

-- df.start(), df.status() - grant to users who need durable functions
-- DBA grants these: GRANT EXECUTE ON FUNCTION df.start TO app_role;

-- df.vars - normal users may set/get their own variables (enforced by RLS)
-- df.secrets - admin-only mutators; no generic getter for non-admins
```

### 8.3 Earlier GUC Proposal (Not Implemented)

The following GUC definitions were part of an earlier proposal. The current
implementation uses Cargo features plus the execution-time privilege check
described in `docs/http-security.md`, not runtime HTTP GUCs.

```rust
// src/lib.rs

// HTTP activity controls
GucRegistry::define_string_guc(
    "df.http_allowed_hosts",
    "Comma-separated list of allowed host patterns for df.http()",
    "",  // default: empty = no hosts allowed
    GucContext::Suset,
);

GucRegistry::define_bool_guc(
    "df.http_block_internal_ips", 
    "Block HTTP requests to private/internal IP ranges (SSRF protection)",
    true,  // default: enabled
    GucContext::Suset,
);

GucRegistry::define_int_guc(
    "df.http_timeout_seconds",
    "Timeout for HTTP requests in seconds",
    30,
    1,
    300,
    GucContext::Suset,
);

GucRegistry::define_int_guc(
    "df.http_rate_limit_per_minute",
    "Maximum HTTP requests per user per minute",
    60,
    1,
    1000,
    GucContext::Suset,
);
```

### 8.4 Identity Capture (Implemented)

Identity is captured at `df.start()` time in the user's backend process. DSL functions (`df.sql()`, `df.seq()`, etc.) do **not** capture identity — nodes are created without `submitted_by`, which remains NULL until linked to an instance.

```rust
// src/dsl.rs — inside df.start()

// Capture current_user identity directly from PostgreSQL (no SPI needed)
let current_user_oid = unsafe { pgrx::pg_sys::GetUserId() };      // submitted_by

// OID is stored as REGROLE in the instance and node rows:
//   INSERT INTO df.instances (..., submitted_by)
//   VALUES (..., {current_user_oid}::oid::regrole)
```

**Why `GetUserId()` (i.e., `current_user`)**: This captures the effective user at `df.start()` time. Inside a `SECURITY DEFINER` function, this will be the definer's identity — which is the expected behavior for the simplified model. The user who has `current_user` privileges at call time is the identity used for SQL execution. See [user-isolation.md](user-isolation.md) for the full design.

### 8.5 Secure SQL Execution (Implemented)

User SQL is executed on a **dedicated sqlx connection** authenticated as the submitting user, not via SPI:

```rust
// src/types.rs — connect_as_user()

pub async fn connect_as_user(
    user: &str,
    database: Option<&str>,
) -> Result<sqlx::postgres::PgConnection, String> {
    let mut options = PgConnectOptions::new()
        .username(user)              // Authenticate as submitted_by
        .database(db)
        .port(get_port());

    let mut conn = PgConnection::connect_with(&options).await?;

    // Mark connection as running inside a workflow (prevents variable mutations)
    sqlx::query("SET df.in_workflow = 'true'")
        .execute(&mut conn)
        .await?;

    Ok(conn)
}
```

```rust
// src/activities/execute_sql.rs

#[derive(Serialize, Deserialize)]
struct ExecuteSqlInput {
    pub query: String,
    pub submitted_by: String,       // User identity (current_user at df.start() time)
    pub database: Option<String>,   // Target database
}

pub async fn execute(
    ctx: ActivityContext,
    _pool: Arc<PgPool>,             // shared pool — not used for user SQL
    input_json: String,
) -> Result<String, String> {
    let input: ExecuteSqlInput = serde_json::from_str(&input_json)?;

    // Open a per-user connection (NOT the worker's shared pool)
    let mut conn = connect_as_user(
        &input.submitted_by,
        input.database.as_deref(),
    ).await?;

    // Execute user SQL on the per-user connection
    let result = sqlx::query(&input.query)
        .fetch_all(&mut conn)
        .await?;

    // conn is dropped here — connection closed
    Ok(/* serialized result */)
}
```

**Key properties of the implemented approach**:
- User SQL runs on a connection authenticated as the user — never on the worker's shared pool
- `RESET ROLE` reverts to `submitted_by` (the user's own identity) — no escalation possible
- Each SQL node gets a fresh connection (future optimization: per-instance connection caching)
- `SET df.in_workflow = 'true'` prevents variable mutations (`setvar`/`unsetvar`/`clearvars`) during workflow execution. Note: it does not currently prevent recursive `df.start()` calls — that is a potential future improvement

### 8.6 Orchestration Wiring (Implemented)

The orchestration packages the query and both identities together before scheduling the activity:

```rust
// src/orchestrations/execute_function_graph.rs

let input = serde_json::json!({
    "query": final_query,
    "submitted_by": node.submitted_by,
    "database": node.database,
});

let result = ctx
    .schedule_activity(activities::execute_sql::NAME, input.to_string())
    .into_activity()
    .await?;
```

Both values come from the `FunctionNode` loaded via the `load_function_graph` activity. They are stable across replays (safe for determinism).

### 8.7 Fault Injection Hooks (Test-Only)

To validate crash/panic behavior and restart semantics, pg_durable should include a **test-only fault injection mechanism** that can deterministically trigger failures inside `execute_sql`.

**Mechanism (proposed)**:
- A superuser-only GUC such as `df.test_fault_inject = 'none'|'execute_sql_error'|'execute_sql_panic_before'|'execute_sql_panic_after_connect'`.
- The worker checks this setting at runtime and triggers the configured fault.
- This GUC MUST NOT be enabled by default and should be documented as test-only.

### 8.8 SPI as a Potential Future Optimization

The current implementation executes user SQL via external sqlx connections. An alternative approach — executing via SPI with `SetUserIdAndSecContext()` — was considered during design and remains a potential future optimization.

#### What SPI + SetUserIdAndSecContext would provide

| Benefit | Description |
|---------|-------------|
| **Stronger escape prevention** | `SetUserIdAndSecContext()` operates at the C level. SQL commands like `RESET ROLE` only affect the session-level role, not the C-level security context. With the sqlx approach, `RESET ROLE` reverts to `submitted_by` — which is still the user's identity (no escalation), but the effective role does change. |
| **No pg_hba.conf dependency** | SPI runs in-process; no TCP connection is needed for user SQL. The current approach requires `pg_hba.conf` trust auth so the worker process can connect as arbitrary users. |
| **Lower connection overhead** | SPI avoids TCP connection setup/teardown per SQL node. This could matter for workflows with many SQL nodes. |
| **Atomic with worker transaction** | SPI shares the worker's transaction context, which could simplify certain consistency scenarios. |

#### Why the sqlx approach was chosen

| Reason | Description |
|--------|-------------|
| **Async compatibility** | SPI is synchronous and has thread-affinity requirements. The duroxide runtime is async (tokio). Mixing SPI into an async context requires careful locking and prevents concurrent SQL execution across different instances. The sqlx approach naturally composes with async. |
| **Concurrency** | With SPI, only one SQL query can execute at a time per background worker (global SPI lock + single backend thread). With sqlx, multiple SQL nodes from different instances could execute concurrently on separate connections. |
| **Simplicity** | The sqlx approach uses standard PostgreSQL client semantics. SPI + SetUserIdAndSecContext requires unsafe C code, RAII guards, subtransaction management, and careful interaction with the duroxide runtime. |
| **Equivalent security** | Both approaches provide privilege isolation. The sqlx connection is authenticated as the user — `RESET ROLE` only reverts to the user's own `submitted_by`, not the worker's identity. There is no privilege escalation path. |

#### When to reconsider SPI

SPI would be worth revisiting if:
- Connection overhead becomes a bottleneck (many SQL nodes per workflow)
- The `pg_hba.conf` trust requirement is unacceptable in a deployment environment
- A need arises for tighter integration with the worker's transaction (e.g., savepoint-based partial rollback)
- The C-level escape prevention of `SetUserIdAndSecContext` is required for compliance

---

## 9. User Experience

### 9.1 End User Workflow

```sql
-- User with df function access (DBA already granted)
SET ROLE app_user;

-- Create a durable function (SQL runs as app_user)
SELECT df.start(
    df.sql('INSERT INTO my_table VALUES (now(), ''hello'')'),
    'my-job'
);
-- Returns: instance_id 'abc12345'

-- Check status
SELECT df.status('abc12345');
-- Returns: 'completed' (or 'running', 'failed')

-- View my instances only (RLS enforced)
SELECT id, label, status, submitted_at 
FROM df.instances 
ORDER BY submitted_at DESC;
```

### 9.2 Administrator Workflow

```sql
-- After CREATE EXTENSION, admins must grant privileges to application roles.
-- Table and schema grants are NOT auto-applied.

-- 1. Grant basic df access to a role
-- (see USER_GUIDE.md "Privilege Grants" for the full list of individual grants)
SELECT df.grant_usage('app_backend');

-- 2. Opt a role into HTTP access only when needed
SELECT df.grant_usage('app_backend_http', include_http => true);

-- 3. Allowed HTTP destinations depend on the build feature set.
-- See docs/http-security.md for the current allowlist.

-- 4. View all instances (superuser bypasses RLS)
SELECT submitted_by, count(*) 
FROM df.instances 
GROUP BY submitted_by;
```

### 9.3 Error Messages

| Scenario | Error Message |
|----------|---------------|
| No function permission | `ERROR: permission denied for function df.http` or execution-time `Blocked: role '{role}' does not have EXECUTE privilege on df.http()...` |
| SQL permission denied | `ERROR: permission denied for table secret_data` (in df.status result) |
| HTTP host not allowed | `ERROR: HTTP request blocked: host 'evil.com' not in allowed list` |
| SSRF blocked | `ERROR: HTTP request blocked: resolves to internal IP 169.254.169.254` |
| RLS filtered | (silent — user simply doesn't see other users' rows) |
| Cross-user cancel/signal | `ERROR: Instance not found or access denied: <id>` |

---

## 10. Test Specification

### 10.1 Unit Tests

#### UT1: Security Context Capture

```rust
#[pg_test]
fn test_security_context_capture() {
    // Setup: Create test user
    Spi::run("CREATE USER test_capture_user").unwrap();
    Spi::run("GRANT EXECUTE ON FUNCTION df.start TO test_capture_user").unwrap();
    Spi::run("GRANT EXECUTE ON FUNCTION df.sql TO test_capture_user").unwrap();
    Spi::run("GRANT EXECUTE ON FUNCTION df.status TO test_capture_user").unwrap();
    Spi::run("SET ROLE test_capture_user").unwrap();
    
    let ctx = SecurityContext::capture();
    
    assert_eq!(ctx.user_name, "test_capture_user");
    assert!(!ctx.is_superuser);
    assert!(ctx.user_oid > 0);
    
    // Cleanup
    Spi::run("RESET ROLE").unwrap();
    Spi::run("DROP USER test_capture_user").unwrap();
}
```

#### UT2: Context Switch and Restore

**Note**: This unit test validates PostgreSQL's security context APIs (`GetUserIdAndSecContext` / `SetUserIdAndSecContext`) and the general ability to switch/restore identities inside a backend. These APIs are **not currently used** by pg_durable's implemented execution path (which uses sqlx connections instead), but this test documents the API's behavior for potential future SPI-based execution (see [Section 8.8](#88-spi-as-a-potential-future-optimization)).

The pg_durable-specific verification of privilege isolation is covered by the E2E tests (E2E-SEC-01..03) which assert privilege isolation against real tables via the implemented sqlx connection approach.

```rust
#[pg_test]
fn test_context_switch_and_restore() {
    // Get original context
    let original_user = Spi::get_one::<String>("SELECT current_user")
        .unwrap().unwrap();
    
    // Create target user
    Spi::run("CREATE USER test_switch_user").unwrap();
    let target_oid: u32 = Spi::get_one(
        "SELECT oid::int4 FROM pg_roles WHERE rolname = 'test_switch_user'"
    ).unwrap().unwrap();
    
    // Switch context
    unsafe {
        let mut saved_uid: pg_sys::Oid = 0;
        let mut saved_sec: i32 = 0;
        pg_sys::GetUserIdAndSecContext(&mut saved_uid, &mut saved_sec);
        
        pg_sys::SetUserIdAndSecContext(
            target_oid,
            saved_sec | pg_sys::SECURITY_LOCAL_USERID_CHANGE as i32
        );
        
        // Verify switch
        let current = Spi::get_one::<String>("SELECT current_user").unwrap().unwrap();
        assert_eq!(current, "test_switch_user");
        
        // Restore
        pg_sys::SetUserIdAndSecContext(saved_uid, saved_sec);
    }
    
    // Verify restore
    let restored_user = Spi::get_one::<String>("SELECT current_user")
        .unwrap().unwrap();
    assert_eq!(restored_user, original_user);
    
    // Cleanup
    Spi::run("DROP USER test_switch_user").unwrap();
}
```

### 10.2 E2E Security Tests

#### E2E-SEC-01: Basic Privilege Isolation

**File**: `tests/e2e/sql/security_01_privilege_isolation.sql`

```sql
-- Test: User SQL executes with submitting user's privileges
-- Expected: User can access their own tables, not others'

-- Setup: Create two users with separate tables
DROP TABLE IF EXISTS user_a_data;
DROP TABLE IF EXISTS user_b_data;
DROP USER IF EXISTS sec_test_user_a;
DROP USER IF EXISTS sec_test_user_b;

CREATE USER sec_test_user_a;
CREATE USER sec_test_user_b;
GRANT EXECUTE ON FUNCTION df.start TO sec_test_user_a, sec_test_user_b;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_user_a, sec_test_user_b;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_user_a, sec_test_user_b;

-- Create tables owned by each user
SET ROLE sec_test_user_a;
CREATE TABLE user_a_data (id serial, value text);
INSERT INTO user_a_data (value) VALUES ('secret_a');
RESET ROLE;

SET ROLE sec_test_user_b;
CREATE TABLE user_b_data (id serial, value text);
INSERT INTO user_b_data (value) VALUES ('secret_b');
RESET ROLE;

-- Test 1: User A can access their own table
SET ROLE sec_test_user_a;
CREATE TEMP TABLE _test_1 (instance_id TEXT);
INSERT INTO _test_1 SELECT df.start(
    df.sql('SELECT value FROM user_a_data'),
    'sec-test-1-own-table'
);
RESET ROLE;

-- Poll until complete
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_1;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST 1 FAILED: User A could not access own table. Status: %', status;
    END IF;
END $$;

-- Test 2: User A cannot access User B's table
SET ROLE sec_test_user_a;
CREATE TEMP TABLE _test_2 (instance_id TEXT);
INSERT INTO _test_2 SELECT df.start(
    df.sql('SELECT value FROM user_b_data'),
    'sec-test-2-other-table'
);
RESET ROLE;

-- Poll until complete (should fail)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    result_json JSONB;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_2;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST 2 FAILED: User A should NOT access User B table. Status: %', status;
    END IF;
    
    -- Verify error message mentions permission denied
    SELECT result::jsonb INTO result_json 
    FROM df.instances WHERE id = inst_id;
    
    IF NOT (result_json->>'error' ILIKE '%permission denied%') THEN
        RAISE EXCEPTION 'TEST 2 FAILED: Expected permission denied error, got: %', result_json->>'error';
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_1;
DROP TABLE _test_2;
DROP TABLE user_a_data;
DROP TABLE user_b_data;
DROP USER sec_test_user_a;
DROP USER sec_test_user_b;

SELECT 'TEST PASSED: E2E-SEC-01 Privilege Isolation' AS result;
```

#### E2E-SEC-02: RESET ROLE Escape Prevention

**File**: `tests/e2e/sql/security_02_reset_role_escape.sql`

```sql
-- Test: User cannot escape to duroxide privileges via RESET ROLE
-- Expected: RESET ROLE has no effect; SQL still runs as original user

-- Setup
DROP TABLE IF EXISTS admin_only_table;
DROP USER IF EXISTS sec_test_escape_user;

CREATE USER sec_test_escape_user;
GRANT EXECUTE ON FUNCTION df.start TO sec_test_escape_user;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_escape_user;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_escape_user;

-- Create a table that sec_test_escape_user cannot access
CREATE TABLE admin_only_table (secret text);
INSERT INTO admin_only_table VALUES ('admin_secret');
-- duroxide CAN access this, but sec_test_escape_user CANNOT

-- User attempts to escape via RESET ROLE
SET ROLE sec_test_escape_user;
CREATE TEMP TABLE _test_escape (instance_id TEXT);
INSERT INTO _test_escape SELECT df.start(
    df.sql('RESET ROLE; SELECT secret FROM admin_only_table;'),
    'sec-test-escape-attempt'
);
RESET ROLE;

-- Poll until complete (should fail)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_escape;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    -- The key assertion: even with RESET ROLE, the query should FAIL
    -- because the connection is authenticated as sec_test_escape_user,
    -- and RESET ROLE only reverts to that identity (no escalation possible)
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'SECURITY VULNERABILITY: RESET ROLE escape succeeded!';
    END IF;
    
    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: Unexpected status: %', status;
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_escape;
DROP TABLE admin_only_table;
DROP USER sec_test_escape_user;

SELECT 'TEST PASSED: E2E-SEC-02 RESET ROLE Escape Prevention' AS result;
```

#### E2E-SEC-03: SET ROLE Escalation Prevention

**File**: `tests/e2e/sql/security_03_set_role_escalation.sql`

```sql
-- Test: User cannot escalate to a role they're not a member of
-- Expected: SET ROLE to non-member role fails

-- Setup
DROP USER IF EXISTS sec_test_low_priv;
DROP USER IF EXISTS sec_test_high_priv;

CREATE USER sec_test_low_priv;
CREATE USER sec_test_high_priv WITH SUPERUSER;  -- high privilege role
GRANT EXECUTE ON FUNCTION df.start TO sec_test_low_priv;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_low_priv;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_low_priv;
-- NOTE: sec_test_low_priv is NOT a member of sec_test_high_priv

-- Low-priv user attempts to escalate
SET ROLE sec_test_low_priv;
CREATE TEMP TABLE _test_escalate (instance_id TEXT);
INSERT INTO _test_escalate SELECT df.start(
    df.sql('SET ROLE sec_test_high_priv; SELECT usename FROM pg_shadow;'),
    'sec-test-escalation-attempt'
);
RESET ROLE;

-- Poll until complete (should fail)
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_escalate;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'SECURITY VULNERABILITY: SET ROLE escalation succeeded!';
    END IF;
    
    IF lower(status) != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: Unexpected status: %', status;
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_escalate;
DROP USER sec_test_low_priv;
DROP USER sec_test_high_priv;

SELECT 'TEST PASSED: E2E-SEC-03 SET ROLE Escalation Prevention' AS result;
```

#### E2E-SEC-04: Row-Level Security Isolation

**File**: `tests/e2e/sql/security_04_rls_isolation.sql`

```sql
-- Test: Users can only see their own instances in df.instances
-- Expected: User A cannot see User B's instances

-- Setup
DROP USER IF EXISTS sec_test_rls_a;
DROP USER IF EXISTS sec_test_rls_b;

CREATE USER sec_test_rls_a;
CREATE USER sec_test_rls_b;
GRANT EXECUTE ON FUNCTION df.start TO sec_test_rls_a, sec_test_rls_b;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_rls_a, sec_test_rls_b;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_rls_a, sec_test_rls_b;

-- User A creates an instance
SET ROLE sec_test_rls_a;
CREATE TEMP TABLE _test_rls_a (instance_id TEXT);
INSERT INTO _test_rls_a SELECT df.start(
    df.sql('SELECT 1'),
    'rls-test-user-a'
);
RESET ROLE;

-- User B creates an instance
SET ROLE sec_test_rls_b;
CREATE TEMP TABLE _test_rls_b (instance_id TEXT);
INSERT INTO _test_rls_b SELECT df.start(
    df.sql('SELECT 2'),
    'rls-test-user-b'
);
RESET ROLE;

-- Wait for both to complete
PERFORM pg_sleep(2);

-- Test: User A can see their instance
SET ROLE sec_test_rls_a;
DO $$
DECLARE
    a_instance_id TEXT;
    visible_count INT;
BEGIN
    SELECT instance_id INTO a_instance_id FROM _test_rls_a;
    
    -- User A should see exactly 1 instance (their own)
    SELECT count(*) INTO visible_count FROM df.instances;
    
    IF visible_count != 1 THEN
        RAISE EXCEPTION 'RLS FAILED: User A sees % instances, expected 1', visible_count;
    END IF;
    
    -- Verify it's their instance
    IF NOT EXISTS (SELECT 1 FROM df.instances WHERE id = a_instance_id) THEN
        RAISE EXCEPTION 'RLS FAILED: User A cannot see their own instance';
    END IF;
END $$;
RESET ROLE;

-- Test: User B can see their instance, not A's
SET ROLE sec_test_rls_b;
DO $$
DECLARE
    a_instance_id TEXT;
    b_instance_id TEXT;
    visible_count INT;
BEGIN
    SELECT instance_id INTO a_instance_id FROM _test_rls_a;
    SELECT instance_id INTO b_instance_id FROM _test_rls_b;
    
    -- User B should see exactly 1 instance (their own)
    SELECT count(*) INTO visible_count FROM df.instances;
    
    IF visible_count != 1 THEN
        RAISE EXCEPTION 'RLS FAILED: User B sees % instances, expected 1', visible_count;
    END IF;
    
    -- Verify User B cannot see User A's instance
    IF EXISTS (SELECT 1 FROM df.instances WHERE id = a_instance_id) THEN
        RAISE EXCEPTION 'RLS FAILED: User B can see User A instance!';
    END IF;
END $$;
RESET ROLE;

-- Cleanup
DROP TABLE _test_rls_a;
DROP TABLE _test_rls_b;
DROP USER sec_test_rls_a;
DROP USER sec_test_rls_b;

SELECT 'TEST PASSED: E2E-SEC-04 RLS Isolation' AS result;
```

#### E2E-SEC-05: Function Permission Requirement

**File**: `tests/e2e/sql/security_05_function_permission_required.sql`

```sql
-- Test: Users without EXECUTE on df.start cannot create durable functions
-- Expected: df.start() fails with permission denied

-- Setup
DROP USER IF EXISTS sec_test_no_permission;
CREATE USER sec_test_no_permission;
-- NOTE: NOT granting EXECUTE on df.start/df.sql

-- Attempt to create durable function without required function permissions
SET ROLE sec_test_no_permission;
DO $$
BEGIN
    -- This should fail
    PERFORM df.start(df.sql('SELECT 1'), 'should-fail');
    RAISE EXCEPTION 'SECURITY FAILURE: User without permission could call df.start()!';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT ILIKE '%permission denied%' AND 
           SQLERRM NOT ILIKE '%df.start%' THEN
            RAISE EXCEPTION 'Unexpected error: %', SQLERRM;
        END IF;
        -- Expected: permission denied
END $$;
RESET ROLE;

-- Cleanup
DROP USER sec_test_no_permission;

SELECT 'TEST PASSED: E2E-SEC-05 Function Permission Requirement' AS result;
```

### 10.3 Test Matrix

| Test ID | Description | Threat | Expected Result |
|---------|-------------|--------|-----------------|
| E2E-SEC-01 | Privilege Isolation | T1, T2 | User accesses only own tables |
| E2E-SEC-02 | RESET ROLE Escape | T1 | RESET ROLE has no effect |
| E2E-SEC-03 | SET ROLE Escalation | T2 | SET ROLE to non-member fails |
| E2E-SEC-04 | RLS Isolation | T4 | Users see only own instances (see also `37_rls.sql`) |
| E2E-SEC-05 | Function Permission | - | Users without EXECUTE cannot use df.* |
| E2E-SEC-06 | Dynamic SQL Escape | T3 | EXECUTE 'RESET ROLE' fails |
| E2E-SEC-07 | HTTP SSRF Blocked | T8 | Internal IP requests denied |
| E2E-SEC-08 | HTTP Function Permission | T9 | Users without GRANT cannot use df.http |
| E2E-SEC-09 | HTTP Allowlist | T9 | Non-allowlisted hosts denied |
| E2E-SEC-10 | Vars RLS Isolation | T10 | Users cannot read/override other users' vars |
| E2E-SEC-11 | execute_sql Fault: Error | - | Instance fails cleanly; worker continues |
| E2E-SEC-12 | execute_sql Fault: Panic + Restart | - | After restart, instance is failed or retried deterministically |

### 10.4 HTTP Activity Tests

#### E2E-SEC-07: HTTP SSRF Protection

**File**: `tests/e2e/sql/security_07_http_ssrf.sql`

```sql
-- Test: HTTP requests to internal IPs are blocked (always-on protection)
-- Expected: SSRF attempts fail regardless of permissions

-- Setup
DROP USER IF EXISTS sec_test_ssrf_user;
CREATE USER sec_test_ssrf_user;
GRANT EXECUTE ON FUNCTION df.start TO sec_test_ssrf_user;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_ssrf_user;
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO sec_test_ssrf_user;  -- Has HTTP permission
GRANT EXECUTE ON FUNCTION df.status TO sec_test_ssrf_user;
GRANT sec_test_ssrf_user TO duroxide;

-- Build with a feature set that allows the chosen public test destination.
-- SSRF protection still applies regardless of that feature set.

-- Test 1: AWS metadata endpoint (169.254.169.254) should be blocked
SET ROLE sec_test_ssrf_user;
CREATE TEMP TABLE _test_ssrf_1 (instance_id TEXT);
INSERT INTO _test_ssrf_1 SELECT df.start(
    df.http('http://169.254.169.254/latest/meta-data/', 'GET'),
    'ssrf-test-aws-metadata'
);
RESET ROLE;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    error_msg TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf_1;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 50;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'SSRF VULNERABILITY: AWS metadata request succeeded!';
    END IF;
    
    -- Verify error message mentions blocked/internal
    SELECT result->>'error' INTO error_msg FROM df.instances WHERE id = inst_id;
    IF error_msg NOT ILIKE '%internal%' AND error_msg NOT ILIKE '%blocked%' THEN
        RAISE EXCEPTION 'Expected SSRF block error, got: %', error_msg;
    END IF;
END $$;

-- Test 2: localhost should be blocked
SET ROLE sec_test_ssrf_user;
CREATE TEMP TABLE _test_ssrf_2 (instance_id TEXT);
INSERT INTO _test_ssrf_2 SELECT df.start(
    df.http('http://127.0.0.1:8080/', 'GET'),
    'ssrf-test-localhost'
);
RESET ROLE;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_ssrf_2;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 50;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'SSRF VULNERABILITY: localhost request succeeded!';
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_ssrf_1;
DROP TABLE _test_ssrf_2;
REVOKE sec_test_ssrf_user FROM duroxide;
DROP USER sec_test_ssrf_user;
SELECT 'TEST PASSED: E2E-SEC-07 HTTP SSRF Protection' AS result;
```

#### E2E-SEC-08: HTTP Function Permission

**File**: `tests/e2e/sql/security_08_http_permission.sql`

```sql
-- Test: Users need EXECUTE permission on df.http to use it
-- Expected: Users without permission get function permission error

-- Setup
DROP USER IF EXISTS sec_test_http_denied;
DROP USER IF EXISTS sec_test_http_allowed;

CREATE USER sec_test_http_denied;
CREATE USER sec_test_http_allowed;

-- Both users can use df.start and df.sql
GRANT EXECUTE ON FUNCTION df.start TO sec_test_http_denied, sec_test_http_allowed;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_http_denied, sec_test_http_allowed;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_http_denied, sec_test_http_allowed;
GRANT SELECT ON df.instances TO sec_test_http_denied, sec_test_http_allowed;

-- Only sec_test_http_allowed gets HTTP permission
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO sec_test_http_allowed;
-- NOTE: sec_test_http_denied does NOT get df.http permission

GRANT sec_test_http_denied TO duroxide;
GRANT sec_test_http_allowed TO duroxide;

-- Build with a feature set that allows httpbin.org.

-- Test 1: User WITHOUT df.http permission should fail
SET ROLE sec_test_http_denied;
DO $$
BEGIN
    PERFORM df.start(
        df.http('https://httpbin.org/get', 'GET'),
        'http-test-denied'
    );
    RAISE EXCEPTION 'SECURITY FAILURE: User without df.http permission could use it!';
EXCEPTION
    WHEN insufficient_privilege THEN
        -- Expected: permission denied for function df.http
        NULL;
    WHEN OTHERS THEN
        IF SQLERRM NOT ILIKE '%permission denied%' THEN
            RAISE EXCEPTION 'Unexpected error: %', SQLERRM;
        END IF;
END $$;
RESET ROLE;

-- Test 2: User WITH df.http permission should succeed
SET ROLE sec_test_http_allowed;
CREATE TEMP TABLE _test_http_allowed (instance_id TEXT);
INSERT INTO _test_http_allowed SELECT df.start(
    df.http('https://httpbin.org/get', 'GET'),
    'http-test-allowed'
);
RESET ROLE;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_http_allowed;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Allowed user HTTP should succeed. Status: %', status;
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_http_allowed;
REVOKE sec_test_http_denied FROM duroxide;
REVOKE sec_test_http_allowed FROM duroxide;
DROP USER sec_test_http_denied;
DROP USER sec_test_http_allowed;

SELECT 'TEST PASSED: E2E-SEC-08 HTTP Function Permission' AS result;
```

#### E2E-SEC-09: HTTP URL Allowlist

**File**: `tests/e2e/sql/security_09_http_allowlist.sql`

```sql
-- Test: HTTP requests only allowed to the destinations permitted by the
-- build-time feature allowlist
-- Expected: Requests to non-allowlisted hosts are denied

-- Setup
DROP USER IF EXISTS sec_test_allowlist_user;
CREATE USER sec_test_allowlist_user;
GRANT EXECUTE ON FUNCTION df.start TO sec_test_allowlist_user;
GRANT EXECUTE ON FUNCTION df.sql TO sec_test_allowlist_user;
GRANT EXECUTE ON FUNCTION df.http(text, text, text, jsonb, integer) TO sec_test_allowlist_user;
GRANT EXECUTE ON FUNCTION df.status TO sec_test_allowlist_user;
GRANT SELECT ON df.instances TO sec_test_allowlist_user;
GRANT sec_test_allowlist_user TO duroxide;

-- Build with a feature set that allows httpbin.org but not evil.com.

-- Test 1: Allowlisted host should succeed
SET ROLE sec_test_allowlist_user;
CREATE TEMP TABLE _test_allowed (instance_id TEXT);
INSERT INTO _test_allowed SELECT df.start(
    df.http('https://httpbin.org/get', 'GET'),
    'allowlist-test-allowed'
);
RESET ROLE;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_allowed;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 100;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: Allowlisted host should succeed. Status: %', status;
    END IF;
END $$;

-- Test 2: Non-allowlisted host should fail
SET ROLE sec_test_allowlist_user;
CREATE TEMP TABLE _test_denied (instance_id TEXT);
INSERT INTO _test_denied SELECT df.start(
    df.http('https://evil.com/steal-data', 'GET'),
    'allowlist-test-denied'
);
RESET ROLE;

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    error_msg TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_denied;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 50;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'completed' THEN
        RAISE EXCEPTION 'SECURITY FAILURE: Non-allowlisted host succeeded!';
    END IF;
    
    SELECT result->>'error' INTO error_msg FROM df.instances WHERE id = inst_id;
    IF error_msg NOT ILIKE '%allowed%' AND error_msg NOT ILIKE '%blocked%' THEN
        RAISE EXCEPTION 'Expected allowlist error, got: %', error_msg;
    END IF;
END $$;

-- Cleanup
DROP TABLE _test_allowed;
DROP TABLE _test_denied;
REVOKE sec_test_allowlist_user FROM duroxide;
DROP USER sec_test_allowlist_user;

SELECT 'TEST PASSED: E2E-SEC-09 HTTP URL Allowlist' AS result;
```

---

### 10.5 Fault Injection Tests (execute_sql)

These tests validate behavior when `execute_sql` fails due to expected errors and unexpected panics.

**E2E-SEC-11: execute_sql error path**

- Configure `df.test_fault_inject = 'execute_sql_error'` (superuser)
- Start a simple workflow with a SQL node
- Assert:
    - Instance transitions to `failed`
    - Error is recorded without leaking secrets/other-user data
    - Worker keeps processing subsequent instances

**E2E-SEC-12: execute_sql panic + restart**

- Configure `df.test_fault_inject = 'execute_sql_panic_after_connect'` (superuser)
- Start a workflow that will hit SQL execution
- Assert:
    - The worker process crashes/restarts (or is forcibly restarted)
    - On restart, the runtime resumes from durable state
    - The instance eventually becomes `failed` (or is retried if the orchestration semantics retry)
    - No stale per-user connections remain after restart

**Restart validation strategy**:
- Use the existing E2E harness to stop/start Postgres (or restart the bgworker) between polling loops.
- After restart, poll `df.status(instance_id)` until terminal state.

---

### 10.6 Vars/Secrets Security Tests

**E2E-SEC-10: Vars RLS isolation**

- User A sets `df.setvar('k','a')`
- User B sets `df.setvar('k','b')`
- User A starts a workflow that reads `$k` and asserts it sees `a`
- User B starts a workflow that reads `$k` and asserts it sees `b`
- Assert User A cannot read/overwrite User B’s var rows

**Secrets tests (design-level)**

- Verify non-admin cannot `EXECUTE df.setsecret/df.unsetsecret/df.clearsecrets`
- Verify non-admin cannot `SELECT` from `df.secrets`
- Verify workflows can reference a secret by name and the secret value is not returned/logged

---

## 11. Open Questions

### OQ1: Azure Managed Identity Integration

**Question**: Should duroxide support Azure AD authentication as an alternative to pg_hba.conf local auth?

**Considerations**:
- Useful for multi-instance deployments
- Requires duroxide-pg changes
- May need Azure SDK dependency

**Recommendation**: Defer to Phase 2; pg_hba.conf approach works for Azure Flexible Server.

---

### OQ2: Cross-Database Execution

**Question**: Should durable functions support cross-database queries (via postgres_fdw)?

**Considerations**:
- Per-user sqlx connections are per-database (the `database` field in `ExecuteSqlInput` supports targeting a specific database)
- FDW connections are separate sessions
- Security model becomes complex

**Recommendation**: Out of scope; document as unsupported.

---

### OQ3: SECURITY DEFINER Functions

**Question**: If user SQL calls a SECURITY DEFINER function, which user's context applies?

**Answer**: PostgreSQL's standard behavior applies:
- SECURITY DEFINER function runs as its owner
- After function returns, context reverts
- This is expected and documented PostgreSQL behavior

**Recommendation**: Document this; no special handling needed.

---

### OQ4: Superuser Durable Functions

**Status**: Resolved — implemented via `pg_durable.enable_superuser_instances`.

**Question**: Should superusers be able to create durable functions that run as superuser?

**Considerations**:
- Useful for administrative tasks
- Higher risk if function graph is compromised
- BYPASSRLS roles can forge `submitted_by` to a superuser OID, making this a privilege escalation vector in multi-tenant environments

**Resolution**: Gated behind `pg_durable.enable_superuser_instances` (default `off`). When `off`, `df.start()` immediately rejects any submission whose `current_user` is a superuser, and the background worker rejects any instance whose `submitted_by` resolves to a superuser at execution time (closing the BYPASSRLS forgery path). When `on`, superuser submissions are allowed as before. The GUC is `SUSET` / `SUPERUSER_ONLY` and hidden from `SHOW ALL`. See [superuser_guc.md](superuser_guc.md) for full design rationale.

---

## Appendix A: Security Checklist for Code Review

- [ ] All user SQL goes through `connect_as_user()` → per-user sqlx connection (never the worker's shared pool)
- [ ] `submitted_by` is captured from `GetUserId()` at `df.start()` time, not from user input
- [ ] Role names are properly quoted where needed
- [ ] Access control uses PostgreSQL-native function permissions (EXECUTE on df.start/df.sql/df.http)
- [x] RLS policies use `current_user`, not user-supplied values
- [ ] Error messages don't leak other users' data
- [ ] Logging includes effective user for audit trail
- [ ] `SET df.in_workflow = 'true'` is set on user connections to prevent variable mutation during execution (future: could also guard against recursive `df.start()`)
- [ ] All SPI queries that accept user-supplied parameters prefer parameterized APIs (`Spi::get_one_with_args()` / `Spi::run_with_args()`). Use manual `.replace('\'', "''")` escaping only as fallback where parameters cannot be used. Cross-check: `df.status()`, `df.result()`, `df.cancel()`, `df.signal()`, monitoring functions
- [ ] PL/pgSQL and SQL helper functions include `SET search_path = pg_catalog, df, pg_temp`
- [ ] All function/table references in dynamic SQL are schema-qualified (`df.instances`, not `instances`)

---

## Appendix B: Related PostgreSQL Internals

**Note**: These internals are relevant to the potential future SPI-based execution path described in [Section 8.8](#88-spi-as-a-potential-future-optimization). The current implementation uses sqlx connections and does not directly call these APIs for user SQL execution.

### SetUserIdAndSecContext Flags

| Flag | Value | Meaning |
|------|-------|---------|
| `SECURITY_LOCAL_USERID_CHANGE` | 1 | Temporary userid change (like SECURITY DEFINER) |
| `SECURITY_RESTRICTED_OPERATION` | 2 | Block certain operations |
| `SECURITY_NOFORCE_RLS` | 4 | Don't force RLS for this operation |

### Relevant PostgreSQL Source

- `src/backend/utils/init/miscinit.c`: SetUserIdAndSecContext implementation
- `src/backend/utils/adt/acl.c`: Permission checking functions
- `src/backend/executor/spi.c`: SPI implementation

---

*End of Specification*
