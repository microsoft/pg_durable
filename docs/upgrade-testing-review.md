# Review: Upgrade Testing Infrastructure

**Model: Claude Opus 4.6  
**Review: [#54 - Bump version to 0.2.0 and add upgrade testing infrastructure](https://github.com/microsoft/pg_durable/pull/54)  
**Spec/Design: [docs/upgrade-testing.md](upgrade-testing.md)  
**Files changed: 9 files, +4724 / −4 lines  
**Status:** Not Addressed. All issues identified are non-blocking, left for later.

---

## Summary

This PR introduces an upgrade testing framework for pg_durable, covering three scenarios:

- **Scenario A** — Schema upgrade correctness (upgraded schema matches fresh install)
- **Scenario B1** — Binary backward compatibility (new `.so` against all old schemas)
- **Scenario B2** — Data compatibility after upgrade (pre-upgrade data survives `ALTER EXTENSION UPDATE`)

The implementation comprises a 780-line shell test script, a comprehensive strategy document, the v0.1.1 install SQL fixture, an empty v0.1.1→v0.2.0 upgrade script, CI integration, version bump to 0.2.0, and updates to copilot-instructions.

---

## Review Areas

### 1. Conceptual Model & Strategy (upgrade-testing.md)

**Verdict: Strong.** The three-scenario framework is well-reasoned and directly addresses the real-world deployment model.

**Strengths:**
- The distinction between **chain tests** (A, B2) and **direct-contact tests** (B1) is clearly articulated and correctly justified. Chain tests only need to test the immediately previous version because each link was validated by its own CI. B1 must test all previous versions because there is no transitive chain — a customer on v0.1.1 with a v0.5.0 `.so` has never seen an intermediate upgrade.
- Major version boundary semantics are well-defined: B1 compat can be dropped at a major boundary while A/B2 upgrade chains still work across majors.
- The "Preparing for the next version" section provides clear, actionable steps for minor, first-after-major, and major releases. The key insight that only the first version per major needs a checked-in fixture (intermediates are reconstructed via `ALTER EXTENSION UPDATE` chaining) keeps the fixture count minimal.
- The backward compatibility patterns section (runtime schema detection, cross-schema SQL, pg_catalog version check) gives developers practical tools for future work.

**Suggestions:**
- The doc could briefly mention what happens if a developer **forgets** to update the upgrade script — i.e., Scenario A will catch it automatically. This reinforces the safety net role.
- The "Future work" section mentions pg_regress-style upgrade tests as complementary. It might be worth noting that the current approach is *strictly more thorough* since it covers B1/B2, making this clearly a "nice-to-have" rather than a gap.

---

### 2. Test Script Correctness (test-upgrade.sh)

**Verdict: Solid implementation with a few robustness concerns.**

#### 2.1 Version Discovery Logic

The version detection is well-implemented:
- `CURRENT_VERSION` from `Cargo.toml`, `PREV_VERSION` from upgrade script naming, `FIRST_VERSION` from fixture files, `ALL_PREV_VERSIONS` from all upgrade script "from" versions.
- The regex-based filename parsing (`^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)\.sql$`) is strict and avoids matching upgrade scripts or other files.
- `first_fixture_for_major()` correctly finds the earliest fixture for a given major version using `sort -V`.

**Issue — IFS manipulation pattern (line 140):**
```bash
IFS=$'\n' ALL_PREV_VERSIONS=($(sort -V -u <<< "${ALL_PREV_VERSIONS[*]}")); unset IFS
```
This relies on word-splitting with modified IFS. While functional, `mapfile` / `readarray` would be more robust and idiomatic:
```bash
mapfile -t ALL_PREV_VERSIONS < <(printf '%s\n' "${ALL_PREV_VERSIONS[@]}" | sort -V -u)
```

#### 2.2 Server Lifecycle

Server management is competent: the script checks `pg_isready`, restarts if already running (to reload the new `.so`), and has a trap-based cleanup. The `--keep` flag for debugging is a nice touch.

**Concern — shared port with E2E tests:** Both `test-e2e-local.sh` and `test-upgrade.sh` use port `28800 + PG_VERSION`. CI runs them sequentially (E2E before upgrade), so no conflict. But running both locally in parallel would collide. This is documented implicitly by the port calculation but not called out — a comment would help.

#### 2.3 `create_extension_at_version()` 

This function drops any existing extension and installs at the target version by creating at the first fixture version and then calling `ALTER EXTENSION UPDATE TO '${target_version}'` if needed. PostgreSQL handles intermediate chaining automatically, which is correct.

**Issue — suppressed `CREATE EXTENSION` errors:** The `CREATE EXTENSION` output is redirected to `/dev/null`:
```bash
"$PSQL" ... -c "CREATE EXTENSION pg_durable VERSION '${base_version}';" >/dev/null 2>&1
```
If this fails (e.g., corrupted fixture SQL), stderr is suppressed and the test proceeds without the extension, leading to misleading downstream failures. The `ALTER EXTENSION UPDATE` on the next line *does* use `ON_ERROR_STOP=1`, but only if `target_version != base_version`. When installing the base version directly, there's no error check.

**Recommendation:** Fail explicitly if `CREATE EXTENSION` fails:
```bash
"$PSQL" ... -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION pg_durable VERSION '${base_version}';" >/dev/null 2>&1 || return 1
```

#### 2.4 `run_test()` and `eval`

```bash
if eval "$test_func"; then
```
The `eval` is used to call function names passed as strings. Since all callers pass hardcoded function names (e.g., `run_test "name" test_b1_setvar`), this is safe in practice. However, `eval` is unnecessary — `"$test_func"` (direct invocation) is cleaner and avoids the eval risk:
```bash
if "$test_func"; then
```

#### 2.5 `run_sql_capture()` — stderr mixed into stdout

```bash
result=$("$PSQL" ... -c "$sql" 2>&1)
```
Merging stderr into stdout means psql error messages (e.g., `ERROR: relation "df.nodes" does not exist`) become the "result" that `assert_sql_equals` compares. This causes confusing failures like:
```
Expected: OK
Got: ERROR: function df.setvar(unknown, unknown) does not exist
```
The error *is* shown, but only because it happens to be in the "Got" field. A cleaner pattern would capture stderr separately and display it on failure.

#### 2.6 Missing `set -o pipefail`

The script uses `set -e` but not `set -o pipefail`. Piped commands where the left side fails silently succeed. Current usage is minimal (mostly `sort -V | head/tail`), but this could bite if pipes are added later.

#### 2.7 Global B1_INSTANCE_ID dependency chain

`B1_INSTANCE_ID` is set in `test_b1_start_and_complete` and used by `test_b1_status_instance`, `test_b1_result`, `test_b1_list_instances`, and `test_b1_instance_info`. If the start-and-complete test fails, `B1_INSTANCE_ID` is empty and all dependent tests fail with misleading empty-string errors. The same pattern applies to `B2_PRE_INSTANCE_ID` and friends.

This is a pragmatic trade-off (test interdependency vs. duplication) and is fine for an upgrade test suite that runs sequentially. Just be aware that a single early failure cascades.

---

### 3. Schema Snapshot Completeness

**Verdict: Good coverage of the primary schema objects, with known gaps.**

The `SCHEMA_QUERY` captures:
- ✅ Columns (name, type, default, nullability, ordinal position)
- ✅ Types (composite, domain, enum, range — excluding implicit row types)
- ✅ Constraints (PK, FK, unique — via `information_schema.key_column_usage`)
- ✅ RLS policies (using_expr, check_expr, permissive)
- ✅ RLS enabled/disabled status per table
- ✅ Indexes (full `pg_get_indexdef`)
- ✅ Table grants
- ✅ Routine grants (including `PUBLIC` grantee)
- ✅ Schema grants
- ✅ Functions (name, arguments, return type)

**Gaps:**

| Object | Status | Risk |
|--------|--------|------|
| Triggers | ❌ Not captured | Low — `df` schema currently has no triggers; duroxide triggers are in a separate schema. If `df` triggers are added in the future, this would silently miss mismatches. |
| `COMMENT ON` metadata | ❌ Not captured | Low — cosmetic, but comments are part of `pg_description` and could drift between upgrade and fresh install without being caught. |
| `duroxide` schema | ❌ Not captured | Medium — the extension creates both `df` and `duroxide` schemas. Changes to duroxide tables/triggers/functions would not be caught. However, duroxide DDL comes from vendored upstream migrations via `gen-duroxide-install-sql.sh`, so the delta is likely to originate only from migration sync errors (which have their own verification script). This is a reasonable design choice, but worth documenting explicitly. |
| CHECK constraints on column definitions | ⚠️ Partially captured | Constraints from `information_schema.table_constraints` only include those that have key columns. Standalone CHECK constraints might be missed. The `df` schema uses `WITH CHECK` in RLS (captured separately) but not standalone CHECKs, so this is not a current risk. |

**Recommendation:** Add a comment in the script explaining why only the `df` schema is captured (duroxide is handled by migration sync verification). Consider adding trigger snapshot for future-proofing.

---

### 4. Test Coverage Quality

#### 4.1 Scenario A

Clean and effective. Compares upgraded vs. fresh-install schemas using a deterministic snapshot. The diff output with `--verbose` is well-handled (concise by default, full diff with flag).

#### 4.2 Scenario B1

Good breadth of API coverage:
- Variable lifecycle: `setvar`, `getvar`, `unsetvar`, `clearvars`
- Version reporting: `df.version()`
- DSL construction: `df.sql()`, operator `~>`
- Full execution: `df.start()` → `wait_for_completion()` → result verification
- Monitoring: `df.status()`, `df.result()`, `df.list_instances()`, `df.instance_info()`
- Edge case: `df.status()` on nonexistent instance

**Not currently tested (noted in the doc's expand-per-version table):**
- `df.if()`, `df.loop()`, `df.sleep()`, `df.http()` — DSL construction only, no execution
- `df.seq()` — the composite sequence operator
- Parallel operator `&` / `|` 
- Variable capture (`{var_name}` substitution) is tested as part of `test_b1_start_and_complete`, which is good
- RLS enforcement — no test verifying that non-superuser access control works on the old schema

These are reasonable omissions for v0.2.0 (the doc explicitly says "expand per-version as the API surface grows"), but worth tracking.

#### 4.3 Scenario B2

Good coverage of the upgrade data lifecycle:
1. Create data under old version (vars + completed instance)
2. Start in-flight work (sleep + SQL chain)
3. Upgrade via `ALTER EXTENSION UPDATE`
4. Verify pre-upgrade data accessible
5. Verify in-flight work completes
6. Verify new operations work post-upgrade

**Concern — in-flight timing (line 719):** The in-flight test uses `df.sleep(2)` to create work that should still be running when the upgrade happens. The sequence is:
1. Start inflight instance (2-second sleep)
2. Wait for pre-instance to complete (could take time)
3. Run `ALTER EXTENSION UPDATE`
4. Assert inflight completed

If step 2 takes > 2 seconds (slow CI, high load), the inflight instance may have already completed before the upgrade, making the test vacuous (it passes but doesn't test what it claims). Consider increasing the sleep duration or verifying the instance status is NOT completed before running the upgrade.

---

### 5. SQL Fixtures

#### 5.1 `sql/pg_durable--0.1.1.sql` (3726 lines)

This is a pgrx-generated install SQL captured from the v0.1.1 release (the `main` branch is tagged `v0.1.1`). It contains:
- df schema: tables, RLS policies, indexes, functions
- duroxide schema: queues, triggers, functions

This is the correct approach — the fixture must exactly reproduce what v0.1.1 would install.

**Observation:** The file contains a `This file is auto generated by pgrx` header. Since it's now a manually-managed fixture, it might be worth adding a header comment explaining its purpose (e.g., "Checked-in copy of the v0.1.1 install SQL for upgrade testing. Do not regenerate.").

#### 5.2 `sql/pg_durable--0.1.1--0.2.0.sql`

Correctly starts as an empty upgrade script with clear comments explaining its purpose. The `-- (no changes yet)` placeholder sets the right expectation.

---

### 6. CI Integration

**Verdict: Clean and appropriate.**

The upgrade test step is placed after E2E tests and before the artifact upload step. It runs per-matrix entry (currently just pg17) with `--pg-version` parametrization.

**Note:** The artifact upload step has `if: failure()` — this captures PostgreSQL logs on *any* prior step failure, including upgrade test failures. Good.

**Missing:** There's no separate artifact upload for upgrade-specific diagnostics (e.g., the schema diff). If Scenario A fails, the diff is printed to stdout (captured in the CI log), which is likely sufficient. The `--verbose` flag is not used in CI, so only the concise (head -40) diff is shown. For CI, `--verbose` might be worth enabling to avoid needing to reproduce locally.

---

### 7. Version Bump & Config Changes

- `Cargo.toml` bumped from 0.1.1 → 0.2.0 — correct, needed for the upgrade script naming
- `Cargo.lock` updated to match — correct
- `Makefile` `DATA` line removed — correct, pgrx manages extension file installation; the fixture is now in `sql/` and copied to the extension directory by the test script
- `pg_durable.control` uses `@CARGO_VERSION@` template — no change needed, pgrx substitutes automatically
- copilot-instructions updated with upgrade test commands, backward compat pattern, schema change workflow, spec doc requirements — thorough and valuable

---

### 8. Documentation Quality (copilot-instructions.md additions)

**Verdict: Excellent.** The additions integrate upgrade testing naturally into the existing development workflow:

- Added `scripts/test-upgrade.sh` to dev commands
- Added "Binary Backward Compatibility" to Critical Patterns
- Added "Changing the extension schema" and "Writing a spec or design doc" to Common Tasks
- Updated merge checklist to include upgrade tests
- Updated CI pipeline description

These changes ensure that future development (human or AI-assisted) is aware of upgrade testing requirements from the start.

---

## Summary of Findings

### Issues to Address

| # | Severity | Area | Description |
|---|----------|------|-------------|
| 1 | Medium | Script | `create_extension_at_version` suppresses `CREATE EXTENSION` errors — add `|| return 1` |
| 2 | Low | Script | `eval "$test_func"` can be replaced with `"$test_func"` (direct invocation) |
| 3 | Low | Script | IFS manipulation pattern — `mapfile` would be cleaner |
| 4 | Low | Script | `run_sql_capture` merges stderr into stdout, causing confusing failure messages |
| 5 | Low | Script | B2 in-flight test timing — `df.sleep(2)` may complete before upgrade on slow systems |
| 6 | Low | Schema | Schema snapshot doesn't capture triggers — low risk now but worth future-proofing |

### Observations (not blocking)

| # | Area | Note |
|---|------|------|
| A | Schema | `duroxide` schema not in snapshot — intentional (migration sync handles it), but worth a comment |
| B | Script | No `set -o pipefail` |
| C | Script | B1 test functions share state via global `B1_INSTANCE_ID` — pragmatic, but failures cascade |
| D | CI | `--verbose` not used in CI; consider enabling for easier debugging of Scenario A failures |
| E | SQL | v0.1.1 fixture has pgrx "auto generated" header that could be misleading — consider adding a purpose comment |
| F | Coverage | DSL functions `if`, `loop`, `sleep`, `http`, `seq` and parallel operators not B1-tested yet (documented as future work) |

### Strengths

- The three-scenario framework directly addresses the real deployment model and is well-justified
- Chain test vs. direct-contact test reasoning is rigorous
- The schema snapshot query is comprehensive (10 object categories)
- B1 generalizes to all previous versions within a major — crucial for long-lived customers
- B2 tests the full data lifecycle including in-flight work
- copilot-instructions updates ensure the upgrade workflow is discoverable
- Minimal fixture strategy (one per major version) keeps maintenance low
- The docs provide clear "Preparing for the next version" checklists for minor, first-after-major, and major releases
