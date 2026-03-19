# pg_durable Security Review

**Review Date**: 2026-03-18  
**System**: pg_durable — PostgreSQL extension for durable SQL function execution  
**Version**: 0.2.0 (current development)  
**Deployment Model**: Single-tenant PostgreSQL instance  
**Reviewer**: Security Review Agent (SDL methodology)  
**Companion**: [ThreatModelDFD.md](ThreatModelDFD.md) | [threat-model.tm7](threat-model.tm7)

---

## 1. Executive Summary

pg_durable is a PostgreSQL extension (Rust/pgrx) that provides durable SQL function execution within the PostgreSQL server process. Users build function graphs via SQL DSL operators, and a background worker executes them durably via the duroxide runtime. The extension also supports outbound HTTP requests via `df.http()`.

### Review Scope

- Full extension codebase (src/, sql/, tests/)
- Background worker architecture and privilege model
- SQL DSL entry points and data flows
- SSRF protection implementation
- User isolation and RLS enforcement
- Existing security documentation and specs

### Overall Security Posture: **GOOD with identified gaps**

The extension demonstrates strong security design for its core threat model:

**Strengths:**
- Privilege isolation via per-user sqlx connections is well-designed and correctly implemented
- RLS enforcement on all user-facing tables with appropriate policies
- Identity capture via PostgreSQL C API (GetSessionUserId/GetOuterUserId) is unforgeable from SQL
- Comprehensive SSRF protection with IP blocklist, DNS rebinding prevention, and redirect disabling 
- SQL injection mitigated in critical paths (df.status, df.result use parameterized SPI)
- Thorough security documentation with explicit threat model

**Key Gaps:**
- No denial-of-service protections (rate limiting, quotas) — P0
- HTTP data exfiltration controls not yet implemented — P0
- Some activity SQL uses string formatting instead of parameterized queries — P1
- No encryption at rest for variables or HTTP credentials stored in node configs — P1
- TLS not enforced on PostgreSQL wire protocol — P2

---

## 2. Architecture Overview

### System Components

