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

### df.result(instance_id)

Gets instance result (for completed instances).

| Parameter | Type | Auto-wrap | Description |
|-----------|------|-----------|-------------|
| `instance_id` | TEXT | ❌ Literal | Target instance ID |

```sql
SELECT df.result('a1b2c3d4');
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

