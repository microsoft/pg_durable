# Proposal: Unified Variable Substitution Syntax

**Status:** Draft  
**Date:** 2026-03-24

## Summary

pg_durable currently uses two different syntaxes for variable substitution in SQL queries and HTTP templates:

| Mechanism | Syntax | Source |
|-----------|--------|--------|
| Named results | `$var`, `$var.col`, `$var?`, `$var.*` | `\|=>` operator (step outputs) |
| Function variables | `{var}` | `df.setvar()` / `df.vars` table |
| System variables | `{sys_instance_id}`, `{sys_label}` | Runtime metadata |

This proposal argues that named results and function variables should share the same `$` syntax, making `{var}` an alias for `$var` (or vice versa). **No changes to how named results are produced (`|=>`) or how function variables are set (`df.setvar()`) are proposed** — only the substitution syntax at query execution time.

## Current Behavior

### Named results (`$`)

Created by the `|=>` operator during graph execution. The result of a SQL step is stored as a JSON object and substituted into downstream queries:

```sql
SELECT df.start(
    'SELECT 42 AS amount' |=> 'total'
    ~> 'SELECT $total * 2'
);
```

Supports advanced patterns: `$name.column`, `$name?` (null-safe), `$name.column?`, `$name.*` (row-set expansion). Values are SQL-quoted in SQL contexts and unquoted in HTTP contexts.

### Function variables (`{}`)

Set before `df.start()` via `df.setvar()`, captured as a snapshot at start time, and immutable during execution:

```sql
SELECT df.setvar('api_url', 'https://api.example.com');
SELECT df.start(
    df.http('{api_url}/data', 'GET')
);
```

Values are inserted as raw strings with no quoting or null handling.

### System variables (`{}`)

Automatically available during execution:

```sql
'INSERT INTO audit (instance_id) VALUES (''{sys_instance_id}'')'
```

## Is There a Good Reason for Different Syntax?

The original design chose different delimiters to signal different *origins*:

| Argument | Counterpoint |
|----------|--------------|
| `$` means "computed result", `{}` means "configuration" | Users don't care *where* a value comes from — they care about *using* it in a query. The origin is already clear from `\|=>` vs `df.setvar()`. |
| Different syntax prevents naming collisions | A single namespace with clear precedence rules achieves the same goal more simply. Collisions between named results and vars are already a user error today — different syntax doesn't prevent bad naming, it just makes the error less obvious. |
| `{var}` is simpler for plain-text values | But `$var` is equally simple. The advanced suffixes (`.col`, `?`, `.*`) are only needed for result variables and would simply not apply to plain-text vars. |
| Braces match template languages (Jinja, mustache) | Dollar-sign is the standard in SQL (`$1` parameters), shell, and many string interpolation syntaxes. PostgreSQL's own dollar-quoting uses `$`. Braces conflict with JSON (`{"key": "value"}`) which appears frequently in HTTP bodies. |

**Conclusion:** The syntactic distinction adds cognitive overhead without meaningful safety benefit. A user writing `'SELECT $total + $batch_size'` shouldn't need to remember that `total` came from `|=>` and `batch_size` came from `df.setvar()`.

## Proposed Change

Adopt `$name` as the single substitution syntax for all variable types. Specifically:

1. **Function variables** (`df.setvar()`) become accessible as `$name` in addition to `{name}`.
2. **System variables** become accessible as `$sys_instance_id` and `$sys_label` in addition to `{sys_instance_id}` and `{sys_label}`.
3. **`{name}` syntax remains supported** as a deprecated alias during a transition period.
4. **Named results continue to work exactly as today** — no changes to `|=>`, `$name.col`, `$name?`, `$name.*`.
5. **`df.setvar()`, `df.getvar()`, `df.vars`** — no API changes.

### Substitution Order & Precedence

When the same name exists as both a named result and a function variable:

1. Named results take precedence (they are step-specific and more local).
2. Function variables serve as fallback defaults.
3. System variables have reserved `sys_` prefix — user names starting with `sys_` are disallowed.

