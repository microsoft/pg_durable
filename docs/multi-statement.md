# Multi-Statement SQL Support

## Motivation

Users naturally want to write multi-statement SQL in `df.sql()`:

```sql
SELECT df.start(
    df.sql('INSERT INTO audit_log VALUES (now(), ''start'');
            UPDATE accounts SET balance = balance - 100 WHERE id = 1;
            UPDATE accounts SET balance = balance + 100 WHERE id = 2;
            INSERT INTO audit_log VALUES (now(), ''done'')'),
    'transfer-funds'
);
```

Without multi-statement support, users must chain each statement as a separate `df.sql()` node connected with `~>`. This is verbose for what is conceptually a single unit of work, and — critically — each `df.sql()` node executes as a separate activity (separate connection, separate transaction), so there is no atomicity across the group.

Multi-statement `df.sql()` gives users a way to execute several statements atomically within a single activity invocation.

## Technical Challenge

pg_durable uses [sqlx](https://github.com/launchbadge/sqlx) to execute SQL from the background worker. sqlx sends queries via PostgreSQL's **extended query protocol**, which does not support multiple commands in a single prepared statement. Attempting to do so produces:

```
ERROR: cannot insert multiple commands into a prepared statement
```

This is a PostgreSQL protocol-level restriction, not a sqlx bug. The extended query protocol parses, binds, and executes a single statement per message cycle. The **simple query protocol** does support multiple statements in one message, but sqlx does not expose it.

## Alternatives Considered

### A1: Use the simple query protocol

PostgreSQL's simple query protocol (`PQexec` in libpq) accepts multiple semicolon-separated statements and executes them all. However, sqlx does not support the simple query protocol. Switching to a different driver (e.g., `tokio-postgres` with `simple_query`) would be a significant change with ripple effects across the codebase.

**Verdict:** Too invasive. Would require replacing sqlx or maintaining a parallel driver just for this case.

### A2: Use `sqlx::raw_sql()`

sqlx provides `raw_sql()` which uses the simple query protocol. However, it returns raw protocol messages rather than typed rows, making result extraction (needed for `|=>` result piping) more complex. It also doesn't support parameterized queries, which could matter in future evolution.

**Verdict:** Viable but would require a separate code path for result extraction. The lack of typed rows means we'd lose the column-type detection logic. Worth revisiting if the splitting approach proves too fragile.

### A3: Split and execute sequentially (chosen)

Parse the SQL string to find statement boundaries (semicolons outside of string literals and comments), then execute each statement individually via the existing sqlx extended query protocol path. This reuses all existing result-handling code.

**Verdict:** Chosen. Minimal change, reuses existing infrastructure, handles the common cases well.

### A4: Wrap in a DO block

Wrap the user's SQL in `DO $$ BEGIN ... END $$` to let PostgreSQL handle multi-statement execution natively. This works for DML but not for statements that return rows (SELECT), since DO blocks cannot return results.

**Verdict:** Not viable. Breaks `|=>` result piping for any multi-statement block ending with SELECT.

## Design

### Statement Splitting

The `split_statements()` parser splits SQL by semicolons while respecting:

- **Single-quoted strings:** `'it''s a semicolon: ;'` — semicolons inside string literals are not split points
- **Dollar-quoted strings:** `$$body with ; inside$$` and `$tag$...$tag$` — common in function bodies
- **Single-line comments:** `-- comment with ;` — semicolons in comments are ignored
- **Block comments:** `/* comment with ; */` — likewise ignored

The parser is intentionally simple. It does not handle all PostgreSQL syntax edge cases (e.g., the `E'\;'` escape string syntax). This covers the vast majority of real-world usage.

### Execution Model

When multiple statements are detected:

1. All statements execute **sequentially** on the **same connection**
2. The entire block is wrapped in a **single transaction** (`BEGIN` / `COMMIT`), with `ROLLBACK` on any error
3. The **result of the last statement** is returned as the node's output (for `|=>` piping)
4. If any statement fails, the entire block is rolled back and the activity returns an error

The transaction wrapping is critical: without it, a failure in statement N would leave statements 1..N-1 committed, producing a partial-execution state that is difficult to reason about or recover from.

Single-statement SQL nodes are **not** wrapped in an explicit transaction (preserving existing behavior where each statement runs in PostgreSQL's implicit auto-commit transaction).

### Result Semantics

For a multi-statement block like:

```sql
df.sql('INSERT INTO t1 VALUES (1); INSERT INTO t2 VALUES (2); SELECT count(*) AS n FROM t1')
```

The returned result is `{"rows": [{"n": 1}], "row_count": 1}` — only the last statement's output. Intermediate statement results are discarded. This matches the behavior of `psql` and most SQL tools when running multiple statements.

## Limitations

- **No per-statement result access:** Only the last statement's result is available via `|=>`. If you need results from intermediate statements, use separate `df.sql()` nodes.
- **Dollar signs in variable substitution:** pg_durable uses `$name` for variable substitution (`|=>` results). If a multi-statement block contains dollar-quoted strings, the `$` signs could conflict with variable substitution. In practice this is rare since variable substitution happens before statement splitting, and dollar-quoting uses `$$` or `$tag$` patterns that are unlikely to collide with result names.
- **Parser simplicity:** The semicolon splitter is not a full SQL parser. Exotic syntax may confuse it. For complex multi-statement logic, consider using a PL/pgSQL DO block or separate `df.sql()` nodes.

## Life without multi-statement support

Given the transfer-funds example, here are the options users have today to execute multiple statements atomically within a single `df.sql()` node:

### 1. PL/pgSQL DO block (simplest for DML-only)

```sql
SELECT df.start(
    df.sql('DO $$
    BEGIN
        INSERT INTO audit_log VALUES (now(), ''start'');
        UPDATE accounts SET balance = balance - 100 WHERE id = 1;
        UPDATE accounts SET balance = balance + 100 WHERE id = 2;
        INSERT INTO audit_log VALUES (now(), ''done'');
    END $$'),
    'transfer-funds'
);
```

This is a **single statement** (the `DO` block), so it works with sqlx's extended query protocol. PostgreSQL executes all inner statements atomically. **Limitation:** DO blocks cannot return results, so `|=>` piping from this node won't produce useful output. For pure DML like this example, that's fine.

### 2. Stored function (best if you need a return value)

```sql
CREATE FUNCTION transfer_funds() RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log VALUES (now(), 'start');
    UPDATE accounts SET balance = balance - 100 WHERE id = 1;
    UPDATE accounts SET balance = balance + 100 WHERE id = 2;
    INSERT INTO audit_log VALUES (now(), 'done');
    RETURN jsonb_build_object('status', 'ok');
END $$;
```

Then:

```sql
SELECT df.start(
    df.sql('SELECT transfer_funds()') |=> 'result'
    ~> 'SELECT $result',
    'transfer-funds'
);
```

This is a single `SELECT` statement, fully compatible with `|=>`. The function body executes atomically within the calling transaction. **Trade-off:** requires DDL upfront (creating the function), but gives maximum flexibility — parameters, return values, error handling with `EXCEPTION` blocks, etc.

### 3. Writeable CTE (single-statement trick, limited)

```sql
SELECT df.start(
    df.sql('WITH
        log_start AS (INSERT INTO audit_log VALUES (now(), ''start'') RETURNING 1),
        debit AS (UPDATE accounts SET balance = balance - 100 WHERE id = 1 RETURNING 1),
        credit AS (UPDATE accounts SET balance = balance + 100 WHERE id = 2 RETURNING 1),
        log_done AS (INSERT INTO audit_log VALUES (now(), ''done'') RETURNING 1)
    SELECT ''ok'' AS status'),
    'transfer-funds'
);
```

This is technically a **single SQL statement**, so it works with the extended query protocol and supports `|=>`. **Limitations:** CTE branches execute in an unspecified order (PostgreSQL may reorder or parallelize them), so this doesn't guarantee the audit log entries are written before/after the updates. Also, if you need conditional logic or loops inside the block, CTEs can't express that. Best suited for independent-but-atomic mutations.

### 4. Stored procedure (CALL)

```sql
CREATE PROCEDURE transfer_funds() LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log VALUES (now(), 'start');
    UPDATE accounts SET balance = balance - 100 WHERE id = 1;
    UPDATE accounts SET balance = balance + 100 WHERE id = 2;
    INSERT INTO audit_log VALUES (now(), 'done');
END $$;
```

Then:

```sql
SELECT df.start(df.sql('CALL transfer_funds()'), 'transfer-funds');
```

Works atomically. **Difference from functions:** procedures support internal `COMMIT`/`ROLLBACK` (transaction control), which functions cannot do. However, `CALL` statements don't return result rows, so `|=>` won't capture output — similar limitation to the DO block. Procedures are better suited when you need explicit transaction control *within* the body itself.

### Summary

| Approach | Atomic | Returns results (`\|=>`) | Requires DDL | Execution order guaranteed |
|----------|--------|--------------------------|-------------|---------------------------|
| DO block | Yes | No | No | Yes |
| Stored function | Yes | Yes | Yes (`CREATE FUNCTION`) | Yes |
| Writeable CTE | Yes | Yes | No | No (order unspecified) |
| Stored procedure | Yes | No | Yes (`CREATE PROCEDURE`) | Yes |

**Recommendation:** For DML-only blocks (like the transfer example), a **DO block** is the simplest — no DDL needed, fully atomic, single statement. If you need to pipe results downstream with `|=>`, use a **stored function**. Writeable CTEs work for simple cases but the unspecified execution order makes them unsuitable when ordering matters (like audit logging before/after).