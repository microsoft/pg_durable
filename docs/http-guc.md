# Plan: Convert HTTP Cargo Features to `pg_durable.http_mode` GUC

> **Working doc — not intended for merge.** Delete once all changes are landed and docs updated.

## Motivation

Today, HTTP access is controlled by three Cargo features (`http-allow-azure-domains`,
`http-allow-test-domains`, `http-allow-all`). Changing the HTTP mode requires
rebuilding the `.so` and restarting PostgreSQL.

A superuser-only, postmaster-context GUC removes the rebuild requirement. Benefits:

* Operators change policy in `postgresql.conf` — no recompilation.
* In production our admin roles are **not** superuser, so the GUC is invisible to
  them (`SUPERUSER_ONLY`).
* E2E tests switch modes via `ALTER SYSTEM` + restart instead of three separate
  `cargo pgrx install` invocations (saves ~2 min of compilation per mode).
* A single binary ships for all environments.

---

## Design

### GUC Definition

| Property | Value |
|----------|-------|
| Name | `pg_durable.http_mode` |
| Type | Enum (`PostgresGucEnum`) |
| Context | `Postmaster` (requires restart) |
| Flags | `SUPERUSER_ONLY` |
| Default | `azure` |

### Enum Values

| GUC Value | Replaces Cargo Feature | Behaviour |
|-----------|----------------------|-----------|
| `disabled` | *(none)* | All HTTP blocked — DSL-time error + execution-time rejection |
| `azure` | `http-allow-azure-domains` | Azure data-plane domains only + IP blocklist + DNS rebinding protection |
| `azure-and-test` | `http-allow-test-domains` | Same as `azure`, plus `api.github.com`, `httpbin.org`, `httpbingo.org` |
| `allow-all` | `http-allow-all` | No restrictions — all SSRF protections disabled (development only) |

### Core Pattern

Every `#[cfg(feature = "...")]` compile-time branch becomes a runtime match:

```rust
// BEFORE (compile-time):
#[cfg(feature = "http-allow-all")]
{ let _ = ip; None }
#[cfg(not(feature = "http-allow-all"))]
{ /* blocklist logic */ }

// AFTER (runtime):
match get_http_mode() {
    HttpMode::AllowAll => None,
    _ => { /* blocklist logic */ }
}
```

All code paths exist in every build; the GUC selects which path executes.

---

## Implementation Steps

### Phase 1 — GUC Infrastructure (`src/lib.rs`, `src/types.rs`)

1. **Define `HttpMode` enum** in `src/lib.rs` next to existing GUC statics:

   ```rust
   #[derive(PostgresGucEnum, Clone, Copy, PartialEq, Debug)]
   pub enum HttpMode {
       #[name = c"disabled"]
       Disabled,
       #[name = c"azure"]
       Azure,
       #[name = c"azure-and-test"]
       AzureAndTest,
       #[name = c"allow-all"]
       AllowAll,
   }

   pub static HTTP_MODE: GucSetting<HttpMode> = GucSetting::<HttpMode>::new(HttpMode::Azure);
   ```

2. **Register GUC** in `_PG_init()`:

   ```rust
   GucRegistry::define_enum_guc(
       c"pg_durable.http_mode",
       c"Controls outbound HTTP access for df.http(). \
         Values: disabled, azure (Azure domains only), \
         azure-and-test (+ test domains), allow-all (no restrictions).",
       c"",
       &HTTP_MODE,
       GucContext::Postmaster,
       GucFlags::SUPERUSER_ONLY,
   );
   ```

3. **Add accessor** in `src/types.rs` (follows existing `get_worker_role()` pattern):

   ```rust
   pub fn get_http_mode() -> crate::HttpMode {
       crate::HTTP_MODE.get()
   }
   ```

### Phase 2 — Convert `src/ssrf.rs` (~25 cfg gates)

4. **Replace `http_enabled()` const fn** → runtime function:

   ```rust
   pub fn http_enabled() -> bool {
       crate::types::get_http_mode() != crate::HttpMode::Disabled
   }
   ```

   > This keeps the call-site in `dsl.rs` unchanged; only the implementation moves
   > from `const fn` + `cfg!()` to a runtime GUC read.

