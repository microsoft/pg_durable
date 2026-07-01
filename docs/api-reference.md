# API Reference

Complete reference for all `df.*` functions with parameter types and auto-wrap behavior.

## Auto-Wrap Explained

**Auto-wrap** means a plain SQL string is automatically converted to a `df.sql()` node. 

```sql
-- These are equivalent when auto-wrap is supported:
df.seq('SELECT 1', 'SELECT 2')
df.seq(df.sql('SELECT 1'), df.sql('SELECT 2'))
```

Parameters marked with ✅ **Auto-wrap** accept either:
- A plain SQL string (auto-wrapped to `df.sql()`)
- A Durofut node (from any `df.*` function)

Parameters marked with ❌ **Literal** expect a literal value (not auto-wrapped).

---

## Node Functions

### df.sql(query)

Creates a SQL execution node.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `query` | TEXT | ❌ Literal | SQL query to execute |

```sql
df.sql('SELECT * FROM users WHERE id = 1')
```

---

### df.seq(a, b) / `~>` operator

Executes two nodes in sequence.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `a` | TEXT | ✅ Auto-wrap | First node to execute |
| `b` | TEXT | ✅ Auto-wrap | Second node to execute |

```sql
df.seq('SELECT 1', 'SELECT 2')
'SELECT 1' ~> 'SELECT 2'               -- operator form
df.sql('SELECT 1') ~> df.sleep(5)      -- mixed
```

---

### df.as(fut, name) / `|=>` operator

Binds a result to a variable name.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `fut` | TEXT | ✅ Auto-wrap | Node whose result to name |
| `name` | TEXT | ❌ Literal | Variable name (no `$` prefix) |

```sql
df.as('SELECT id FROM users LIMIT 1', 'user_id')
'SELECT id FROM users LIMIT 1' |=> 'user_id'  -- operator form
```

**Substitution patterns** available on named results:

| Pattern | Behavior | On no rows | On NULL |
|---------|----------|------------|---------|
| `$name` | First column of first row | Error | Error |
| `$name.column` | Specific column of first row | Error | Error |
| `$name?` | Null-safe scalar | → `NULL` | → `NULL` |
| `$name.column?` | Null-safe column | → `NULL` | → `NULL` |
| `$name.*` | Row-set expansion (inline VALUES) | Empty relation | N/A |

---

### df.join(a, b) / `&` operator

Executes nodes in parallel, waits for all to complete.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `a` | TEXT | ✅ Auto-wrap | First parallel branch |
| `b` | TEXT | ✅ Auto-wrap | Second parallel branch |

```sql
df.join('SELECT count(*) FROM a', 'SELECT count(*) FROM b')
'SELECT 1' & 'SELECT 2'                -- operator form
```

---

### df.join3(a, b, c)

Executes three nodes in parallel, waits for all.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `a` | TEXT | ✅ Auto-wrap | First parallel branch |
| `b` | TEXT | ✅ Auto-wrap | Second parallel branch |
| `c` | TEXT | ✅ Auto-wrap | Third parallel branch |

```sql
df.join3('SELECT 1', 'SELECT 2', 'SELECT 3')
```

---

### df.race(a, b) / `|` operator

Executes nodes in parallel, first to complete wins.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `a` | TEXT | ✅ Auto-wrap | First competing branch |
| `b` | TEXT | ✅ Auto-wrap | Second competing branch |

```sql
df.race(df.sleep(10), df.wait_for_signal('cancel'))
df.sleep(10) | df.wait_for_signal('cancel')  -- operator form
```

---

### df.if(condition, then, else) / `?>` `!>` operators

Conditional execution.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `condition` | TEXT | ✅ Auto-wrap | Node that returns truthy/falsy |
| `then` | TEXT | ✅ Auto-wrap | Execute if condition is truthy |
| `else` | TEXT | ✅ Auto-wrap | Execute if condition is falsy |

```sql
df.if('SELECT count(*) > 0 FROM q', 'SELECT ''yes''', 'SELECT ''no''')
'SELECT true' ?> 'SELECT ''yes''' !> 'SELECT ''no'''  -- operator form
```

---

### df.if_rows(result_name, then, else)

Branches based on whether a named result has any rows. Unlike `df.if()`, no SQL query is executed — the check is done in-memory on the stored result.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `result_name` | TEXT | ❌ Literal | Name of a previously stored result (no `$` prefix) |
| `then` | TEXT | ✅ Auto-wrap | Execute if result has rows |
| `else` | TEXT | ✅ Auto-wrap | Execute if result has zero rows |

