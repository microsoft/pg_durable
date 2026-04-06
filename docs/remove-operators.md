# Plan: Remove DSL Operators

## Decision

Remove all seven custom SQL operators (`~>`, `|=>`, `&`, `|`, `?>`, `!>`, `@>`) from pg_durable. The function equivalents (`df.seq`, `df.as`, `df.join`, `df.race`, `df.if`, `df.loop`) are retained as the only way to compose durable function graphs. To compensate for the loss of `~>` chaining, `df.seq` is upgraded to accept variadic arguments.

**This is a breaking change.** Any SQL that uses the operator syntax will fail after upgrade.

## Motivation

The operators were syntactic sugar for the underlying `df.*` functions. They add complexity (helper SQL functions, `ensure_durofut`, partial-if state machine) without sufficient benefit at this time.

## Assessment: Are the operators worth keeping?

### Where operators help

- **`~>` (sequence)** is the most-used operator (~50 occurrences across tests). It chains steps linearly and reads naturally: `'A' ~> 'B' ~> 'C'`. Without it, binary `df.seq` forces ugly nesting: `df.seq(df.seq('A', 'B'), 'C')`. However, a **variadic `df.seq`** (`df.seq('A', 'B', 'C')`) achieves the same readability without custom operator machinery.
- **`|=>` (name/capture)** reads as a postfix annotation: `'SELECT id' |=> 'row_id'`. The function form `df.as('SELECT id', 'row_id')` is slightly less fluent but clear.
- **`&` and `|` (join/race)** are compact: `'A' & 'B'`. But these are rarely chained (most uses are 2-branch), so `df.join('A', 'B')` is fine.

### Where operators hurt

- **`?>` / `!>` (if-then-else)** require a complex two-phase state machine: `?>` produces a `_partial_if` JSON marker, `!>` completes it. This is the most fragile operator — it requires three helper SQL functions (`if_then_op`, `if_else_op`, `ensure_durofut`) and partial JSON state passing. `df.if(cond, then, else)` is simpler, more explicit, and less error-prone.
- **`@>` (loop prefix)** is the least intuitive operator. PostgreSQL users don't expect prefix operators. `df.loop(body)` is self-documenting.
- **Operator precedence is a pitfall.** The grammar has 6 precedence levels. Users must know that `&` binds tighter than `~>`, that `|` and `&` have different precedence, and that `?>` / `!>` have the loosest binding. Multiple bug reports and confusion in examples trace back to unexpected grouping. Function calls with explicit parentheses have no ambiguity.
- **Operator collision risk.** `&` and `|` are common PostgreSQL operators (bitwise AND/OR on integers). Custom operators on `text` operands can shadow or conflict with future PostgreSQL features or other extensions.
- **Maintenance cost.** The operator infrastructure is ~140 lines of `extension_sql!` (5 helper SQL functions + 7 `CREATE OPERATOR` statements) plus `docs/grammar.md` (170 lines of precedence documentation). Every new node type must be added to the `ensure_durofut` valid-type list in two places (SQL + Rust). Removing operators deletes this entire category of maintenance.
- **Tooling friction.** SQL formatters, linters, and syntax highlighters don't know about custom operators. `df.*` functions are standard SQL function calls that every tool handles correctly.

### Other reasons to keep operators

- **Marketing / first impressions.** `'A' ~> 'B' ~> 'C'` looks striking in a README. But this is a one-time effect — ongoing usability matters more, and variadic `df.seq('A', 'B', 'C')` is nearly as concise.
- **Familiarity for Elixir/F# users.** The pipe-forward style is familiar to functional programmers. But the primary audience is PostgreSQL/SQL developers, not FP developers.
- **No other reason was identified.** The operators do not enable any capability that functions don't. They are pure syntax sugar.

### Verdict

