# Durable Functions Grammar

This document defines the formal grammar for pg_durable's DSL expressions.

## Notation

```
UPPERCASE     = terminal (keyword, operator)
lowercase     = non-terminal
'literal'     = literal string
|             = alternative
[]            = optional
{}            = zero or more
()            = grouping
```

## Grammar Rules

### Top-Level

```ebnf
durable_function ::= df.start( expression [, label] )

label ::= STRING
```

### Expressions

```ebnf
expression ::= loop_expr

loop_expr ::= '@>' loop_expr
            | cond_expr

cond_expr ::= sequence_expr '?>' sequence_expr '!>' sequence_expr
            | sequence_expr

sequence_expr ::= parallel_expr { '~>' parallel_expr }

parallel_expr ::= race_expr { '&' race_expr }

race_expr ::= bind_expr { '|' bind_expr }

bind_expr ::= atom_expr [ '|=>' NAME ]

atom_expr ::= '(' expression ')'
            | sql_string
            | node_function
```

### Node Functions

```ebnf
node_function ::= df.sql( QUERY )
                | df.sleep( SECONDS )
                | df.wait_for_schedule( CRON_EXPR )
                | df.wait_for_signal( NAME [, TIMEOUT] )
                | df.http( URL [, METHOD [, BODY [, HEADERS [, TIMEOUT]]]] )
                | df.join( expression, expression )
                | df.join3( expression, expression, expression )
                | df.race( expression, expression )
                | df.seq( expression, expression )
                | df.if( condition, then_expr, else_expr )
                | df.loop( expression [, condition] )
                | df.break( [value] )
                | df.as( expression, NAME )
```

### Terminals

```ebnf
QUERY       ::= SQL query string (single-quoted)
SECONDS     ::= positive integer
CRON_EXPR   ::= cron expression (5-part: "min hour dom month dow")
NAME        ::= identifier string
URL         ::= HTTP/HTTPS URL string
METHOD      ::= 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH'
BODY        ::= JSON string (supports $variable substitution)
HEADERS     ::= JSONB object
TIMEOUT     ::= positive integer (seconds)
STRING      ::= single-quoted SQL string
```

## Operator Precedence

From highest to lowest binding:

| Precedence | Operator | Associativity | Meaning |
|------------|----------|---------------|---------|
| 1 (highest) | `|=>`   | left          | Bind result to variable |
| 2          | `&`      | left          | Parallel join (wait all) |
| 3          | `\|`     | left          | Race (first wins) |
| 4          | `~>`     | left          | Sequence (then) |
| 5          | `?>` `!>` | right        | Conditional (if-then-else) |
| 6 (lowest) | `@>`     | prefix        | Loop (forever) |

## Examples

### Sequence

```sql
-- Using operator
'SELECT 1' ~> 'SELECT 2' ~> 'SELECT 3'

-- Using function
df.seq(df.seq('SELECT 1', 'SELECT 2'), 'SELECT 3')
```

### Parallel Join

```sql
-- Wait for both to complete
'SELECT pg_sleep(1)' & 'SELECT pg_sleep(2)'

-- Three-way join
df.join3('SELECT 1', 'SELECT 2', 'SELECT 3')
```

### Race

```sql
-- First to complete wins
df.sleep(10) | df.wait_for_signal('cancel')
```

### Binding Results

```sql
-- Bind SQL result to variable
'SELECT id FROM users LIMIT 1' |=> 'user_id'
~> 'SELECT * FROM orders WHERE user_id = $user_id'

-- Bind HTTP response
df.http('https://api.example.com/data') |=> 'response'
~> 'INSERT INTO api_data VALUES ($response::jsonb)'
```

### Conditionals

```sql
-- If-then-else with operators
'SELECT count(*) > 0 FROM users' 
    ?> 'SELECT ''has users'''
    !> 'SELECT ''no users'''

-- Using function
df.if(
    'SELECT balance > 100 FROM accounts WHERE id = 1',
    'UPDATE accounts SET status = ''gold'' WHERE id = 1',
    'UPDATE accounts SET status = ''standard'' WHERE id = 1'
)
```

### Loops

