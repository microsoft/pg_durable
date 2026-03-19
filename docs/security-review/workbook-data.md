# pg_durable — Threat Model Workbook Data

**Review Date**: 2026-03-18  
**System**: pg_durable v0.2.0  
**Companion**: [security-review.md](security-review.md) | [ThreatModelDFD.md](ThreatModelDFD.md)

This document provides supplementary data tables for the threat model review meeting.

---

## 1. Tokens / Claims Inventory

pg_durable does not use token-based authentication. All identity is PostgreSQL role-based.

| Identity | Source | Capture Method | Stored In | Used For |
|---|---|---|---|---|
| session_user (login_role) | pg_hba.conf authentication | `GetSessionUserId()` C API | df.instances.login_role, df.nodes.login_role | Connection authentication for per-user SQL execution |
| current_user (submitted_by) | PostgreSQL SET ROLE / default | `GetOuterUserId()` C API | df.instances.submitted_by, df.nodes.submitted_by | SET ROLE target for privilege isolation; RLS policy column |
| worker_role | GUC `pg_durable.worker_role` | Configuration (default: "azuresu") | postgresql.conf | Background worker sqlx pool authentication |

### Least Privilege Assessment

| Identity | Privileges | Minimum Required | Delta |
|---|---|---|---|
| Database user | EXECUTE on all df.* functions, SELECT/INSERT on df.tables, USAGE on df schema | EXECUTE on needed df.* functions only; no df.http() unless needed | Too broad — PUBLIC has EXECUTE on all functions including df.http() |
| Worker role (azuresu) | SUPERUSER (bypasses RLS, connects as any role) | BYPASSRLS + CREATEROLE or trust-auth connect-as capability | Could explore non-superuser with BYPASSRLS if PostgreSQL supports connect-as without superuser |
| Per-user SQL connection | User's own RBAC (login_role + SET ROLE submitted_by) | Exactly what the user has outside durable functions | ✅ Correct — no privilege amplification |

---

## 2. Protected Assets

| Asset | Classification | Location | Protection | Residual Risk |
|---|---|---|---|---|
| User SQL queries | Confidential (user code) | df.nodes.query | RLS (submitted_by); worker logs queries | Queries visible in worker logs |
| Execution results | Confidential (user data) | df.nodes.result (JSONB) | RLS (submitted_by) | None — properly isolated |
| User variables | May contain secrets | df.vars (name, value) | RLS (owner); explicit WHERE in functions | Plaintext storage; superuser visibility |
| HTTP request config | May contain auth tokens | df.nodes.query (JSON) | RLS (submitted_by) | Credentials in plaintext alongside URL/method |
| Instance metadata | Internal | df.instances | RLS (submitted_by) | Low |
| Duroxide state | Internal runtime | duroxide.* tables | No GRANT to PUBLIC | Worker-only access; low risk |
| Worker connection string | Configuration | GUC / env vars | Standard PostgreSQL config | Readable via current_setting() |

---

## 3. API Inventory

### User-Facing Functions (df.* schema)

| Function | Parameters | Auth | RLS | Input Validation | Risk |
|---|---|---|---|---|---|
| `df.start(fut, label?, db?)` | Durofut JSON, optional label, optional database | PostgreSQL role | INSERT into df.instances/nodes | Validates Durofut JSON, database existence | Medium — main entry point |
| `df.sql(query)` | SQL text | None (builds in-memory) | N/A | Node type validation | Low — no I/O |
| `df.http(url, method?, body?, headers?, timeout?)` | URL + HTTP config | PostgreSQL role | N/A | Scheme, method, timeout validation | **High** — external I/O |
| `df.status(instance_id)` | Instance ID text | PostgreSQL role | SELECT df.instances | **Parameterized SPI** | Low |
| `df.result(instance_id)` | Instance ID text | PostgreSQL role | SELECT df.instances/nodes | **Parameterized SPI** | Low |
| `df.cancel(instance_id, reason?)` | Instance ID, optional reason | PostgreSQL role | SELECT df.instances (ownership check) | None beyond RLS | Low |
| `df.signal(instance_id, event, data)` | Instance ID, event name, data | PostgreSQL role | None (via duroxide client) | None | Medium — no ownership check on signal target |
| `df.setvar(name, value)` | Key-value text | PostgreSQL role | INSERT/UPDATE df.vars | Rejects if in workflow context | Low |
| `df.getvar(name)` | Key text | PostgreSQL role | SELECT df.vars (owner filter) | None | Low |
| `df.unsetvar(name)` | Key text | PostgreSQL role | DELETE df.vars (owner filter) | None | Low |
| `df.clearvars()` | None | PostgreSQL role | DELETE df.vars (owner filter) | None | Low |
| `df.wait_for_completion(id, timeout?)` | Instance ID, timeout | PostgreSQL role | SELECT df.instances | Timeout > 0 | Low |
| `df.sleep(seconds)` | bigint | None (in-memory) | N/A | seconds >= 0 | Low |
| `df.if(cond, then, else)` | Three Durofut args | None (in-memory) | N/A | Validates Durofut JSON | Low |
| `df.loop(body, cond?)` | Durofut, optional condition | None (in-memory) | N/A | Validates Durofut JSON | Low |
| `df.join(a, b)` / `df.join3(a, b, c)` | Durofut args | None (in-memory) | N/A | Validates Durofut JSON | Low |
| `df.race(a, b)` | Two Durofut args | None (in-memory) | N/A | Validates Durofut JSON | Low |
| `df.explain(fut_or_id)` | Durofut JSON or instance ID | PostgreSQL role | SELECT df.nodes (for existing instances) | JSON parse | Low |
| `df.debug_connection()` | None | PostgreSQL role | None | None | **Medium** — exposes connection info |
| `df.version()` | None | PostgreSQL role | None | None | Low |
| `df.target_database()` | None | PostgreSQL role | None | None | Low |