```sql
df.if_rows('data', 'SELECT $data.id', 'SELECT ''no data''')
```

---

### df.loop(body [, condition]) / `@>` operator

Repeats body (forever or while condition is true).

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `body` | TEXT | ✅ Auto-wrap | Node to repeat |
| `condition` | TEXT | ✅ Auto-wrap | (Optional) Continue while truthy |

```sql
-- Infinite loop
df.loop('SELECT process_item()' ~> df.sleep(1))
@> ('SELECT process_item()' ~> df.sleep(1))  -- operator (infinite only)

-- While loop (function only, no operator)
df.loop('SELECT process_item()', 'SELECT count(*) > 0 FROM queue')
```

---

### df.break([value])

Exits the enclosing loop.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `value` | TEXT | ❌ Literal | (Optional) JSON value to return |

```sql
df.break()                           -- exit with null
df.break('{"status": "done"}')       -- exit with value
```

**Note:** The `value` parameter is a literal JSON string, NOT auto-wrapped.

---

### df.sleep(seconds)

Pauses execution for N seconds.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `seconds` | INTEGER | ❌ Literal | Duration in seconds |

```sql
df.sleep(60)
```

---

### df.wait_for_schedule(cron_expr)

Waits until cron expression matches.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `cron_expr` | TEXT | ❌ Literal | 5-part cron expression |

```sql
df.wait_for_schedule('*/5 * * * *')   -- every 5 minutes
df.wait_for_schedule('0 9 * * 1-5')   -- weekdays at 9am
```

---

### df.wait_for_signal(name [, timeout])

Waits for an external signal.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `name` | TEXT | ❌ Literal | Signal name to wait for |
| `timeout` | INTEGER | ❌ Literal | (Optional) Timeout in seconds |

```sql
df.wait_for_signal('approval')         -- wait forever
df.wait_for_signal('approval', 3600)   -- 1 hour timeout
```

---

### df.http(url [, method, body, headers, timeout])

Makes an HTTP request.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `url` | TEXT | ❌ Literal | Request URL (supports `$var` substitution) |
| `method` | TEXT | ❌ Literal | HTTP method (default: POST) |
| `body` | TEXT | ❌ Literal | Request body JSON (supports `$var`) |
| `headers` | JSONB | ❌ Literal | Request headers |
| `timeout` | INTEGER | ❌ Literal | Timeout in seconds (default: 30) |

```sql
df.http('https://api.example.com/users', 'GET')
df.http('https://api.example.com', 'POST', '{"key": "$value"}')
df.http(url, 'GET', NULL, '{"Auth": "Bearer token"}'::jsonb, 60)
```

---

## Control Functions

### df.start(fut [, label])

Starts a durable function.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `fut` | TEXT | ✅ Auto-wrap | Root node of the function |
| `label` | TEXT | ❌ Literal | (Optional) Human-readable label |

```sql
df.start('SELECT 1')                      -- auto-wrapped
df.start(df.sleep(10) ~> 'SELECT 2')      -- explicit nodes
df.start('SELECT 1', 'my-job')            -- with label
```

---

### df.signal(instance_id, signal_name [, signal_data])

Sends a signal to a running instance.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID |
| `signal_name` | TEXT | ❌ Literal | Signal name |
| `signal_data` | TEXT | ❌ Literal | Optional signal payload text (default: '{}'). Valid JSON is preserved; other text is sent as a JSON string. |

```sql
df.signal('a1b2c3d4', 'approval', '{"approved": true}')
```

---

### df.cancel(instance_id [, reason])

Cancels a running instance.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID |
| `reason` | TEXT | ❌ Literal | Cancellation reason |

```sql
df.cancel('a1b2c3d4', 'Manual stop')
```

---

### df.status(instance_id)

Gets instance status.

> **Note:** the argument is an **`instance_id`** (returned by `df.start()`), **not** a label. Passing a label returns `NULL`, since no instance has that ID. To check a labeled run, resolve the label to an `instance_id` first (see example below).

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID from `df.start()` (not a label) |

```sql
-- By instance_id. Returns a lowercase status:
-- 'pending', 'running', 'completed', 'failed', or 'cancelled'.
SELECT df.status('a1b2c3d4');

-- Have a label instead of an instance_id? Resolve it first:
SELECT df.status(instance_id)
FROM df.list_instances()
WHERE label = 'my-job';
```

If you reuse a label across runs, multiple instances can match — pass the specific `instance_id` you want.

---

### df.list_instances(...)

Lists your durable function instances, newest-first. Results are RLS-scoped to your own instances (superusers see all). The function comes in **two overloads**, distinguished by argument count:

| Overload | Call shape | Returned columns |
|----------|-----------|------------------|
| **Basic** (0–2 args) | `df.list_instances([status_filter[, limit_count]])` | 6 columns (no timestamps or cursor) |
| **Paginated** (3–4 args) | `df.list_instances(status_filter, limit_count, label_filter[, after_cursor])` | 9 columns (adds `created_at`, `completed_at`, `next_cursor`) |

The two overloads have non-overlapping arities (basic matches 0–2 arguments, paginated matches 3–4), so a call is never ambiguous. To reach the paginated overload you must pass at least the first three arguments — use `NULL` for any you don't want to filter on (e.g. `df.list_instances(NULL, 100, NULL)`).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `status_filter` | TEXT | `NULL` (basic only) | Only instances with this status (lowercase: `pending`, `running`, `completed`, `failed`, `cancelled`). `NULL` = any. |
| `limit_count` | INTEGER | `100` (basic only) | Max rows per page (must be ≥ 1). A request above `pg_durable.list_instances_max_limit` (default 1000) raises an error instead of being silently truncated — lower `limit_count`, or use the paginated overload (`after_cursor`) for larger result sets. |
| `label_filter` | TEXT | — (required to select the paginated overload) | Only instances whose label equals this value (issue #87). `NULL` = any. |
| `after_cursor` | TEXT | `NULL` | Opaque keyset cursor from a prior page's `next_cursor`; returns the page that sorts strictly after it (issue #146). `NULL` = first page. |

> `status_filter` and `limit_count` default only in the basic overload. The paginated overload requires all three of `status_filter`, `limit_count`, and `label_filter` to be supplied positionally (pass `NULL` to skip a filter); only `after_cursor` is optional.

**Basic overload columns:** `instance_id`, `label`, `function_name`, `status`, `execution_count`, `output`.

**Paginated overload columns:** the six above plus `created_at`, `completed_at`, `next_cursor`.

- `created_at` / `completed_at` are the submit and completion timestamps from `df.instances`. `completed_at` is `NULL` until the instance reaches `completed` (it stays `NULL` for `failed`/`cancelled`).
- Rows are ordered `created_at DESC, id ASC` (deterministic, served by the `(created_at DESC, id)` indexes on `df.instances`).
- `next_cursor` is the token to fetch the page *after* this one. It is the same value on every row of a page and `NULL` on the final page.

```sql
-- Basic overload: most recent 50 completed runs (6 columns, no timestamps/cursor)
SELECT instance_id, status FROM df.list_instances('completed', 50);

-- Paginated overload: all instances carrying a given label (9 columns)
SELECT instance_id, status, created_at, completed_at, next_cursor
FROM df.list_instances(NULL, 100, 'nightly-report');

-- Keyset pagination: pass the previous page's next_cursor back in as after_cursor
SELECT * FROM df.list_instances(NULL, 50, NULL, '323032362d...');
```

> **Pagination note:** `next_cursor` is computed over `df.instances` (the authoritative, RLS-filtered set) independently of the per-row execution-metadata lookup, so it normally advances correctly. In a brief start-up window an instance can exist in `df.instances` before its execution metadata is queryable; such a row is omitted from the current page. Edge case: if *every* row of a non-final page is omitted this way, that page returns zero rows and you cannot read `next_cursor` (it is carried on each row) — retry shortly. A malformed `after_cursor` raises an error; always pass a `next_cursor` value back verbatim.

---

### df.result(instance_id)

Gets instance result (for completed instances).

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID |

```sql
SELECT df.result('a1b2c3d4');
```

---

### df.instance_nodes(instance_id)

Returns one row per node in an instance's graph, with each node's stored physical
status alongside a read-time **derived** status. This is the primary tool for
inspecting *where* an instance is and *why* a branch did or did not run.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID |

Return columns:

| Column | Type | Description |
|--------|------|-------------|
| `node_id` | TEXT | Node id (unique within the instance) |
| `node_type` | TEXT | `SQL`, `THEN`, `IF`, `JOIN`, `RACE`, `LOOP`, `SLEEP`, `SIGNAL`, `HTTP`, … |
| `query` | TEXT | SQL text for `SQL` nodes; a JSON config for compound/leaf nodes |
| `result_name` | TEXT | Capture name (`\|=>`), or `NULL` |
| `left_node` | TEXT | First child node id, or `NULL` |
| `right_node` | TEXT | Second child node id, or `NULL` |
| `status` | TEXT | **Physical** stored status: `pending`, `running`, `completed`, `failed` |
| `result` | JSONB | Result/error payload for `completed`/`failed` nodes, else `NULL` |
| `status_details` | JSONB | Worker-written node metadata (see below), or `NULL` if never transitioned |
| `inferred_status` | TEXT | **Derived** status: physical status plus `skipped`, and loop re-entry surfaced as `pending` |
| `inferred_status_from_ancestor_id` | TEXT | Ancestor node id that drove a derived `skipped`/`pending`, or `NULL` |
| `updated_at` | TIMESTAMPTZ | Last physical status change |

**`status_details` JSON contract.** Written by the worker through the
`update-node-status` activity and stored verbatim in `df.nodes.status_details`:

- `execution_id` — the node's full segmented execution path, e.g.
  `a1b2c3d4::1::7f9a0012::1`. Parse it positionally: the second `::`-token is the
  root loop generation (used to detect superseded loop iterations), and the
  trailing segments encode `JOIN`/`RACE` sub-orchestration lineage.

`inferred_status` and `inferred_status_from_ancestor_id` are **computed at read
time** and are not stored in `df.nodes.status_details`.

**Derived statuses.** `skipped` is never written to `df.nodes.status` (it is not a
member of the `nodes_status_chk` constraint) — it exists only in `inferred_status`:

- `skipped` — a non-terminal node whose nearest terminal ancestor already decided
  the branch will not run: the untaken arm of a completed `df.if()`, the right side
  of a failed `df.then()`/`~>`, or the abandoned (still-running) loser of a resolved
  `df.race()`. A loser that already reached `completed`/`failed` keeps its physical
  status.
- `pending` (derived) — a node from an older loop generation that a newer ancestor
  generation has superseded; it will re-run, so it reads back as `pending` rather
  than showing the previous iteration's terminal status.

`df.explain()` renders the same derived status for each node, so the two views
always agree.

```sql
SELECT node_id, node_type, status AS physical, inferred_status,
       status_details->>'execution_id' AS execution_id
FROM df.instance_nodes('a1b2c3d4')
ORDER BY node_id;
```

---

## Variable Functions

### df.setvar(name, value)

Sets a workflow variable for the current user (before `df.start()`). Each user has their own variable namespace — variables set by one user are invisible to others.
`df.setvar` is a setup helper, not a workflow node: do not use it inside `df.seq`, `df.join`, `df.race`, etc.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `name` | TEXT | ❌ Literal | Variable name |
| `value` | TEXT | ❌ Literal | Variable value |

```sql
SELECT df.setvar('api_url', 'https://api.example.com');
```

---

### df.getvar(name)

Gets a workflow variable owned by the current user.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `name` | TEXT | ❌ Literal | Variable name |

```sql
SELECT df.getvar('api_url');
```

---

### df.unsetvar(name)

Removes a workflow variable owned by the current user.
`df.unsetvar` is a setup helper, not a workflow node.

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `name` | TEXT | ❌ Literal | Variable name |

```sql
SELECT df.unsetvar('api_url');
```

---

### df.clearvars()

Clears all workflow variables owned by the current user.
`df.clearvars` is a setup helper, not a workflow node.

```sql
SELECT df.clearvars();
```

---

## Quick Reference: Auto-Wrap Summary

| Function | Parameters with Auto-Wrap |
|----------|---------------------------|
| `df.seq(a, b)` | `a`, `b` |
| `df.as(fut, name)` | `fut` |
| `df.join(a, b)` | `a`, `b` |
| `df.join3(a, b, c)` | `a`, `b`, `c` |
| `df.race(a, b)` | `a`, `b` |
| `df.if(cond, then, else)` | `cond`, `then`, `else` |
| `df.loop(body, cond)` | `body`, `cond` |
| `df.start(fut, label)` | `fut` |
| All others | No auto-wrap (literals only) |

**Rule of thumb:** If a parameter expects a "node" (something that executes), it supports auto-wrap. If it expects a configuration value (name, URL, timeout), it's a literal.

---

## Administration Functions

### df.grant_usage(role_name [, include_http] [, with_grant])

Grants the privileges a role needs to use pg_durable. By default this grants general `df` usage but does not grant `EXECUTE` on `df.http()`. Pass `include_http => true` to opt a role into HTTP access. Pass `with_grant => true` to allow the role to delegate access to others.

Authorization is enforced by PostgreSQL’s native mechanisms: EXECUTE on this function is revoked from PUBLIC (so only roles explicitly granted access can call it), and the inner GRANT statements run as the caller via SECURITY INVOKER, so the caller must hold the underlying privileges WITH GRANT OPTION.

| Parameter | Type | Description |
|-----------|------|-------------|
| `role_name` | TEXT | The role to grant privileges to |
| `include_http` | BOOLEAN | Optional, defaults to `false`; when `true`, also grants `EXECUTE` on `df.http(text, text, text, jsonb, integer)` |
| `with_grant` | BOOLEAN | Optional, defaults to `false`; when `true`, grants all privileges WITH GRANT OPTION and retains EXECUTE on `df.grant_usage` / `df.revoke_usage` |

```sql
SELECT df.grant_usage('app_role');
SELECT df.grant_usage('app_role', include_http => true);
SELECT df.grant_usage('admin_role', with_grant => true);
```

### df.revoke_usage(role_name)

Revokes all privileges previously granted by `df.grant_usage()`, including any `df.http()` access. Authorization is enforced the same way as `df.grant_usage()` — EXECUTE is revoked from PUBLIC, and the inner REVOKE statements run as the caller. On upgraded installs, revoking `df.http()` from `PUBLIC` is still a separate manual step.

| Parameter | Type | Description |
|-----------|------|-------------|
| `role_name` | TEXT | The role to revoke privileges from |

```sql
SELECT df.revoke_usage('app_role');
```

---

## Server Configuration (GUCs)

These settings are configured via `ALTER SYSTEM SET` or `postgresql.conf` and take effect after `SELECT pg_reload_conf()` (no restart required).

---

### pg_durable.enable_superuser_instances

Controls whether pg_durable allows durable function instances whose `submitted_by` role is a PostgreSQL superuser.

| Property | Value |
|----------|-------|
| Type | `boolean` |
| Default | `off` |
| Context | `SUSET` (superuser can change at runtime; no restart needed) |
| Visibility | Hidden from `SHOW ALL` and `pg_settings` for non-superusers |

**When `off` (default):**
- `df.start()` raises an error immediately if `current_user` is a superuser.
- The background worker rejects any instance whose `submitted_by` resolves to a superuser at execution time, even if the row was tampered with after submission.

**When `on`:**
- Superusers may submit durable functions. Their SQL nodes execute with superuser privileges.
- Intended for administrative tasks in single-tenant or fully-trusted deployments.

```sql
-- Enable (requires superuser)
ALTER SYSTEM SET pg_durable.enable_superuser_instances = on;
SELECT pg_reload_conf();

-- Disable (default; recommended for multi-tenant)
ALTER SYSTEM SET pg_durable.enable_superuser_instances = off;
SELECT pg_reload_conf();

-- Check current value (superuser only)
SHOW pg_durable.enable_superuser_instances;
```

**Security note:** Setting this GUC to `on` in a multi-tenant environment allows any role with `BYPASSRLS` to forge `submitted_by` to a superuser OID and execute arbitrary SQL as superuser. Keep `off` unless you have a specific need and understand the risk. See [docs/superuser_guc.md](superuser_guc.md) for the full threat analysis.

---

### pg_durable.list_instances_max_limit

Maximum number of rows `df.list_instances()` returns in a single call. A request for more rows than this raises an error instead of silently truncating the result, so external clients paginate explicitly (via `after_cursor`/`next_cursor`) rather than relying on a silent cap.

| Property | Value |
|----------|-------|
| Type | `integer` |
| Default | `1000` |
| Range | `1` – `1000000` |
| Context | `SUSET` (superuser can change at runtime; no restart needed) |

Both `df.list_instances()` overloads (basic and paginated) enforce this cap. By default an ordinary (non-superuser) caller cannot raise it, so the guardrail holds from a user session — a superuser may delegate that ability with `GRANT SET ON PARAMETER pg_durable.list_instances_max_limit TO <role>`, but without that grant it stays superuser-settable only.

> **Sizing note:** `df.list_instances()` materializes up to `limit_count` rows per call, so raise the cap only as high as a single response should reasonably hold. For very large exports, prefer paging with `after_cursor`/`next_cursor` over one huge page rather than setting the cap near its maximum.

```sql
-- Inspect the current cap
SHOW pg_durable.list_instances_max_limit;

-- Raise it for an admin reporting workload (requires superuser)
ALTER SYSTEM SET pg_durable.list_instances_max_limit = 5000;
SELECT pg_reload_conf();
```

> **Behavior change (v0.2.4):** prior to v0.2.4, `df.list_instances()` silently truncated `limit_count` to 10000. It now raises an error when `limit_count` exceeds this GUC (default 1000). Callers that previously requested very large pages should lower `limit_count` or use the paginated overload (`after_cursor`/`next_cursor`).