5. **Make domain constants unconditional** — remove `#[cfg]` from:
   - `AZURE_DOMAIN_SUFFIXES` (lines 37-59) — remove `#[cfg(any(feature = "http-allow-azure-domains", feature = "http-allow-test-domains"))]`
   - `TEST_EXACT_DOMAINS` (line 61-63) — remove `#[cfg(feature = "http-allow-test-domains")]`

   The constants are always compiled; only consulted at runtime when mode matches.

6. **Convert `check_blocked_ipv4()`** (lines 84-101):
   - Remove both `#[cfg(feature = "http-allow-all")]` and `#[cfg(not(...))]` blocks.
   - Replace with: `if get_http_mode() == HttpMode::AllowAll { return None; }` at the top, then the blocklist logic unconditionally.

7. **Convert `check_blocked_ipv6()`** (lines 103-132): Same pattern.

8. **Convert `validate_url_allowlist()`** (lines 151-196):
   - Remove the triple-nested `#[cfg]` branches.
   - Replace with a `match get_http_mode()`:

   ```rust
   pub fn validate_url_allowlist(url: &str) -> Result<(), String> {
       match crate::types::get_http_mode() {
           HttpMode::AllowAll => Ok(()),
           HttpMode::Disabled => Err("Blocked: outbound HTTP requests are disabled. \
               Set pg_durable.http_mode in postgresql.conf and restart.".into()),
           HttpMode::Azure | HttpMode::AzureAndTest => {
               let host = extract_host(url).ok_or_else(|| ...)?;
               let host_lower = host.to_ascii_lowercase();

               // Block bare IPs
               if host_lower.parse::<IpAddr>().is_ok() { return Err(...); }

               // Azure suffixes
               for suffix in AZURE_DOMAIN_SUFFIXES {
                   if host_lower.ends_with(suffix) { return Ok(()); }
               }

               // Test domains (only in AzureAndTest)
               if crate::types::get_http_mode() == HttpMode::AzureAndTest {
                   for exact in TEST_EXACT_DOMAINS {
                       if host_lower == *exact { return Ok(()); }
                   }
               }

               Err(format!("Blocked: '{host}' is not in the allowed endpoint list..."))
           }
       }
   }
   ```

9. **Make `extract_host()` unconditional** — remove `#[cfg(not(feature = "http-allow-all"))]` (line 202). Dead-code elimination handles the case where it's unused at runtime.

### Phase 3 — Convert `src/activities/execute_http.rs` (1 cfg gate)

10. **Convert `build_client()`** (lines 55-68):
    - Remove `#[cfg(not(feature = "http-allow-all"))]`.
    - Replace with runtime check:

    ```rust
    let builder = if crate::types::get_http_mode() != crate::HttpMode::AllowAll {
        use crate::ssrf::{SsrfSafeResolver, SystemResolver};
        let resolver = SsrfSafeResolver::wrapping(Arc::new(SystemResolver));
        builder.dns_resolver(Arc::new(resolver))
    } else {
        builder
    };
    ```

11. **Update module doc comment** (lines 1-11) — replace Cargo feature references
    with GUC references.

### Phase 4 — Convert `src/dsl.rs` (1 call site)

12. **Update `df.http()` error message** (line 470-476):
    - `http_enabled()` call can remain (it now reads the GUC internally).
    - Change the error message from `"Rebuild with the 'http-allow-azure-domains' Cargo feature..."` to `"Set pg_durable.http_mode to 'azure' (or higher) in postgresql.conf and restart the server."`.

### Phase 5 — Remove Cargo Features from `Cargo.toml`

13. Delete these three lines from `[features]`:
    ```
    http-allow-all = []
    http-allow-azure-domains = []
    http-allow-test-domains = ["http-allow-azure-domains"]
    ```

### Phase 6 — Update Build Infrastructure

14. **`Dockerfile`** line 48 — remove `--features http-allow-test-domains`:
    ```
    RUN cargo pgrx package --pg-config /usr/lib/postgresql/17/bin/pg_config
    ```

15. **`Makefile`** line 48 — remove `--features http-allow-test-domains`:
    ```
    cargo pgrx install
    ```

16. **`.github/workflows/ci.yml`**:
    - Line 178: `cargo clippy --no-default-features --features pg${{ matrix.pg_version }} -- -D warnings`
    - Line 182: `cargo pgrx test pg${{ matrix.pg_version }}`

### Phase 7 — Rewrite E2E Test Harness (`scripts/test-e2e-local.sh`)