This matches the principle of "most-local scope wins" and is the same order used today.

### Advanced Suffixes for Function Variables

With unified syntax, `$name.col`, `$name?`, and `$name.*` would only apply to named results (which carry structured JSON). For function variables (plain strings), these suffixes have no meaning and would not match — the plain `$name` form is used instead. This is natural: you wouldn't write `$api_url.column` because `api_url` is a string, not a result set.

## Benefits

### 1. Reduced Cognitive Load

One syntax to learn instead of two. Users write `$name` everywhere and don't need to remember which mechanism produced the value.

### 2. Simpler Documentation

The User Guide currently has separate sections explaining `$var` and `{var}`. A unified syntax consolidates these into a single "Variable Substitution" section.

### 3. Composability

A user can start with a hardcoded value via `df.setvar('threshold', '100')` using `$threshold`, then later refactor to compute it dynamically via `|=>` — without changing any downstream queries.

```sql
-- Before: static config
SELECT df.setvar('threshold', '100');
SELECT df.start('SELECT * FROM orders WHERE amount > $threshold');

-- After: dynamic computation — downstream query unchanged
SELECT df.start(
    'SELECT avg(amount) FROM orders' |=> 'threshold'
    ~> 'SELECT * FROM orders WHERE amount > $threshold'
);
```

### 4. No JSON/Brace Conflicts

The `{var}` syntax is visually ambiguous inside JSON bodies used in HTTP requests:

```sql
-- Current: braces inside JSON are confusing
df.http('https://api.example.com', 'POST',
    '{"user": "{username}", "count": 5}')

-- Proposed: dollar-sign is unambiguous
df.http('https://api.example.com', 'POST',
    '{"user": "$username", "count": 5}')
```

### 5. Consistent with PostgreSQL Conventions

PostgreSQL uses `$` for parameterized queries (`$1`, `$2`), dollar-quoting (`$$`), and PL/pgSQL variables (`$1`, `NEW`, declared vars). The `$name` syntax feels native to PostgreSQL users.

## Migration Path

| Phase | Behavior |
|-------|----------|
| **Phase 1: Add `$` support for vars** | `$name` resolves against both named results and function variables. `{name}` continues to work unchanged. |
| **Phase 2: Deprecation warnings** | Log a notice when `{name}` syntax is used, suggesting `$name`. |
| **Phase 3: Remove `{}`** | Drop `{name}` support in a future major version. |

Phase 1 is fully backward-compatible. Existing workflows using `{var}` continue to work with no changes.

## Non-Goals

- **Changing `df.setvar()` / `df.getvar()` API** — these functions remain as-is.
- **Changing how `|=>` stores results** — the JSON result format is unchanged.
- **Adding SQL quoting to function variables** — function variables remain raw text substitution. Users who need quoting should use `quote_literal()` in their SQL or provide pre-quoted values.
- **Merging the namespaces** — named results and function variables remain distinct data sources with distinct lifecycles. Only the *reference syntax* is unified.

## Implementation Sketch

In `substitute_all_with_options()` (src/types.rs), the change is small:

1. After substituting system vars and user vars via `{name}`, also register them as entries in the results map (with a "plain string" marker) before calling `substitute_results()`.
2. Alternatively, extend `substitute_results()` to check the vars map as a fallback when `$name` doesn't match any named result.
3. Keep `{name}` substitution in place for backward compatibility during the transition period.

The `substitute_results()` scanner already handles word-boundary detection and longest-match-first ordering, so function variables would slot in naturally.

## Open Questions

1. **Should `$var.col` work on function variables if the value happens to be JSON?** Probably not in the initial implementation — keep it simple with plain-text substitution for vars.
2. **Should `$var?` (null-safe) apply to function variables?** A missing var could return NULL instead of being left as literal `$var`. This would be a useful safety feature.
3. **Naming conflicts:** If a named result and a function variable share the same name, the result wins. Should we warn? Error? The current `{}`/`$` split makes conflicts invisible — with a single syntax, we'd at least have a clear precedence rule.