```
┌──────────────────────────────────────────────────────────────┐
│                    PostgreSQL Server                          │
│                                                              │
│  ┌──────────────────┐     ┌──────────────────────────────┐  │
│  │  User Backend     │     │  Background Worker            │  │
│  │  (per session)    │     │  (single persistent process)  │  │
│  │                   │     │                                │  │
│  │  DSL functions    │     │  duroxide runtime              │  │
│  │  SPI calls        │     │  orchestrations/activities     │  │
│  │  Identity capture │     │  per-user SQL connections      │  │
│  └───────┬───────────┘     │  outbound HTTP (SSRF-safe)    │  │
│          │                 └──────────┬───────────────────┘  │
│          │                            │                      │
│  ┌───────┴────────────────────────────┴───────────────────┐  │
│  │  PostgreSQL Tables                                      │  │
│  │  df.instances  df.nodes  df.vars  duroxide.*           │  │
│  │  (RLS)         (RLS)     (RLS)    (worker-only)        │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Trust Boundaries

1. **External ↔ PostgreSQL Server**: User connections via pg_hba.conf authentication
2. **User Session ↔ Shared Tables**: RLS policies enforce per-user data isolation
3. **Background Worker ↔ User Tables**: Worker bypasses RLS (superuser); creates per-user connections for SQL execution
4. **PostgreSQL Server ↔ External HTTP**: SSRF-protected outbound HTTP from df.http()

### Key Data Flows

| # | Flow | Risk Level |
|---|---|---|
| DF-1 | User → Backend (SQL DSL calls) | Medium |
| DF-2 | Backend → df.tables (graph persistence via SPI) | Low |
| DF-3 | Backend → df.vars (variable R/W via SPI) | Low |
| DF-4 | Backend → duroxide.* (instance enqueue) | Low |
| DF-5 | Worker → duroxide.* (work item polling) | Low |
| DF-6 | Worker → df.tables (graph loading) | Medium |
| DF-7 | Worker → df.tables (status updates) | Low-Medium |
| DF-8 | Worker → user tables (SQL execution) | **High** |
| DF-9 | Worker → external HTTP (outbound requests) | **High** |
| DF-10 | Backend → User (query results) | Low |

---

## 3. Findings by Category

### 3.1 Spoofing

| ID | Finding | Severity | Status |
|---|---|---|---|
| S-1 | PostgreSQL authentication delegates to pg_hba.conf — extension does not add its own auth layer | Info | ✅ Appropriate for trusted extension model |
| S-2 | User identity captured via unforgeable C API calls (GetSessionUserId, GetOuterUserId) | Info | ✅ Well-implemented |
| S-3 | Per-user SQL connections authenticated as login_role via trust auth on localhost | Medium | ✅ Mitigated — pg_hba.conf trust is intentional and appropriate for same-host background worker |
| S-4 | SECURITY DEFINER functions: GetOuterUserId correctly captures caller, not definer | Info | ✅ Tested (E2E test 27_user_isolation) |

### 3.2 Tampering

| ID | Finding | Severity | Status |
|---|---|---|---|
| T-1 | **SQL injection in SPI — FIXED**: df.status() and df.result() now use parameterized queries (Spi::get_one_with_args) | Critical (fixed) | ✅ Mitigated |
| T-2 | **String formatting in activity SQL**: update_instance_status and update_node_status use `format!()` for SQL construction. Instance IDs/node IDs come from trusted duroxide orchestration data, not user input, but parameterization would be more robust. | Medium | ⚠️ Recommend parameterize |
| T-3 | **Variable substitution is raw injection by design**: `{var}` substitution replaces variables as-is into SQL. This is intentional (variables are SQL fragments), runs with user's own privileges, and is documented. | Medium | ✅ Accepted risk (documented) |
| T-4 | **Result substitution ($name) quotes strings**: String values from result substitution are properly escaped with single-quote doubling (`s.replace('\'', "''")`) | Info | ✅ Implemented |
| T-5 | **SET ROLE quote escaping**: `connect_as_user()` escapes double quotes in role names via `replace('"', "\"\"")`. This is correct PostgreSQL identifier escaping. | Info | ✅ Correct |
| T-6 | **RLS prevents cross-user table manipulation**: WITH CHECK clauses on all tables prevent user from inserting/updating rows with forged identity | Info | ✅ Well-implemented |
| T-7 | **Column-level UPDATE grant on df.instances**: Only (status, updated_at) columns are writable by users; submitted_by, login_role, root_node, label are immutable | Info | ✅ Good defense-in-depth |
| T-8 | **search_path pinned on helper functions**: PL/pgSQL helpers set `search_path = pg_catalog, df, pg_temp` | Info | ✅ Implemented |
| T-9 | **SSRF protection comprehensive**: IP blocklist, DNS rebinding protection, redirect disabling, IPv6 mapped address handling | Info | ✅ Well-implemented |

### 3.3 Repudiation

| ID | Finding | Severity | Status |
|---|---|---|---|
| R-1 | **Audit trail for SQL execution**: submitted_by and login_role stored in df.instances and df.nodes | Info | ✅ Good |
| R-2 | **Audit trail for HTTP requests**: submit_by, login_role, URL, and method logged via trace_info | Info | ✅ Good |
| R-3 | **No centralized audit log table**: Audit data is distributed across instance/node rows and worker log files. No dedicated, queryable audit log. | Medium | ⚠️ Recommend for GA |
| R-4 | **Worker logs include user SQL**: Full query text logged, which aids forensics but may expose sensitive data in log files | Low | ⚠️ Log protection needed |
| R-5 | **No alerting for security events**: SSRF blocks, privilege failures, and auth errors are logged but no alerting mechanism exists | Low | ⚠️ Deferred |

### 3.4 Information Disclosure

| ID | Finding | Severity | Status |
|---|---|---|---|
| I-1 | **RLS on all user-facing tables**: df.instances, df.nodes, df.vars all have RLS enabled with appropriate policies | Info | ✅ Well-implemented |
| I-2 | **duroxide.* schema not accessible to users**: No GRANT to PUBLIC on duroxide schema | Info | ✅ Good isolation |
| I-3 | **df.vars stores values as plaintext**: Users may store sensitive values (API keys, connection strings) in variables. No encryption at rest. | High | ⛔ Recommend encryption or warning |
| I-4 | **HTTP headers (incl. auth tokens) stored in df.nodes query column**: When df.http() is called with Authorization headers, the full config JSON including credentials is stored in df.nodes. RLS-protected but no encryption. | High | ⛔ Recommend credential separation |
| I-5 | **TLS not enforced on PostgreSQL connections**: Wire protocol uses whatever pg_hba.conf specifies. Extension does not enforce TLS. | Medium | ⚠️ Document requirement |
| I-6 | **Worker role (GUC) visible via current_setting()**: pg_durable.worker_role is readable by any user | Low | ✅ Acceptable — not a secret |
| I-7 | **df.debug_connection() exposes connection string**: This function returns the duroxide connection string. Should be restricted in production. | Medium | ⚠️ Recommend REVOKE or restrict |
| I-8 | **Superuser bypasses RLS**: By design, superuser sees all users' data. Appropriate for single-tenant. | Info | ✅ Accepted |

### 3.5 Denial of Service

| ID | Finding | Severity | Status |
|---|---|---|---|
| D-1 | **No rate limiting on df.start()**: Any user can create unbounded instances, consuming storage and worker capacity | High | ⛔ NOT IMPLEMENTED |
| D-2 | **No per-user instance/node quotas**: Storage can be exhausted by mass creation | High | ⛔ NOT IMPLEMENTED |
| D-3 | **No rate limiting on df.http()**: Outbound HTTP connections are unbounded | High | ⛔ NOT IMPLEMENTED |
| D-4 | **No timeout enforcement on user SQL**: execute_sql activity has no query timeout. Long-running queries block per-user connections (not worker pool). | Medium | ⚠️ Recommend statement_timeout |
| D-5 | **Worker fixed connection pool**: 5 connections, prevents resource exhaustion but limits throughput | Info | ✅ Appropriate |
| D-6 | **HTTP timeout configurable**: Default 30s, minimum enforced (>0) | Info | ✅ Good |
| D-7 | **No queue depth limit**: duroxide work queue has no maximum depth | Medium | ⚠️ Recommend limit |

### 3.6 Elevation of Privilege

| ID | Finding | Severity | Status |
|---|---|---|---|
| E-1 | **RESET ROLE cannot escalate**: Per-user connections authenticated as login_role; RESET ROLE returns to user's own identity | Info | ✅ Well-designed |
| E-2 | **SET ROLE membership-checked**: Standard PostgreSQL RBAC applies on per-user connections | Info | ✅ Correct |
| E-3 | **SECURITY DEFINER correctly handled**: GetOuterUserId captures caller, not definer. E2E tested. | Info | ✅ Tested |
| E-4 | **EXECUTE on all df.* functions granted to PUBLIC**: Any database user can use the extension. Consider defaulting to a specific role. | Medium | ⚠️ Recommend REVOKE from PUBLIC, grant to specific role |
| E-5 | **df.http() EXECUTE not restricted by default**: Per T9 in threat model, HTTP access should default to restricted | High | ⛔ NOT IMPLEMENTED |
| E-6 | **Worker superuser validates at startup**: lib.rs checks if worker role is superuser — warns if not, but does not prevent startup | Medium | ⚠️ Consider hard-fail |

---

## 4. Key Considerations Checklist

### Hostile Multi-tenancy

| Check | Status | Notes |
|---|---|---|
| Hyper-V sandboxes for compute isolation | N/A | Single-tenant deployment; no VM-level isolation needed |
| VNET isolation between tenants | N/A | Single-tenant; not applicable |
| Dedicated sandboxes for third-party apps | N/A | Extension runs in PostgreSQL process |
| Credential isolation per tenant/identity | ✅ | Per-user sqlx connections with separate authentication |
| Assume hostile root/SYSTEM code in sandboxes | N/A | Single-tenant; trusted extension model |

### Authentication & Authorization

| Check | Status | Notes |
|---|---|---|
| Auth request validation | ✅ | PostgreSQL pg_hba.conf handles all authentication |
| Token acquisition | N/A | No token-based auth — PostgreSQL role-based |
| Authorization before resource access | ✅ | RLS enforces per-user isolation; RBAC for SQL execution |
| Least privilege principle | ⚠️ | PUBLIC has EXECUTE on all df.* functions; df.http() should be restricted |
| Role-based privilege separation | ✅ | User ↔ worker role separation; per-user connection isolation |

### Secrets Management

| Check | Status | Notes |
|---|---|---|
| HSM-backed secrets storage | ⛔ | No secrets management infrastructure |
| Secrets inventory and rotation | ⛔ | No rotation mechanism; df.vars stores plaintext |
| No secrets in code or config | ✅ | No hardcoded secrets in extension code |

### Encryption

| Check | Status | Notes |
|---|---|---|
| TLS 1.3 support | ⚠️ | PostgreSQL supports TLS but extension doesn't enforce it |
| Data encrypted in transit | ⚠️ | Depends on pg_hba.conf; localhost trust auth has no encryption |
| Data encrypted at rest | ⛔ | df.vars, df.nodes (HTTP config) store plaintext |

### Data Validation

| Check | Status | Notes |
|---|---|---|
| Input validation and sanitization | ✅ | Node types, HTTP methods, cron expressions, timeouts validated |
| Protection against injection attacks | ✅ | Parameterized SPI in critical paths; per-user connection isolation |
| Safe deserializers only | ✅ | serde_json for all JSON parsing |

### Auditability

| Check | Status | Notes |
|---|---|---|
| Comprehensive logging | ⚠️ | HTTP requests logged; SQL logged in trace_info; no centralized audit log |
| Action attribution (who did what) | ✅ | submitted_by and login_role in all records |
| Log integrity protection | ⛔ | Worker logs to PostgreSQL log files; no tamper protection |
| Alerting for anomalies | ⛔ | No alerting mechanism |

### Dependencies & Supply Chain

| Check | Status | Notes |
|---|---|---|
| Approved package management | ✅ | Cargo with pinned dependency versions |
| Static code analysis | ⚠️ | cargo clippy in CI; no dedicated security SAST tool |
| Component governance | ⚠️ | Key deps (pgrx, duroxide, sqlx, reqwest) are maintained |
| Code signing | ⛔ | No code signing for extension .so binary |

---

## 5. Recommendations

### 5.1 Critical — Before Production (P0)

| # | Recommendation | Effort | Related Finding |
|---|---|---|---|
| 1 | **Implement rate limiting on df.start()**: Add `df.max_concurrent_per_user` GUC and `df.max_instances_per_user` limit to prevent resource exhaustion | Medium | D-1, D-2 |
| 2 | **Restrict df.http() by default**: REVOKE EXECUTE on df.http() from PUBLIC. Require explicit GRANT for HTTP access. | Low | E-5, I-3 |

### 5.2 High Priority — Before Preview (P1)

| # | Recommendation | Effort | Related Finding |
|---|---|---|---|
| 3 | **Parameterize activity SQL**: Convert update_instance_status and update_node_status to use sqlx bind parameters instead of format!() | Low | T-2 |
| 4 | **Add statement_timeout to per-user connections**: Set `statement_timeout` on user SQL connections to prevent runaway queries | Low | D-4 |
| 5 | **Add rate limiting on df.http()**: Implement `df.max_http_requests_per_instance` or per-user HTTP rate limit | Medium | D-3 |
| 6 | **Restrict df.debug_connection()**: REVOKE EXECUTE from PUBLIC or gate behind superuser check | Low | I-7 |

### 5.3 Medium Priority — Before GA (P2)

| # | Recommendation | Effort | Related Finding |
|---|---|---|---|
| 7 | **Document TLS requirements**: Add production deployment guide requiring TLS on the PostgreSQL wire protocol | Low | I-5 |
| 8 | **Credential separation for HTTP headers**: Store auth tokens separately from df.nodes query column (future df.secrets table) | High | I-4 |
| 9 | **Centralized audit log table**: Create df.audit_log for security-relevant events (SSRF blocks, auth failures, cancellations) | Medium | R-3 |
| 10 | **REVOKE EXECUTE on df.* from PUBLIC**: Default to a `df_user` role; require explicit GRANT | Low | E-4 |
| 11 | **Add SAST scanning to CI**: Integrate cargo-audit and/or cargo-deny for supply chain and vulnerability scanning | Low | — |
| 12 | **Protect worker logs**: Ensure PostgreSQL log directory permissions prevent unauthorized access; consider log rotation | Low | R-4 |

### 5.4 Low Priority — Future Improvements

| # | Recommendation | Effort | Related Finding |
|---|---|---|---|
| 13 | **Queue depth limit**: Add maximum pending instance count across all users | Medium | D-7 |
| 14 | **Worker role hard-fail**: Make worker startup fail (not just warn) if worker role is not superuser | Low | E-6 |
| 15 | **HTTP URL allowlist**: Implement `df.http_allowed_hosts` GUC for fine-grained outbound control | Medium | I-3 |
| 16 | **Anomaly alerting**: Add PostgreSQL NOTIFY-based alerting for security events | Medium | R-5 |

---

## 6. Items Already Well-Addressed

The following security areas are already implemented effectively:

1. **Privilege escalation prevention** — Per-user sqlx connections with unforgeable identity capture; RESET ROLE and SET ROLE cannot escalate
2. **RLS data isolation** — Proper policies on df.instances, df.nodes, df.vars with both USING and WITH CHECK
3. **SSRF protection** — Multi-layer approach (scheme validation, IP blocklist, DNS resolver wrapper, redirect disabling, IPv6 handling)
4. **SQL injection in SPI** — Critical paths (df.status, df.result) use parameterized queries
5. **search_path hardening** — Helper functions pin search_path
6. **Column-level UPDATE grants** — Prevents modification of identity columns
7. **Background worker isolation** — Separate process, separate connections, superuser for control-plane only
8. **Deterministic orchestrations** — No I/O in orchestration code; all side effects through activities

---

## 7. Appendix: Code Locations

| Security Control | Location |
|---|---|
| Identity capture | [src/dsl.rs](../../src/dsl.rs) — `df_start()` function |
| Per-user connections | [src/types.rs](../../src/types.rs) — `connect_as_user()` |
| RLS policies | [src/lib.rs](../../src/lib.rs) — extension_sql! blocks |
| SSRF protection | [src/ssrf.rs](../../src/ssrf.rs) |
| HTTP execution | [src/activities/execute_http.rs](../../src/activities/execute_http.rs) |
| SQL execution | [src/activities/execute_sql.rs](../../src/activities/execute_sql.rs) |
| Worker setup | [src/worker.rs](../../src/worker.rs) |
| Variable substitution | [src/types.rs](../../src/types.rs) — `substitute_all_with_options()` |
| Orchestration | [src/orchestrations/execute_function_graph.rs](../../src/orchestrations/execute_function_graph.rs) |