17. **Remove rebuild-based phase switching**:
    - Delete `build_extension_no_http()` and `build_extension_http_allow_all()`.
    - Delete `CURRENT_FEATURES` variable and all checks against it.
    - `build_extension()` becomes a simple `cargo pgrx install --pg-config=...` (no feature flags).

18. **HTTP phases now use `ALTER SYSTEM` + restart**:
    - `http-disabled` phase: `ALTER SYSTEM SET pg_durable.http_mode = 'disabled';` then restart PG.
    - `http-allow-all` phase: `ALTER SYSTEM SET pg_durable.http_mode = 'allow-all';` then restart PG.
    - `standard` phase: `ALTER SYSTEM SET pg_durable.http_mode = 'azure-and-test';` (or set in the initial config).
    - After phase completes, `ALTER SYSTEM RESET pg_durable.http_mode;` then restart.

19. **Set default for standard phase**: Ensure `postgresql.conf` (or the test harness
    startup) sets `pg_durable.http_mode = 'azure-and-test'` so `06_http_and_ssrf.sql`
    tests pass against test domains.

### Phase 8 — Update E2E Test SQL

20. **`tests/e2e/sql/47_http_dsl_disabled.sql`**:
    - Update header comment: "runs in the http-disabled phase, which sets `pg_durable.http_mode = 'disabled'`" (not "builds without features").
    - Update `SQLERRM ILIKE` check: match on the new error message (`%http_mode%` instead of `%Rebuild%`).

21. **`tests/e2e/sql/48_http_allow_all.sql`**:
    - Update header comment: "runs in the http-allow-all phase, which sets `pg_durable.http_mode = 'allow-all'`".

22. **`tests/e2e/sql/06_http_and_ssrf.sql`**:
    - Update header comment from "Requires: pg_durable built with --features http" to "Requires: `pg_durable.http_mode = 'azure-and-test'`".

### Phase 9 — Update Unit Tests in `src/lib.rs`

23. **Remove `#[cfg(any(feature = ...))]` guards** from all HTTP unit tests
    (~8 tests, lines 2506-2790).

24. **Handle Postmaster GUC limitation**: Since `Postmaster` GUCs can't be changed
    per-test in `#[pg_test]`, and the default is `azure`, the HTTP unit tests will
    run with `http_mode = azure`. This is correct — they test DSL node construction
    which should work in any non-disabled mode.

25. **Option for ssrf.rs unit tests**: Refactor SSRF functions to accept mode as a
    parameter internally, with public wrappers that read the GUC. This lets native
    `#[test]` (non-pg) unit tests exercise all four modes without restarting PG.

    ```rust
    // Internal: accepts mode explicitly (testable)
    fn validate_url_allowlist_for_mode(url: &str, mode: HttpMode) -> Result<(), String> { ... }

    // Public: reads GUC (called from activity + DSL)
    pub fn validate_url_allowlist(url: &str) -> Result<(), String> {
        validate_url_allowlist_for_mode(url, crate::types::get_http_mode())
    }
    ```

    Apply the same pattern to `check_blocked_ip()`, `http_enabled()`, and
    `build_client()` where useful.

### Phase 10 — Update Documentation

26. **`docs/http-security.md`**: Replace all "Cargo feature" references with GUC
    references. Update the feature table, error messages, and admin instructions.
    The three-layer security model documentation stays the same — layers 1-3 are
    unchanged, only the mechanism that selects the mode changes.

27. **`USER_GUIDE.md`**: Add `pg_durable.http_mode` to the Configuration section.
    Replace any "rebuild with features" language.

28. **`docs/spec-http-support.md`**: Replace feature references with GUC.

29. **`.github/copilot-instructions.md`**: Remove `--features http-allow-test-domains`
    from build commands. Update "Common Tasks" to reflect the GUC.

30. **`docs/api-reference.md`**: If it references HTTP features, update to GUC.

---

## Files Changed

