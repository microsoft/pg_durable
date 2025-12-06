# pg_durable Test Specification

This document describes the test suite for the `pg_durable` PostgreSQL extension. All tests are executed using pgrx's `#[pg_test]` framework, which runs tests inside a live PostgreSQL instance.

## Test Environment

### Configuration

Tests run with the following PostgreSQL configuration:

```
shared_preload_libraries = 'pg_durable'
```

This ensures the background worker is loaded during test execution, enabling full integration testing of features that depend on the Duroxide runtime.

### Test Framework

- **Framework**: pgrx `#[pg_test]`
- **Execution**: Tests run inside a PostgreSQL process with full SPI access
- **Database**: Each test runs in an isolated transaction that is rolled back

---

## Test Categories

### 1. DSL Node Creation Tests

These tests verify that each DSL function correctly creates workflow nodes with the expected structure.

#### `test_sql_creates_valid_durofut`

**Purpose**: Verify that `durable.sql()` creates a valid SQL node.

**Test Logic**:
1. Call `dsl::sql("SELECT 1")`
2. Deserialize the returned JSON into a `Durofut` struct
3. Assert `node_type` equals `"SQL"`
4. Assert `node_id` is not empty (UUID was generated)

**Validates**:
- SQL node creation
- UUID generation for node IDs
- Proper JSON serialization

---

#### `test_seq_creates_then_node`

**Purpose**: Verify that `durable.seq()` (the `~>` operator function) creates a THEN node linking two child nodes.

**Test Logic**:
1. Create two SQL nodes: `a = sql("SELECT 1")`, `b = sql("SELECT 2")`
2. Call `then_fn(&a, &b)` to sequence them
3. Assert `node_type` equals `"THEN"`
4. Assert `left_node` is `Some` (references node `a`)
5. Assert `right_node` is `Some` (references node `b`)

**Validates**:
- Sequence node creation
- Child node linkage (left/right references)
- Tree structure integrity

---

#### `test_as_named_sets_result_name`

**Purpose**: Verify that `durable.as()` (the `|=>` operator function) sets the result name on a node.

**Test Logic**:
1. Create a SQL node
2. Call `as_named("my_result", &sql_json)`
3. Assert `result_name` equals `Some("my_result")`

**Validates**:
- Result naming for variable substitution
- Node metadata update without changing node type

---

#### `test_sleep_creates_valid_node`

**Purpose**: Verify that `durable.sleep()` creates a SLEEP node with duration stored correctly.

**Test Logic**:
1. Call `dsl::sleep(60)` (60 seconds)
2. Assert `node_type` equals `"SLEEP"`
3. Assert `query` equals `Some("60")` (duration stored as string)

**Validates**:
- Sleep node creation
- Duration parameter storage in `query` field

---

#### `test_wait_for_schedule_valid_cron`

**Purpose**: Verify that `durable.wait_for_schedule()` creates a WAIT_SCHEDULE node with a valid cron expression.

**Test Logic**:
1. Call `wait_for_schedule("*/5 * * * *")` (every 5 minutes)
2. Assert `node_type` equals `"WAIT_SCHEDULE"`

**Validates**:
- Cron-based schedule node creation
- Cron expression parsing/validation (invalid expressions would cause panic)

---

#### `test_loop_creates_loop_node`

**Purpose**: Verify that `durable.loop()` creates a LOOP node with a body reference.

**Test Logic**:
1. Create a SQL node as the loop body
2. Call `loop_fn(&body)`
3. Assert `node_type` equals `"LOOP"`
4. Assert `left_node` is `Some` (body is stored in left_node)

**Validates**:
- Eternal loop node creation
- Body node linkage

---

#### `test_if_creates_if_node`

**Purpose**: Verify that `durable.if()` creates an IF node with condition and branches.

**Test Logic**:
1. Create three SQL nodes: condition, then_branch, else_branch
2. Call `if_fn(&condition, &then_branch, &else_branch)`
3. Assert `node_type` equals `"IF"`

**Validates**:
- Conditional branching node creation
- Multi-node reference storage (condition in query JSON, branches in left/right)

---

#### `test_join_creates_join_node`

**Purpose**: Verify that `durable.join()` creates a JOIN node for parallel execution.

**Test Logic**:
1. Create two SQL nodes
2. Call `join(&a, &b)`
3. Assert `node_type` equals `"JOIN"`

**Validates**:
- Parallel join node creation
- Binary branch linkage

---

### 2. Instance Management Tests

These tests verify workflow instance lifecycle operations.

#### `test_start_returns_instance_id`

**Purpose**: Verify that `durable.start()` returns a valid 8-character hex instance ID.