Remove all operators. The only operator with a meaningful readability advantage (`~>`) is fully replaced by variadic `df.seq`. The remaining operators range from neutral (`&`, `|`, `|=>`) to actively harmful (`?>` / `!>` state machine, `@>` prefix confusion, precedence pitfalls).

## Scope

### Operators to remove

| Operator | Function retained | Helper SQL functions to drop |
|----------|-------------------|------------------------------|
| `~>` | `df.seq(a, b)` | _(none — operator called `df.seq` directly)_ |
| `\|=>` | `df.as(fut, name)` | `df.as_op(fut, name)` |
| `&` | `df.join(a, b)` | _(none — operator called `df.join` directly)_ |
| `\|` | `df.race(a, b)` | _(none — operator called `df.race` directly)_ |
| `?>` | `df.if(cond, then, else)` | `df.if_then_op(condition, then_branch)` |
| `!>` | `df.if(cond, then, else)` | `df.if_else_op(partial_if, else_branch)` |
| `@>` | `df.loop(body)` | `df.loop_prefix_op(body)` |

### Additional SQL function to drop

`df.ensure_durofut(val)` — only used by the `?>` / `!>` helper functions. The Rust `Durofut::ensure()` handles auto-wrapping for all `df.*` functions, so this SQL-level helper is unused once operators are removed.

---

## Implementation Steps

### Phase 0: Make `df.seq` variadic

This must land first — all subsequent test/doc rewrites depend on it.

#### Rust implementation (`src/dsl.rs`)

Add a new variadic overload alongside the existing binary `df.seq`:

```rust
use pgrx::datum::VariadicArray;

/// Creates a sequence node from 2+ steps.
/// Folds left into a binary THEN chain for the on-disk representation.
/// SELECT df.seq('A', 'B', 'C') is equivalent to df.seq(df.seq('A', 'B'), 'C').
#[pg_extern(name = "seq", schema = "df")]
pub fn seq_variadic(steps: VariadicArray<&str>) -> String {
    let futs: Vec<Durofut> = steps
        .iter()
        .flatten() // skip NULLs
        .map(|s| Durofut::ensure(s))
        .collect();

    if futs.len() < 2 {
        pgrx::error!("df.seq requires at least 2 arguments");
    }

    // Fold left: seq(A, B, C) → THEN(THEN(A, B), C)
    futs.into_iter()
        .reduce(|acc, next| Durofut {
            node_type: "THEN".to_string(),
            left_node: Some(Box::new(acc)),
            right_node: Some(Box::new(next)),
            ..Default::default()
        })
        .unwrap()
        .to_json()
}
```

pgrx 0.16.1 supports `VariadicArray<T>` in `#[pg_extern]` functions. PostgreSQL will generate `CREATE FUNCTION df.seq(VARIADIC steps text[])` which coexists with the existing binary `df.seq(text, text)` via standard function overloading. PostgreSQL resolves `df.seq('A', 'B')` to the binary form and `df.seq('A', 'B', 'C')` to the variadic form.

**Note on the binary overload:** Keep the existing binary `df.seq(a, b)` as-is. It avoids array allocation overhead for the common 2-argument case and maintains backward compatibility with any code already calling `df.seq(a, b)`.

#### Unit tests

Add tests for variadic `df.seq`:

| Test | What it verifies |
|------|-----------------|
| `test_seq_variadic_3` | `df.seq('A', 'B', 'C')` produces nested THEN nodes |
| `test_seq_variadic_many` | 5+ arguments fold correctly |
| `test_seq_variadic_2_falls_through` | `df.seq('A', 'B')` still works (resolves to binary overload) |
| `test_seq_variadic_1_errors` | Single argument raises error |
| `test_seq_variadic_with_mixed_types` | `df.seq('plain SQL', df.sleep(1), df.http(...))` — auto-wrap + durofut mix |

#### Upgrade considerations