```sql
-- Infinite loop with @> operator
@> (
    df.wait_for_schedule('*/5 * * * *')
    ~> 'INSERT INTO heartbeats VALUES (now())'
)

-- While loop (continues while condition is true)
df.loop(
    'SELECT process_item()',
    'SELECT count(*) > 0 FROM queue'  -- while queue has items
)

-- Loop with df.break() to exit
df.loop(
    'SELECT process_batch()' |=> 'batch'
    ~> (
        '$batch.done'
            ?> df.break('{"status": "complete"}')  -- exit with value
            !> df.sleep(5)
    )
)

-- Loop with escape via race (alternative to break)
@> (
    'CALL process_queue()'
    ~> df.sleep(60)
) | df.wait_for_signal('shutdown')
```

### Signals

```sql
-- Wait for human approval
'INSERT INTO orders VALUES (...) RETURNING id' |=> 'order_id'
~> df.wait_for_signal('approval', 3600)  -- 1 hour timeout
~> 'UPDATE orders SET status = CASE 
        WHEN $approval.timed_out THEN ''expired''
        ELSE ''approved'' 
    END WHERE id = $order_id'
```

### HTTP Requests

```sql
-- GET request
df.http('https://api.github.com/repos/owner/repo/commits', 'GET')

-- POST with body and headers
df.http(
    'https://api.example.com/webhook',
    'POST',
    '{"event": "completed", "id": $order_id}',
    '{"Authorization": "Bearer $token", "Content-Type": "application/json"}'::jsonb,
    30
)
```

### Combined Example

```sql
df.start(
    -- Step 1: Create order
    'INSERT INTO orders (customer_id, amount) 
     VALUES (42, 100.00) RETURNING id' |=> 'order_id'
    
    -- Step 2: Parallel - reserve inventory and notify
    ~> (
        'UPDATE inventory SET reserved = reserved + 1 WHERE sku = ''WIDGET'''
        &
        df.http('https://hooks.slack.com/...', 'POST', '{"text": "New order $order_id"}')
    )
    
    -- Step 3: Wait for payment confirmation
    ~> (
        df.wait_for_signal('payment_confirmed', 86400)  -- 24 hour timeout
        | df.wait_for_signal('payment_failed')
    ) |=> 'payment'
    
    -- Step 4: Conditional completion
    ~> (
        '$payment.signal_name = ''payment_confirmed'''
            ?> 'UPDATE orders SET status = ''completed'' WHERE id = $order_id'
            !> 'UPDATE orders SET status = ''failed'' WHERE id = $order_id'
    ),
    'order-workflow'  -- label
);
```

## Variable Substitution

Variables are set before `df.start()` using `df.setvar()`:

```sql
SELECT df.setvar('customer_id', '42');
SELECT df.setvar('sku', 'WIDGET-001');
SELECT df.start('SELECT * FROM products WHERE sku = $sku');
```

Result bindings (`|=>`) create variables available in subsequent steps:

```sql
'SELECT id FROM users WHERE email = $email' |=> 'user_id'
~> 'SELECT * FROM orders WHERE user_id = $user_id'
```

Variables are substituted at execution time, not at definition time.

## Auto-Wrapping

Plain SQL strings are automatically wrapped in `df.sql()`:

```sql
-- These are equivalent:
'SELECT 1' ~> 'SELECT 2'
df.sql('SELECT 1') ~> df.sql('SELECT 2')
df.seq(df.sql('SELECT 1'), df.sql('SELECT 2'))
```

This applies to all operator positions and function arguments.

## Node Types

| Type | Created By | Description |
|------|------------|-------------|
| `SQL` | `df.sql()`, plain strings | Execute SQL query |
| `THEN` | `~>`, `df.seq()` | Sequential execution |
| `JOIN` | `&`, `df.join()` | Parallel, wait all |
| `RACE` | `\|`, `df.race()` | Parallel, first wins |
| `IF` | `?>` `!>`, `df.if()` | Conditional branch |
| `LOOP` | `@>`, `df.loop()` | Loop (infinite or while-condition) |
| `BREAK` | `df.break()` | Exit enclosing loop with optional value |
| `SLEEP` | `df.sleep()` | Pause for N seconds |
| `WAIT_SCHEDULE` | `df.wait_for_schedule()` | Wait for cron match |
| `SIGNAL` | `df.wait_for_signal()` | Wait for external event |
| `HTTP` | `df.http()` | Make HTTP request |
| `CALL` | `df.call()` | Invoke sub-orchestration |

## Future: Compensation (Proposed)

```ebnf
bind_expr ::= compensate_expr [ '|=>' NAME ]

compensate_expr ::= atom_expr [ '<->' atom_expr ]
                  | atom_expr
```

See [spec-compensation.md](spec-compensation.md) for details.