**Test Logic**:
1. Create a SQL workflow
2. Call `start(&fut, None)` with no label
3. Assert returned ID length is exactly 8 characters
4. Assert all characters are hexadecimal digits

**Validates**:
- Instance ID generation format
- Short ID implementation (last 8 chars of UUID)

---

#### `test_start_with_label`

**Purpose**: Verify that `durable.start()` accepts an optional label parameter.

**Test Logic**:
1. Create a SQL workflow
2. Call `start(&fut, Some("my-test-workflow"))`
3. Assert returned ID length is 8 characters

**Validates**:
- Label parameter acceptance
- Instance creation with metadata

---

#### `test_start_creates_instance_row`

**Purpose**: Verify that `durable.start()` persists the instance to the database.

**Test Logic**:
1. Create and start a workflow with label "test-instance-row"
2. Query `durable.instances` table for the returned ID
3. Assert exactly 1 row exists with that ID

**Validates**:
- Database persistence
- Instance table population
- Foreign key integrity (instance ID matches)

---

#### `test_status_returns_pending_for_new`

**Purpose**: Verify that newly created instances have "pending" status.

**Test Logic**:
1. Create and start a workflow
2. Call `status(&instance_id)`
3. Assert status equals `Some("pending")`

**Validates**:
- Initial instance status
- Status retrieval function

---

### 3. SQL Operator Tests

These tests verify that custom SQL operators work correctly when invoked via SPI.

#### `test_seq_operator_via_sql`

**Purpose**: Verify the `~>` sequence operator works in pure SQL.

**Test Logic**:
1. Execute SQL: `SELECT durable.sql('SELECT 1') ~> durable.sql('SELECT 2')`
2. Parse the result as Durofut
3. Assert `node_type` equals `"THEN"`

**Validates**:
- Operator registration in PostgreSQL
- Operator binding to `durable.seq` function
- End-to-end SQL workflow construction

---

#### `test_as_operator_via_sql`

**Purpose**: Verify the `|=>` naming operator works in pure SQL.

**Test Logic**:
1. Execute SQL: `SELECT durable.sql('SELECT 1') |=> 'my_name'`
2. Parse the result as Durofut
3. Assert `result_name` equals `Some("my_name")`

**Validates**:
- Operator registration for naming
- Wrapper function `durable.as_op` (swaps argument order)
- Variable naming in SQL context

---

### 4. Edge Case Tests

These tests verify behavior in boundary conditions and ensure system robustness.

#### `test_multiple_starts_different_ids`

**Purpose**: Verify that each `start()` call generates a unique instance ID.

**Test Logic**:
1. Create one SQL workflow
2. Start it three times: `id1`, `id2`, `id3`
3. Assert `id1 != id2`, `id2 != id3`, `id1 != id3`

**Validates**:
- UUID uniqueness
- No ID reuse even for identical workflows
- Concurrent safety (each call gets unique ID)

---

#### `test_debug_db_path_returns_path`

**Purpose**: Verify that `debug_db_path()` returns a non-empty path.

**Test Logic**:
1. Call `debug_db_path()`
2. Assert the returned string is not empty

**Validates**:
- Configuration system works
- Duroxide store path resolution
- Debug function availability

---

## Test Coverage Summary

| Category | Tests | Coverage |
|----------|-------|----------|
| DSL Node Creation | 8 | SQL, THEN, AS, SLEEP, WAIT_SCHEDULE, LOOP, IF, JOIN |
| Instance Management | 4 | start, start with label, persistence, status |
| SQL Operators | 2 | `~>` sequence, `|=>` naming |
| Edge Cases | 2 | ID uniqueness, config paths |
| **Total** | **16** | |

## Running Tests

```bash
# Run all tests
cargo pgrx test pg17

# Run a specific test
cargo pgrx test pg17 test_sql_creates_valid_durofut

# Run with verbose output
cargo pgrx test pg17 -- --nocapture
```

## Test Limitations

1. **No Runtime Execution Tests**: Tests verify node creation and instance management but do not test actual workflow execution (which requires the background worker to process).

2. **No Network Tests**: Monitoring functions that query the Duroxide SQLite store are not fully tested because the runtime may not be actively processing during test execution.

3. **Isolated Transactions**: Each test runs in an isolated transaction, meaning tests cannot observe side effects from other tests.

## Future Test Additions

Recommended tests to add:

- **Workflow Execution**: Mock or wait for background worker to complete simple workflows
- **Variable Substitution**: Test `$name` replacement in SQL queries
- **Error Handling**: Test invalid cron expressions, malformed JSON, etc.
- **Monitoring Functions**: Test `list_instances()`, `metrics()`, `instance_info()` with pre-populated data
- **Cancellation**: Test `cancel()` updates status correctly