### SQL Operators

| Operator | Function | Purpose |
|---|---|---|
| `~>` | `df.seq(a, b)` | Sequence: execute a then b |
| `\|=>` | `df.as(a, name)` | Name a result |
| `&` | `df.join(a, b)` | Parallel join |
| `\|` | `df.race(a, b)` | Parallel race |

### Internal Activities (not user-callable)

| Activity | Input | Output | I/O |
|---|---|---|---|
| `execute-sql` | query, submitted_by, login_role, database? | JSON result rows | Per-user PostgreSQL connection |
| `execute-http` | HttpConfig JSON | HTTP response JSON | Outbound HTTP/HTTPS |
| `load-function-graph` | instance_id | FunctionGraph JSON | SELECT df.instances/nodes |
| `update-instance-status` | instance_id, status | None | UPDATE df.instances |
| `update-node-status` | node_id, status, result? | None | UPDATE df.nodes |

---

## 4. Database Tables Inventory

| Table | Schema | RLS | Grants | Key Columns |
|---|---|---|---|---|
| df.instances | df | ✅ ENABLE (not FORCE) | PUBLIC: SELECT, INSERT, UPDATE(status, updated_at) | id, label, root_node, status, submitted_by, login_role, created_at, updated_at, completed_at |
| df.nodes | df | ✅ ENABLE (not FORCE) | PUBLIC: SELECT, INSERT | id, instance_id, node_type, query, result_name, left_node, right_node, submitted_by, login_role, status, result |
| df.vars | df | ✅ ENABLE (not FORCE) | PUBLIC: SELECT, INSERT, UPDATE, DELETE | name, value, owner |
| df._worker_epoch | df | ❌ | None (no GRANT to PUBLIC) | sentinel UUID |
| duroxide.* | duroxide | ❌ | None (no GRANT to PUBLIC) | Internal duroxide runtime state |

### RLS Policy Summary

| Table | Policy | USING | WITH CHECK |
|---|---|---|---|
| df.instances | instances_user_isolation (FOR ALL) | submitted_by = current_user::regrole | submitted_by = current_user::regrole |
| df.nodes | nodes_user_isolation (FOR ALL) | submitted_by = current_user::regrole | submitted_by = current_user::regrole |
| df.vars | vars_user_isolation (FOR ALL) | owner = current_user::regrole | owner = current_user::regrole |

---

## 5. Configuration Parameters

| GUC | Default | Scope | Security Relevance |
|---|---|---|---|
| `pg_durable.worker_role` | "azuresu" | Postmaster | Determines background worker's PostgreSQL identity; must be superuser |
| `pg_durable.database` | "postgres" | Postmaster | Target database for extension operations |
| `df.in_workflow` | unset | Session | Custom GUC set on worker connections; prevents variable mutation during execution |

### Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `PGHOST` | "127.0.0.1" | PostgreSQL host for worker connections |
| `RUST_LOG` | (unset) | Controls tracing verbosity for worker process |

---

## 6. Deployment Considerations (Single-Tenant)

### pg_hba.conf Requirements

The background worker connects as arbitrary users via localhost TCP. Required:

```
# Trust auth for local TCP connections (background worker)
host    all    all    127.0.0.1/32    trust
host    all    all    ::1/128         trust
```

### Recommended Production Hardening

1. **TLS on external connections**: Configure `ssl = on` and `ssl_cert_file`/`ssl_key_file` in postgresql.conf
2. **Restrict EXECUTE permissions**: `REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA df FROM PUBLIC`; grant to specific roles
3. **Restrict df.http()**: Additional REVOKE on HTTP function; grant only to roles needing external HTTP
4. **Log file permissions**: Ensure PostgreSQL log directory (containing worker traces with user SQL) has restricted permissions
5. **Superuser access audit**: Verify only necessary operators have superuser/pg_durable admin access
6. **Backup encryption**: Ensure PostgreSQL backups containing df.vars and df.nodes data are encrypted