| File | What Changes |
|------|-------------|
| `src/lib.rs` | Add `HttpMode` enum + `HTTP_MODE` static + `_PG_init()` registration; remove `#[cfg]` from HTTP unit tests |
| `src/types.rs` | Add `get_http_mode()` accessor |
| `src/ssrf.rs` | Convert ~25 `#[cfg(feature)]` gates to runtime `get_http_mode()` checks; make constants unconditional; refactor for testability |
| `src/activities/execute_http.rs` | Convert 1 `#[cfg]` gate in `build_client()`; update module doc comment |
| `src/dsl.rs` | Update `df.http()` error message |
| `Cargo.toml` | Remove 3 HTTP feature declarations |
| `Dockerfile` | Remove `--features http-allow-test-domains` |
| `Makefile` | Remove `--features http-allow-test-domains` |
| `.github/workflows/ci.yml` | Remove `--features http-allow-test-domains` from clippy + test commands |
| `scripts/test-e2e-local.sh` | Replace rebuild-based phases with `ALTER SYSTEM` + restart; remove `CURRENT_FEATURES` tracking |
| `scripts/test-upgrade.sh` | Remove `--features http-allow-test-domains` from `cargo pgrx install` (line 198) |
| `tests/e2e/sql/06_http_and_ssrf.sql` | Update header comment |
| `tests/e2e/sql/47_http_dsl_disabled.sql` | Update header comment + error message assertion |
| `tests/e2e/sql/48_http_allow_all.sql` | Update header comment |
| `docs/http-security.md` | Replace all feature references with GUC |
| `USER_GUIDE.md` | Add GUC documentation |
| `docs/spec-http-support.md` | Replace feature references |
| `.github/copilot-instructions.md` | Remove feature flags from commands |

---

## What Does Not Change

* **SQL schema** — `df.nodes`, `df.http()` signature, `df.grant_usage()`,
  `REVOKE ... FROM PUBLIC` — all unchanged. No upgrade script needed.
* **Security model** — Three-layer validation (privilege → scheme → allowlist →
  DNS resolver) is identical; only the selector changes from compile-time to runtime.
* **Activity registration** — `execute_http` is always registered. When mode is
  `disabled`, the execution-time guard in `validate_url_allowlist()` blocks the
  request (identical to today's behavior when no feature is compiled in).
* **Orchestration code** — `execute_function_graph.rs` HTTP node handling is
  unchanged (no feature gates there).
* **Backward compatibility** — No binary compat concern (this is a `.so`-only
  change; no schema DDL). Upgrade tests should pass as-is.

---

## Verification Checklist

1. `cargo build --features pg17` — compiles without warnings or dead-code from removed features
2. `cargo clippy --features pg17` — clean
3. `cargo fmt -p pg_durable -- --check` — formatted
4. `./scripts/test-unit.sh` — unit tests pass (HTTP tests now run unconditionally)
5. `./scripts/test-e2e-local.sh` — all phases pass:
   - `standard` (http_mode = `azure-and-test`): `06_http_and_ssrf.sql` passes
   - `http-disabled` (http_mode = `disabled`): `47_http_dsl_disabled.sql` passes
   - `http-allow-all` (http_mode = `allow-all`): `48_http_allow_all.sql` passes
6. `./scripts/test-upgrade.sh` — upgrade tests pass (no SQL schema change)
7. Manual: `SHOW pg_durable.http_mode;` as superuser → `azure`
8. Manual: `SHOW pg_durable.http_mode;` as non-superuser → error or hidden
9. `grep -rn 'cfg.*feature.*http' src/` → zero matches

---

## Decisions

| Decision | Rationale |
|----------|-----------|
| Default = `azure` | Production-ready out of the box. Azure data-plane domains allowed with full SSRF protection. |
| Context = `Postmaster` | Requires restart. Matches existing GUCs. Prevents session-level escalation by a compromised superuser session. |
| Flags = `SUPERUSER_ONLY` | Non-superuser roles (including admin roles) cannot see or change the GUC. |
| No SQL schema changes | `df.http()` function signature, `df.nodes` table, privilege model are all unchanged. No upgrade script needed. |
| Refactor ssrf.rs for testability | Accept `HttpMode` as parameter internally so `#[test]` (non-pg) unit tests can exercise all four modes without PG restart. |

---

## Open Questions / Considerations

1. **Unit test strategy for Postmaster GUC**: `#[pg_test]` cannot change Postmaster
   GUCs mid-run. The refactored internal functions (accepting `HttpMode` as parameter)
   solve this for ssrf.rs. The `#[pg_test]` HTTP DSL tests will run with the default
   mode (`azure`), which is sufficient for verifying node construction.

---

### Resolved During Planning

* **`deploy-acr.sh`**: No HTTP feature flags — no change needed.
* **`docker-compose.yml`**: No HTTP feature flags — no change needed.
* **`scripts/test-upgrade.sh`** line 198: passes `--features http-allow-test-domains`.
  **Must update** — remove the flag. Added to Files Changed table above.
