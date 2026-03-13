# pg_durable Security Audit Findings & TODO

**Date**: 2026-03-11
**Source**: External security review (8 claims) evaluated against actual codebase
**Related spec**: [spec-security-model.md](spec-security-model.md)

---

## Summary of Findings

| # | Claim | Verdict | Severity | Action |
|---|-------|---------|----------|--------|
| 1 | SQL Injection via `format!()` and `.replace()` | **Partially valid (fixed)** | **CRITICAL** (2 functions) / LOW (rest) | Fixed `df.status()` and `df.result()` escaping; variable substitution documented in spec |
| 2 | `CREATE IF NOT EXISTS` / `CREATE OR REPLACE` | Valid but low risk | LOW | Document as accepted risk in spec |
| 3 | Missing `SET search_path` in PL/pgSQL functions | Partially valid | MEDIUM | Add `SET search_path` to PL/pgSQL helpers |
| 4 | Control file missing `schema =` | Valid but intentional | LOW | Document rationale |
| 5 | Worker defaults to superuser / unclear context | Mostly invalid | N/A | Already mitigated; minor doc clarification |
| 6 | SSRF / arbitrary HTTP | Invalid (already addressed) | N/A | Already implemented and spec'd |
| 7 | Secrets table permissions | Not applicable | N/A | Table doesn't exist yet |
| 8 | Missing identifier quoting in dynamic SQL | Partially valid (fixed overlap) | CRITICAL (same as #1) | Fixed via claim #1 remediation |

---

## Detailed Findings

### Finding 1: SQL Injection in `df.status()` and `df.result()` (**CRITICAL**)

**Claim**: Multiple locations use `format!()` and manual `.replace()` for query construction without safe quoting.

**Evaluation**: The claim was **partially valid**. Most of the codebase already escaped single quotes, and two functions were vulnerable. Both have now been fixed in `src/dsl.rs`.

#### Fixed: `df.status()` — [src/dsl.rs](../src/dsl.rs)

```rust
pub fn status(instance_id: &str) -> Option<String> {
    let sql = format!(
        "SELECT status FROM df.instances WHERE id = '{}'",
        instance_id.replace('\'', "''")
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}
```

**Attack**: `SELECT df.status('x'' OR 1=1--')` — can bypass RLS to read status of other users' instances.

#### Fixed: `df.result()` — [src/dsl.rs](../src/dsl.rs)

```rust
pub fn result(instance_id: &str) -> Option<String> {
    let escaped_instance_id = instance_id.replace('\'', "''");
    let sql = format!(
        r#"SELECT result::text FROM df.nodes
           WHERE id = (SELECT root_node FROM df.instances WHERE id = '{escaped_instance_id}')
           AND status = 'completed'"#
    );
    Spi::get_one::<String>(&sql).ok().flatten()
}
```

**Attack**: Same pattern — can read results from other users' workflows.

#### Correctly escaped (for reference):

| Function | File | Escaping |
|----------|------|----------|
| `df.cancel()` | src/dsl.rs | `instance_id.replace('\'', "''")` ✓ |
| `df.signal()` | src/dsl.rs | `instance_id.replace('\'', "''")` ✓ |
| `df.wait_for_completion()` | src/dsl.rs | `instance_id.replace('\'', "''")` ✓ |
| `df.start()` (db check) | src/dsl.rs | `db.replace('\'', "''")` ✓ |
| `df.instance_info()` | src/monitoring.rs | `instance_id.replace('\'', "''")` ✓ |
| `df.setvar()` | src/dsl.rs | `name.replace('\'', "''")` ✓ |
| `df.getvar()` | src/dsl.rs | `name.replace('\'', "''")` ✓ |

#### Variable substitution (`{var}`) — by design, but worth noting

`substitute_all_with_options()` in [src/types.rs](../src/types.rs) inserts user variables (`{name}`) as-is into SQL queries without quoting:

```rust
// 2. Substitute user vars: {name} (inserted as-is, no quoting)
for (name, value) in vars {
    result = result.replace(&pattern, value);
}
```

This is **intentional**: users write `SELECT {table_name}` expecting `{table_name}` to expand to a raw identifier. However, it means variable values are trusted SQL fragments. This is documented in the code comments but should be called out in the security spec.

Result substitution (`$name`) **does** quote string values: `format!("'{escaped}'")` with `s.replace('\'', "''")`.

**Remediation**:
- [x] **P0**: Fix `df.status()`: add `instance_id.replace('\'', "''")`
- [x] **P0**: Fix `df.result()`: add `instance_id.replace('\'', "''")`
- [x] **P1**: Add threat T12 to spec-security-model.md documenting variable substitution design
- [ ] **P2**: Consider parameterized queries (SPI with args) for all internal lookups

---

### Finding 2: `CREATE IF NOT EXISTS` / `CREATE OR REPLACE` (LOW)

**Claim**: Pre-creation/ownership attacks via these patterns.

**Evaluation**: Valid pattern, but **low practical risk** in this codebase.

All `CREATE TABLE IF NOT EXISTS` and `CREATE OR REPLACE FUNCTION` statements are inside `extension_sql!()` blocks in [src/lib.rs](../src/lib.rs), which execute during `CREATE EXTENSION` as a **superuser**. The attack scenario requires:

1. Attacker has `CREATE TABLE` privilege in the `df` schema
2. Attacker pre-creates tables before superuser installs the extension
3. The `df` schema must already exist (created by pgrx during extension install)

Since `CREATE EXTENSION pg_durable` requires superuser and creates the `df` schema itself, an attacker cannot pre-create objects in a schema that doesn't exist yet. The `CREATE OR REPLACE FUNCTION` patterns for PL/pgSQL helpers (`df.if_then_op`, `df.if_else_op`, `df.ensure_durofut`, `df.as_op`, `df.loop_prefix_op`) are standard pgrx conventions.

The pgrx-generated `CREATE OR REPLACE FUNCTION` statements for `#[pg_extern]` functions are inherent to the framework and cannot be avoided without upstream changes.

**Residual risk**: If a superuser manually creates the `df` schema and grants usage before installing the extension, pre-creation is possible. This is an operator error, not an extension vulnerability.

**Remediation**:
- [ ] **P3**: Document this as accepted risk (T13) in spec-security-model.md
- [ ] **P3**: Consider adding explicit `CREATE SCHEMA IF NOT EXISTS df AUTHORIZATION` with ownership check in early extension SQL

---

### Finding 3: Missing `SET search_path` in PL/pgSQL Functions (MEDIUM)

**Claim**: No `SET search_path` in PL/pgSQL functions enables search path manipulation.

**Evaluation**: **Partially valid**. Three PL/pgSQL helper functions and two SQL helper functions lack `SET search_path`:

| Function | Language | Schema-qualified calls? | Risk |
|----------|----------|------------------------|------|
| `df.if_then_op()` | plpgsql | Yes (`df.ensure_durofut`, `jsonb_build_object`) | LOW — all calls qualified |
| `df.if_else_op()` | plpgsql | Yes (`df.ensure_durofut`, `df.if`) | LOW — all calls qualified |
| `df.ensure_durofut()` | plpgsql | Yes (`df.sql`) | LOW — all calls qualified |
| `df.as_op()` | sql | Yes (`df.as`) | LOW — call qualified |
| `df.loop_prefix_op()` | sql | Yes (`df.loop`) | LOW — call qualified |

All function calls within these helpers are already schema-qualified (`df.*`). The built-in functions used (`jsonb_build_object`) are in `pg_catalog` which is always in `search_path`. The risk is therefore **low but not zero** — a future edit could introduce an unqualified reference.

The Rust `#[pg_extern]` functions use SPI, and all SPI SQL in the codebase uses schema-qualified table references (`df.instances`, `df.nodes`, `df.vars`).

**Best practice recommendation**: Add `SET search_path = pg_catalog, df` to all PL/pgSQL and SQL helper functions as defense-in-depth.

**Remediation**:
- [x] **P2**: Add `SET search_path = pg_catalog, df, pg_temp` to `df.if_then_op()`, `df.if_else_op()`, `df.ensure_durofut()`, `df.as_op()`, `df.loop_prefix_op()`
- [x] **P3**: Document as best practice in spec

---

### Finding 4: Control File Missing `schema =` (LOW — Intentional)

**Claim**: No fixed `schema =` in `pg_durable.control`.

**Evaluation**: **Valid but intentional**. The extension manages two schemas (`df` and `duroxide`). PostgreSQL's control file `schema` directive only supports a single schema. The `df` schema is created via `#[pg_schema] mod df {}` in pgrx. The `duroxide` schema is created via `sql/duroxide_install.sql` (which does `SET LOCAL search_path TO duroxide`).

`relocatable = false` is correctly set, preventing schema relocation attacks. `superuser = true` ensures only superusers can install.

**Remediation**:
- [ ] **P3**: Document why `schema =` is omitted in spec (multi-schema extension)

---

### Finding 5: Worker Connection Defaults / User Context (MOSTLY INVALID)

**Claim**: Background worker falls back to `postgres` superuser; unclear privilege context.

**Evaluation**: **Mostly invalid**. The claim conflates several unrelated concerns.

**Worker role**: Defaults to `azuresu` via GUC `pg_durable.worker_role`, not `postgres`. The default database is `postgres` (via `pg_durable.database` GUC), which is the target database name, not the user. Both are configurable at server startup.

**Per-user execution**: `connect_as_user()` in [src/types.rs](../src/types.rs) creates isolated sqlx connections authenticated as the submitting user's `login_role`, with `SET ROLE` to `submitted_by`. This is the implemented security model described in spec-security-model.md §5 and §8.5.

**Identity capture**: `GetSessionUserId()` and `GetOuterUserId()` are PostgreSQL C API calls that return OIDs, not user-controlled strings. These are stored as `REGROLE` in `df.instances` and `df.nodes`.

**One minor note**: The `get_worker_role()` fallback to `"azuresu"` is specific to the Azure deployment. In a non-Azure environment, this role may not exist. The extension SQL already validates the worker role is a superuser at `CREATE EXTENSION` time and warns if the role doesn't exist.

**Remediation**:
- [x] Already mitigated — no code changes needed
- [ ] **P3**: Clarify in spec that default worker role is `azuresu`, not `postgres`

---

### Finding 6: SSRF / Arbitrary HTTP (INVALID — Already Addressed)

**Claim**: `df.http()` allows arbitrary HTTP requests with no protection.

**Evaluation**: **Invalid**. This has been comprehensively addressed:

- **SSRF protection**: [src/ssrf.rs](../src/ssrf.rs) implements compile-time IP blocklist covering all RFC 1918, link-local, loopback, and reserved ranges
- **URL scheme validation**: Only `http://` and `https://` allowed
- **IPv4-mapped IPv6 handling**: Properly blocks `::ffff:127.0.0.1` etc.
- **Documented**: [spec-ssrf-protection.md](spec-ssrf-protection.md) contains full specification
- **Already in spec**: Threat T8 in spec-security-model.md

URL allowlist (GUC-based) and rate limiting are documented as future work (Threat T9) in the existing spec.

**Remediation**: None — already addressed. See spec-security-model.md §6 and spec-ssrf-protection.md.

---

### Finding 7: Secrets Table Permissions (NOT APPLICABLE)

**Claim**: Missing access controls for `df.secrets` table.

**Evaluation**: **Not applicable**. The `df.secrets` table does not exist in the codebase. It is only proposed in spec-security-model.md §8.1 and §4.4 as a future feature. No code, no table, no permissions to audit.

**Remediation**: None — feature not implemented. When implemented, follow the spec's permission model (REVOKE ALL FROM PUBLIC, admin-only mutators).

---

### Finding 8: Missing Identifier Quoting in Dynamic SQL (PARTIALLY VALID)

**Claim**: Manual string replacement instead of `quote_ident`/`quote_literal`.

**Evaluation**: **Partially valid**, but overlaps with Finding 1.

**Properly quoted**:
- `SET ROLE` in `connect_as_user()`: uses `effective_role.replace('"', "\"\"")` — correct double-quote escaping for identifiers ✓
- `login_role` passed to `PgConnectOptions::username()` — typed parameter, not string-interpolated ✓
- Single-quote escaping throughout `df.start()`, `df.cancel()`, etc. ✓

**Previously not quoted** (same as Finding 1, now fixed):
- `df.status()` — now escapes `instance_id`
- `df.result()` — now escapes `instance_id`

**Design note**: The codebase uses SPI with string formatting rather than parameterized SPI queries. pgrx's SPI API supports `Spi::get_one_with_args()` for parameterized queries, but this isn't used in the codebase. Migrating to parameterized queries would eliminate this class of vulnerability entirely.

**Remediation**:
- Same as Finding 1 (P0 fixes)
- [x] **P2**: Evaluate migrating internal SPI queries to `Spi::get_one_with_args()` / parameterized form

---

## Priority Summary

### P0 — Fix Immediately
- [x] Fix SQL injection in `df.status()` (Finding 1)
- [x] Fix SQL injection in `df.result()` (Finding 1)

### P2 — Should Fix
- [x] Add `SET search_path` to PL/pgSQL/SQL helper functions (Finding 3)
- [x] Add threat T12 to spec for variable substitution design (Finding 1)
- [x] Evaluate migrating to parameterized SPI queries (Finding 8)

### P3 — Document / Low Priority
- [ ] Document CREATE IF NOT EXISTS as accepted risk (Finding 2)
- [x] Document multi-schema rationale for missing `schema =` (Finding 4)
- [ ] Clarify default worker role name in spec (Finding 5)
- [x] Add search_path best practice to spec (Finding 3)