No upgrade script change needed — this is a new function overload (additive). Fresh installs pick it up from pgrx-generated SQL. For B1, old schemas simply won't have the variadic overload (it won't be callable until `ALTER EXTENSION UPDATE`), but the binary `df.seq` continues to work.

### Phase 1: Upgrade script DDL

**File:** `sql/pg_durable--0.1.1--0.2.0.sql` (or next version's upgrade script if 0.2.0 is already shipped)

Add the following DDL in order (operators must be dropped before their backing functions):

```sql
-- ============================================================
-- Remove DSL operators (breaking change)
-- ============================================================

-- Drop operators (must precede dropping their backing functions)
DROP OPERATOR IF EXISTS ~>  (text, text);
DROP OPERATOR IF EXISTS |=> (text, text);
DROP OPERATOR IF EXISTS &   (text, text);
DROP OPERATOR IF EXISTS |   (text, text);
DROP OPERATOR IF EXISTS ?>  (text, text);
DROP OPERATOR IF EXISTS !>  (text, text);
DROP OPERATOR IF EXISTS @>  (NONE, text);   -- prefix operator: LEFTARG = NONE

-- Drop operator-only helper functions (not used by df.* API)
DROP FUNCTION IF EXISTS df.as_op(text, text);
DROP FUNCTION IF EXISTS df.if_then_op(text, text);
DROP FUNCTION IF EXISTS df.if_else_op(text, text);
DROP FUNCTION IF EXISTS df.ensure_durofut(text);
DROP FUNCTION IF EXISTS df.loop_prefix_op(text);
```

### Phase 2: Remove from fresh-install SQL (`src/lib.rs`)

Remove the entire `extension_sql!` block named `"create_operators"` (lines ~505–650 of `src/lib.rs`). This block contains:

- 7 `CREATE OPERATOR` statements
- 5 `CREATE OR REPLACE FUNCTION` statements (`as_op`, `if_then_op`, `if_else_op`, `ensure_durofut`, `loop_prefix_op`)

Also update the `requires = [...]` list and any `extension_sql_file!` ordering that depends on `"create_operators"`.

### Phase 3: Remove unit tests for operators (`src/lib.rs`)

Remove the following `#[pg_test]` functions that test operator behavior:

| Test function | What it tests |
|---------------|---------------|
| `test_seq_operator_via_sql` | `~>` operator |
| `test_as_operator_via_sql` | `\|=>` operator |
| `test_autowrap_via_sql_operator` | `~>` with auto-wrap |
| `test_autowrap_via_as_operator` | `\|=>` with auto-wrap |

Verify that `test_explain_basic` and `test_explain_cleans_session_nodes` also use operator syntax and rewrite them to use `df.seq()` / `df.as()` if needed.

### Phase 4: Rewrite E2E tests

Every E2E test that uses operator syntax must be rewritten to use the equivalent `df.*` function. The translation rules are:

| Operator pattern | Replacement |
|-----------------|-------------|
| `A ~> B` | `df.seq(A, B)` |
| `A ~> B ~> C` | `df.seq(A, B, C)` _(variadic — no nesting needed)_ |
| `A ~> B ~> C ~> D` | `df.seq(A, B, C, D)` |
| `A \|=> 'name'` | `df.as(A, 'name')` |
| `A & B` | `df.join(A, B)` |
| `A \| B` | `df.race(A, B)` |
| `cond ?> then_b !> else_b` | `df.if(cond, then_b, else_b)` |
| `@> (body)` | `df.loop(body)` |

Variadic `df.seq` is critical for readability. Compare:

```sql
-- Before (operators):
'step1' |=> 'x' ~> 'step2' ~> 'step3' ~> df.sleep(1)

-- After (without variadic — unreadable):
df.seq(df.seq(df.seq(df.as('step1', 'x'), 'step2'), 'step3'), df.sleep(1))

-- After (with variadic — clean):
df.seq(df.as('step1', 'x'), 'step2', 'step3', df.sleep(1))
```

#### Files requiring changes

| File | Operators used | Approximate changes |
|------|----------------|---------------------|
| `01_core_primitives.sql` | `~>`, `\|=>`, `&`, `\|` | Heavy — tests both operator and function forms; remove operator variants or convert to function-only |
| `02_conditionals.sql` | `?>`, `!>`, `\|=>`, `~>` | Heavy — operator-form conditional tests, rename/capture |
| `03_loops.sql` | `@>`, `~>`, `?>`, `!>` | Moderate — loop operator tests, inner sequences |
| `04_variables_and_results.sql` | `\|=>`, `~>` | Heavy — many named-result and sequence chains |
| `05_monitoring_and_explain.sql` | `~>` | Light — one sequence expression |
| `06_http_and_ssrf.sql` | `\|=>`, `~>`, `&`, `@>` | Heavy — chained HTTP calls, parallel HTTP, cron loop |
| `07_signals.sql` | `\|=>`, `~>` | Moderate — signal wait + sequence chains |
| `08_scenarios.sql` | `~>`, `&` | Moderate — multi-step workflow chains |
| `09_graph_and_validation.sql` | `~>` | Light — simple sequence expressions |
| `11_cross_connection.sql` | `\|=>`, `~>`, `@>` | Moderate — signal + loop patterns |
| `13_user_isolation.sql` | `~>` | Light — one sequence usage |
| `14_database.sql` | `~>` | Light — sequence in cross-database test |
| `44_connection_limit_backpressure.sql` | `~>` | Light — simple sequences (4 instances) |

**Test coverage requirement:** Every test scenario that existed with operators must have an equivalent function-only test. No test scenarios may be deleted — only rewritten.

### Phase 5: Rewrite sql/ example files

| File | Operators used |
|------|----------------|
| `sql/sequence.sql` | `~>` |
| `sql/parallel.sql` | `&` |
| `sql/conditional.sql` | `?>`, `!>` |
| `sql/variables.sql` | `\|=>` |
| `sql/simple.sql` | _(check for operators)_ |

Convert all operator usage to `df.*` function calls.

### Phase 6: Rewrite example workflows

| File | Operators used |
|------|----------------|
| `examples/azure-functions/sql/03_start_workflow.sql` | `~>`, `\|=>` |
| `examples/invoice-approval/sql/05_start_workflow.sql` | `~>`, `\|=>`, `\|` |
| `examples/invoice-approval/sql/04_explain.sql` | `~>` |

Convert all operator usage to `df.*` function calls.

### Phase 7: Update documentation

#### Major rewrites required

| File | Scope |
|------|-------|
| `USER_GUIDE.md` | Remove operator column from feature table, rewrite all examples, remove operator reference section |
| `docs/api-reference.md` | Remove `/ ~> operator`, `/ \|=> operator`, etc. from all function headings; delete operator-specific sections |
| `docs/grammar.md` | **Delete or archive** — the grammar is entirely about operator precedence and has no purpose without operators |
| `docs/ARCHITECTURE.md` | Remove "SQL Operators" section, update diagrams mentioning operators |
| `README.md` | Rewrite quick example and feature highlights to use `df.*` functions |
| `CHANGELOG.md` | Add breaking change entry |

#### Moderate updates required

| File | What to change |
|------|----------------|
| `docs/named-results-v2.md` | Replace `\|=>` examples with `df.as()` |
| `docs/design-azure-functions.md` | Replace `~>`, `\|=>` in all workflow examples |
| `docs/spec-compensation.md` | Replace `~>` in precedence table and examples |
| `docs/pg_durable_spec.md` | Replace `~>` in workflow examples |

#### Instruction files to update

| File | What to change |
|------|----------------|
| `.github/copilot-instructions.md` | Remove operator references from architecture overview, DSL description, and common tasks |
| `.github/skills/pg-durable-sql/SKILL.md` | Remove entire "Operators — Complete Reference" section and precedence rules; update frontmatter `description` to remove operator list; update examples |
| `prompts/pg_durable-update-docs-tests.md` | Remove operator documentation and testing checklists |
| `prompts/pg_durable-release.md` | Remove "New operators → E2E tests with both variants" |
| `prompts/pg_durable-merge-main.md` | Remove operator implementation tasks |

---

## Upgrade & Migration

### Scenario A: Schema Upgrade Correctness

The upgrade script must `DROP OPERATOR` and `DROP FUNCTION` for all seven operators and five helper functions. After upgrade:
- Fresh install (`CREATE EXTENSION pg_durable`) must not contain any operators or helper functions
- Upgraded install (`ALTER EXTENSION UPDATE`) must not contain them either
- Schema snapshot diff must match

### Scenario B1: Binary Backward Compatibility

**This is a breaking change for B1.** The new `.so` will not define the operator-backing functions (`as_op`, `if_then_op`, `if_else_op`, `loop_prefix_op`, `ensure_durofut`). However:

- Operators `~>`, `&`, `|` call `df.seq`, `df.join`, `df.race` directly — those Rust functions are retained. These operators will continue to work on old schemas that still have the `CREATE OPERATOR` definitions.
- Operators `|=>`, `?>`, `!>`, `@>` call SQL helper functions (`df.as_op`, `df.if_then_op`, `df.if_else_op`, `df.loop_prefix_op`) that are defined in SQL, not Rust. These will continue to exist in old schemas and call through to the retained Rust functions (`df.as`, `df.if`, `df.loop`). They will continue to work.
- `df.ensure_durofut` is pure SQL and will survive on old schemas.

**Conclusion for B1:** The new `.so` is actually backward compatible with old schemas that still have operators, because the operators in the old schema reference functions that all still exist. The operators just won't be present in new installs. B1 tests should verify that `df.seq()`, `df.as()`, `df.if()`, `df.loop()`, `df.join()`, `df.race()` all work against all previous schemas. No special runtime detection is needed.

### Scenario B2: Data Compatibility After Upgrade

- Existing completed instances are unaffected — operators are purely DSL-time constructs; the stored graph nodes use `node_type` values (`THEN`, `JOIN`, `RACE`, `IF`, `LOOP`) that are unchanged.
- In-flight instances will complete normally because the graph is already materialized in `df.nodes`. The node types are processed by orchestration code that is unchanged.
- The upgrade script drops only operator definitions and helper functions — no table or column changes.

### Update to `docs/upgrade-testing.md`

Add a new section under "Version-Specific Changes" for this change:

```markdown
#### Remove DSL operators (breaking change)
- **DDL change:** Upgrade script drops all seven operators (`~>`, `|=>`, `&`, `|`,
  `?>`, `!>`, `@>`) and five helper functions (`df.as_op`, `df.if_then_op`,
  `df.if_else_op`, `df.ensure_durofut`, `df.loop_prefix_op`).
- **Scenario A considerations:** Fresh install and upgraded install must both lack
  operators and helper functions. Schema comparison must verify absence.
- **Scenario B1 considerations:** Backward compatible. Old schemas retain operator
  DDL and helper functions. New `.so` retains all underlying Rust functions
  (`df.seq`, `df.as`, `df.join`, `df.race`, `df.if`, `df.loop`). Operators on
  old schemas continue to work because they call through to these retained functions.
- **Scenario B2 considerations:** No data migration needed. Stored graph nodes use
  `node_type` values, not operator symbols. In-flight instances complete normally.
  Dropping operators does not affect materialized graphs.

#### Variadic df.seq overload
- **DDL change:** New function `df.seq(VARIADIC text[])` added alongside the
  existing binary `df.seq(text, text)`. PostgreSQL resolves via standard
  function overloading.
- **Scenario A considerations:** Fresh install picks up both overloads from
  pgrx-generated SQL. The upgrade script must CREATE the variadic overload
  for upgraded installs.
- **Scenario B1 considerations:** Old schemas only have the binary overload.
  The new `.so` exports the variadic symbol but it won't be callable on old
  schemas (no matching SQL function). Binary `df.seq(a, b)` is unaffected.
- **Scenario B2 considerations:** No data migration. Additive change.
```

---

## Verification Checklist

### Before merging

- [ ] `cargo build --features pg17` — no warnings related to removed operator code
- [ ] `cargo clippy --features pg17` — clean
- [ ] `cargo fmt -p pg_durable -- --check` — formatted
- [ ] `./scripts/test-unit.sh` — all unit tests pass (operator tests removed, function tests unchanged)
- [ ] `./scripts/test-e2e-local.sh` — all E2E tests pass using function-only syntax
- [ ] `./scripts/test-upgrade.sh` — Scenarios A, B1, B2 pass
- [ ] `grep -rn '~>\||=>\|?>\|!>\|@>' tests/e2e/sql/ src/ examples/ sql/` returns zero hits in SQL context (operators fully removed from test/example code)
- [ ] All documentation files updated — no remaining operator examples
- [ ] CHANGELOG.md updated with breaking change notice
- [ ] Test count has not decreased (rewritten tests, not deleted)

### Test coverage mapping

Every operator-syntax test must map to a function-syntax test:

| Removed test | Replacement |
|-------------|-------------|
| `test_seq_operator_via_sql` | Covered by existing `test_seq_fn` |
| `test_as_operator_via_sql` | Covered by existing `test_as_fn` |
| `test_autowrap_via_sql_operator` | Add `test_autowrap_via_seq_fn` if not already covered |
| `test_autowrap_via_as_operator` | Add `test_autowrap_via_as_fn` if not already covered |
| E2E `01_core_primitives` operator variants | Convert to function variants in same file |
| E2E `02_conditionals` operator variants | Convert to function variants in same file |
| E2E `03_loops` `@>` variants | Convert to `df.loop()` in same file |

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Test coverage drops | Checklist requires 1:1 mapping of removed operator tests to function tests |
| Customer SQL breaks on upgrade | This is a known breaking change — document in CHANGELOG and release notes |
| Old schema + new binary breaks | Analyzed above — backward compatible because operators in old schemas call retained functions |
| `ensure_durofut` used elsewhere | Grep confirms it's only used by `?>` / `!>` helper functions — safe to drop |
| Missed operator reference in docs | Final grep verification step catches any remaining references |
| Variadic `df.seq` overload resolution conflict | PostgreSQL resolves `df.seq('A', 'B')` to the exact-match binary form, not the variadic form. Verified by pgrx function overloading semantics — exact arity match takes priority over VARIADIC. Add a unit test to confirm. |
| Variadic + binary `df.seq` interaction in `df.explain` | `df.explain` parses the JSON graph, not the SQL call site. THEN nodes look identical regardless of which overload created them. No impact. |

## Ordering

Recommended PR ordering:

1. **PR 1 — Variadic `df.seq`:** Phase 0 only. This can land independently on `main` with no breaking changes. Add the overload, unit tests, and upgrade script `CREATE FUNCTION`. All existing code continues to work.
2. **PR 2 — Drop operators + rewrite tests:** Phase 1 (upgrade DDL) + Phase 2 (remove `extension_sql!` block) + Phase 3 (remove unit tests) + Phase 4 (E2E rewrites) + Phase 5 (sql/ examples) + Phase 6 (example workflows). This is the breaking change.
3. **PR 3 — Documentation:** Phase 7 (all docs, instructions, skills, prompts). Can be combined with PR 2 if the diff is manageable.

A single PR combining all phases is acceptable if the team prefers atomic breaking changes. The key constraint is that Phase 0 must be implemented before Phase 4 (tests need variadic `df.seq` to be readable).
