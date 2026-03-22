# Named Result Improvements — Dot-Notation, Row Sets, Null Safety

## Summary

Named results (`|=>`) previously only exposed the first column of the first row via `$name` substitution. This made multi-column results awkward, null handling error-prone, and small row sets impossible to pass between nodes without extra SQL gymnastics.

Four features were introduced to address these problems:

| Feature | Syntax | Purpose |
|---------|--------|---------|
| **Dot-notation** | `$name.column` | Access any column from the first row |
| **Row-set expansion** | `$name.*` | Expand all rows as an inline `VALUES` subquery |
| **`df.if_rows`** | `df.if_rows('name', then, else)` | Branch on whether a named result has rows |
| **Null-safe accessor** | `$name?`, `$name.col?` | Return SQL `NULL` instead of failing the instance |

All four are backward compatible. Bare `$name` retains its existing first-col-first-row behavior.

Additionally, two bugs were fixed: no-rows substitution previously produced raw JSON garbage, and NULL columns silently injected unquoted `null` text (see [Bug Fixes](#bug-fixes)).

---

## Dot-Notation (`$name.column`)

### Problem: multi-column results required manual jsonb packing

Previously, to use multiple columns from a query result, users had to manually serialize into jsonb and deserialize with cast operators:

```sql
-- Node 1: must manually pack columns into jsonb to access more than one
$$SELECT jsonb_build_object('id', id, 'content', content)::text
  FROM documents WHERE status = 'pending' LIMIT 1
$$ |=> 'doc'

-- Node 2: must extract each column with jsonb operators + casts
~> $$UPDATE documents
    SET status = 'processing',
        summary = 'Processing: ' || ($doc::jsonb->>'content')
    WHERE id = ($doc::jsonb->>'id')::bigint$$
```

The user had to enumerate columns twice (once in the SELECT, once in `jsonb_build_object`), and every downstream reference required `($doc::jsonb->>'field')` with explicit type casts.

On top of that, bare `$name` on multi-column results picked a non-deterministic column — `serde_json::Map::iter().next()` does not guarantee insertion order, so `SELECT id, content FROM ...` could substitute `content` instead of `id`.

### Solution

`$name.column` accesses any named column from the first row of a named result:

```sql
$$SELECT id, content FROM documents
    WHERE status = 'pending' LIMIT 1
$$ |=> 'doc'

~> $$UPDATE documents
    SET status = 'processing',
        summary = 'Processing: ' || $doc.content
    WHERE id = $doc.id$$
```

### Semantics

- `$doc.id` looks up the column named `id` in the first row of result `doc`
- String values are SQL-quoted: `$doc.name` → `'Alice'`
- Numeric/boolean values are unquoted: `$doc.id` → `42`
- Works in both SQL (quoted) and raw contexts (HTTP bodies/headers — unquoted)
- **Strict by default**: fails the instance if column is NULL or result has no rows (see [Null-Safe Accessor](#null-safe-accessor--suffix) for opt-out)
- Non-existent column name: left as-is in the query, so PostgreSQL reports a clear SQL error
- **Deterministic**: `$doc.id` always looks up by name, not iteration order — fixing the non-deterministic column problem with bare `$doc`

### Implementation

In `substitute_all_with_options`, before processing bare `$name` patterns, scan for `$name.column` patterns. For each named result, parse the stored JSON, extract the first row, and look up the column by name.

**Substitution order** is longest-match-first: `$name.*` → `$name.column` → `$name`.

---

## Row-Set Expansion (`$name.*`)

### Problem: passing row sets between nodes required JSON gymnastics

Each node in the function graph gets a separate sqlx connection and transaction. Previously, to pass a batch of rows from one node to the next, users had to serialize the batch into a JSON array and deserialize it with `jsonb_array_elements` — the DSL had no native way to express this:

```sql
-- Node 1: pack rows into a JSON array
$$SELECT jsonb_agg(jsonb_build_object('id', id, 'content', content))::text
  FROM documents WHERE status = 'pending' LIMIT 10
$$ |=> 'batch'

-- Node 2: unpack with jsonb_array_elements + extraction
~> $$UPDATE documents SET status = 'processing'
    WHERE id IN (
        SELECT (elem->>'id')::bigint
        FROM jsonb_array_elements($batch::jsonb) AS elem
    )$$
```

This worked, but was verbose, error-prone, and required the user to handle JSON serialization in both directions.

### Solution

`$name.*` expands a named result's full row set as an inline `VALUES` subquery, usable in any SQL `FROM` clause, subquery, or `IN (SELECT ... FROM ...)`:

```sql
-- Node 1: fetch batch
$$SELECT id, content FROM documents
    WHERE status = 'pending' LIMIT 10
$$ |=> 'batch'

-- Node 2: use the row set directly
~> $$UPDATE documents SET status = 'processing'
    WHERE id IN (SELECT id FROM $batch.*)$$

-- Node 3: also works in FROM clauses
~> $$INSERT INTO results SELECT id, upper(content) FROM $batch.*$$
```

### Expansion

`$batch.*` expands to a self-contained inline relation:

```sql
(VALUES (1,'hello'::text), (2,'world'::text), (3,'foo'::text)) AS batch(id, content)
```

### Semantics

- All rows and all columns from the stored result are included
- Column names come from the original query's column names (as stored in the JSON)
- Values are type-cast where possible (text, numeric, boolean)
- In raw contexts (HTTP body), `$batch.*` expands to a JSON array: `[{"id":1,"content":"hello"}, ...]`
- Empty results (no rows): expands to an empty relation — `(VALUES (NULL::text, NULL::text) LIMIT 0) AS batch(id, content)` or similar

### Practical limits

Designed for small-to-medium row sets. PostgreSQL handles inline `VALUES` well up to a few thousand rows. For large result sets (10K+), users should build a **table pipeline** — use ordinary tables to hold intermediate results between stages, with each node reading from and writing to those tables directly. The DSL should not try to shuttle huge result sets through the substitution layer.

---

## `df.if_rows` — Branch on Row Existence

### Problem: no-rows substitution produced garbage

Previously, when a query returned zero rows, `$name` substituted the **raw JSON string** `{"rows": [], "row_count": 0}` into the SQL. This produced invalid SQL that failed with a confusing parse error rather than a clear "no rows" message:

```sql
SELECT df.start(
    $$SELECT id FROM test_docs WHERE status = 'nonexistent' LIMIT 1$$ |=> 'doc'
    ~> $$SELECT 'doc value is: ' || $doc$$,
    'test-no-rows'
);
-- Instance failed. Worker log showed:
-- Executing SQL: SELECT 'doc value is: ' || {"row_count":0,"rows":[]}
-- ERROR:  syntax error at or near "{"
```

The error message gave zero indication that the problem was a named result with no rows. The instance failed, and `df.result()` returned empty — the user had to dig through server logs to understand what happened.

There was no clean way to branch on whether a result had rows — attempting to check `$doc IS NOT NULL` would itself fail because `$doc` was already garbage.

### Solution

`df.if_rows` branches based on whether a named result contains any rows, providing a clean, zero-cost way to handle the common "query returned nothing" case:

```sql
$$SELECT id, content FROM documents
    WHERE status = 'pending' LIMIT 1
$$ |=> 'doc'

~> df.if_rows('doc',
    -- has rows: proceed
    $$UPDATE documents SET status = 'processing' WHERE id = $doc.id$$,
    -- no rows: alternative path
    $$SELECT 'nothing to process'$$
)
```

### Semantics

- The condition is evaluated by checking `row_count > 0` from the stored result JSON
- **No SQL execution** for the condition — zero-cost check against the in-memory results HashMap
- Entering the then-branch guarantees at least one row exists, so `$doc.id` is safe (assuming the column is not NULL)
- The argument is the result name as a string (without `$` prefix)

### Implementation

- DSL function `df.if_rows` in `src/dsl.rs` with `#[pg_extern(schema = "df")]`
- Creates an IF node with a special condition marker (e.g., `condition_type: "result_has_rows"`, `condition_ref: "doc"`)
- The orchestration handles this without scheduling a SQL activity — purely an in-memory check

---

## Null-Safe Accessor (`?` suffix)

### Problem: NULL columns silently injected `null` text

Previously, when a column value was NULL, `$name` substituted the literal text `null` (no quotes). This had two failure modes:

**String concatenation → silent NULL propagation:**
```sql
SELECT 'the value is: ' || null
-- Result: NULL (entire expression becomes NULL)
```
The instance completed "successfully" with a null result. No error, no warning.

**WHERE clause → silent no-op (the worst case):**
```sql
UPDATE test_docs SET status = 'processed' WHERE content = null
-- Result: 0 rows updated (NULL comparisons are always false in SQL)
```

An instance could complete with status `completed` but update zero rows — there was no way to distinguish "did work" from "silently did nothing because of a null substitution."

### Solution

`$name` and `$name.column` now **fail the instance** when the value would be NULL (either because the result has no rows or the column is NULL). The `?` suffix opts into returning SQL `NULL` instead:

```
$name?         — first col, first row; NULL if no rows or column is NULL
$name.column?  — named col, first row; NULL if no rows or column is NULL
```

### Behavior Matrix

| Syntax | On value exists | On NULL column | On no rows |
|--------|----------------|----------------|------------|
| `$doc` | Value | **Fail instance** | **Fail instance** |
| `$doc?` | Value | `NULL` | `NULL` |
| `$doc.id` | Value | **Fail instance** | **Fail instance** |
| `$doc.id?` | Value | `NULL` | `NULL` |

### Rationale

**Why strict by default?** If a user writes `$doc.id`, they expect a value. A NULL result usually indicates a bug (unexpected data, wrong query). Failing fast with a clear error message is better than silently injecting NULL, which causes:
- `WHERE id = NULL` → silent no-op (NULL comparisons are always false)
- `'prefix_' || NULL` → entire expression becomes NULL
- Downstream nodes consuming garbage data

**Why offer `?` at all?** Sometimes columns are intentionally nullable and the user wants to branch on them:

```sql
$$SELECT id, manager_id FROM employees WHERE id = 1$$ |=> 'emp'

~> df.if_rows('emp',
    df.if(
        $$SELECT $emp.manager_id? IS NOT NULL$$,
        $$SELECT 'has manager: ' || $emp.manager_id$$,
        $$SELECT 'no manager'$$
    ),
    $$SELECT 'employee not found'$$
)
```

Without `?`, `$emp.manager_id` would fail before the `IS NOT NULL` check could run. With `?`, it substitutes to `NULL`, the condition evaluates to false, and the else branch runs. In the then-branch, bare `$emp.manager_id` (no `?`) is safe — the condition already confirmed it's not NULL.

### Guidance for users

If a column may be NULL, handle it at the source with `COALESCE`:

```sql
$$SELECT id, COALESCE(content, '') as content FROM documents LIMIT 1$$ |=> 'doc'
-- $doc.content is never NULL — no need for ?
```

Use `?` when you specifically need to test for NULL in a conditional.

---

## Bug Fixes

### Fix: No-rows substitution produced raw JSON

**Previous behavior:** `$name` on a zero-row result substituted to `{"rows": [], "row_count": 0}` — raw JSON injected into SQL, causing parse errors.

**New behavior:** `$name` on a zero-row result **fails the instance** with:
```
Variable substitution failed: $doc has no rows
  Hint: The query for result 'doc' returned 0 rows.
  Use df.if_rows('doc', ...) to branch on empty results,
  or $doc? for NULL-safe substitution.
```

### Fix: NULL column substituted unquoted `null`

**Previous behavior:** `$name` when the first column is JSON null substituted the literal text `null` (unquoted).

**New behavior:** `$name` when the value is NULL **fails the instance** with:
```
Variable substitution failed: $doc is NULL
  Hint: The first column of result 'doc' is NULL.
  Use $doc? for NULL-safe substitution,
  or COALESCE in the original query.
```

---

## Implementation Notes

### Substitution ordering

Resolution proceeds longest-match-first to avoid partial matches:

1. `$name.*` — row-set expansion
2. `$name.column?` — null-safe dot-notation
3. `$name.column` — strict dot-notation
4. `$name?` — null-safe scalar
5. `$name` — strict scalar (with fail-fast behavior)

### No schema changes required

All features are implemented in the substitution layer (`src/types.rs`) and orchestration (`src/orchestrations/execute_function_graph.rs`). No new tables, no upgrade scripts, no duroxide changes.

Exception: `df.if_rows` required a new DSL function in `src/dsl.rs` and a new condition evaluation path in the orchestration.

### Backward compatibility

- Bare `$name` behavior changed from "substitute garbage/null" to "fail on no-rows/NULL". This is technically a breaking change but the previous behavior produced invalid SQL, so any existing usage was already broken.
- `$name` with valid non-NULL single-row results: unchanged behavior.

---

## Out of Scope

- **FROM-able syntax** (`FROM $batch` expanding to a CTE): not planned; for large result sets, users should build a table pipeline instead of passing data through the substitution layer
- **Large result set management**: the DSL is not the right place to shuttle 10K+ rows between nodes. Users should use ordinary tables as staging areas between pipeline stages — each node writes to and reads from those tables directly
- **`$name.row_count` metadata accessor**: potential future convenience; users can use `df.if_rows` for now

## Issue Tracker - Items left for later

| # | Item | Severity | Status |
|---|------|----------|--------|
| 1 | Audit backslash escaping or document assumption | Defense-in-depth | Not started |
| 2 | Validate `df.if_rows` result name at graph-build time | UX | Deferred |
| 3 | Fail substitution on missing columns | UX | Deferred |
| 4 | Add non-ASCII column edge case unit test | Testing | Not started |
| 5 | Fix changelog wording: "NULL" not "empty string" | Documentation | Not started |

---

### 1. String Escaping: Single-Quote-Only May Be Insufficient

The `format_value` function escapes strings by doubling single quotes (`'` → `''`), which is correct for PostgreSQL's standard string syntax. However, if the server has `standard_conforming_strings = off` (rare but possible), backslash sequences become significant and `\' ` could escape the closing quote.

This is a pre-existing concern (not introduced by this PR), but since the substitution engine was rewritten, it's worth noting. PostgreSQL's `E'...'` escape syntax and the `$$..$$` dollar-quoting used elsewhere in the codebase avoid this issue. For defense-in-depth, consider also replacing `\` with `\\` in string values, or document the `standard_conforming_strings = on` assumption.

**Status:** Not started.

### 2. `df.if_rows` Result Name Validation

`df.if_rows('name', ...)` stores the name as-is in the `condition_type: "result_has_rows"` config JSON. The orchestration looks it up in the results HashMap at runtime. If the name is misspelled, the error is:

```
df.if_rows: result 'naem' not found
```

This is a reasonable runtime error. But since the result name is known at graph-build time (in the DSL), it could theoretically be validated earlier — when `df.start()` walks the graph. This would be a future improvement, not a blocker.

**Status:** Deferred — future improvement.

### 3. Missing Column Behavior Inconsistency

When `$doc.nonexistent` is used and the column doesn't exist in the result JSON, the substitution leaves the pattern as-is in the SQL string. The spec says this is so "PostgreSQL reports a clear SQL error." This is a pragmatic choice, but may produce confusing error messages — PostgreSQL will see a literal `$doc` in the query and report a syntax error about `$` rather than about a missing column.

Consider instead failing the substitution with:
```
$doc.nonexistent: column 'nonexistent' not found in result 'doc'. Available columns: id, name
```

**Status:** Deferred — future improvement.

### 4. Non-ASCII Column Edge Case

The `parse_identifier` function stops at non-ASCII bytes, so `$doc.café` would parse as `$doc.caf` and leave `é` in the query. This is an edge case but worth a unit test to document the behavior.

**Status:** Not started.

### 5. Changelog Wording

The USER_GUIDE.md documents `$name?` as substituting `NULL` but the changelog says "append `?` to substitute an empty string instead". These should be made consistent — the code substitutes `NULL` (the SQL keyword), not an empty string.

**Status:** Not started.

---
