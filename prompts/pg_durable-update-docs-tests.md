# Update Documentation and Tests After Code Changes

## Objective
Ensure all documentation is accurate, complete, and helpful after code changes. Also propose additional E2E tests to cover the changes.

## Step 1: Scan Changes and Propose Tests

**First, analyze what changed:**
1. Run `git diff --cached` to see staged changes
2. Run `git diff` to see unstaged changes
3. Identify new features, bug fixes, or behavior changes

**For each significant change, propose tests:**
- New DSL functions → E2E tests in `tests/e2e/sql/`
- New operators → E2E tests with both operator and function variants
- Bug fixes → Regression tests
- API changes → Example updates in USER_GUIDE.md

**Ask the user:**
- Present a list of changes found
- Propose specific tests for each change
- Ask which tests to implement before proceeding

## Step 2: Documentation Hierarchy

### 2.1 User-Facing Guide (Priority: High, MUST scan)

**`USER_GUIDE.md`** - Main user documentation

**Review criteria:**
- Examples compile and use current SQL syntax
- All DSL functions are documented in the reference table
- All operators are documented with examples
- Code patterns match working E2E tests
- Instructions are prescriptive and actionable
- Examples are succinct but complete

### 2.2 Other Documentation (Priority: Medium)

- **`README.md`** - Project overview, quick examples
- **`docs/TESTING.md`** - Testing setup and commands
- **`docs/pg_durable_mvp.md`** - MVP specification

**Review criteria:**
- README has accurate quick start example
- Testing docs reflect current script locations
- All commands actually work

### 2.3 Code Documentation (Priority: Medium)

Review doc comments in public-facing modules:
- **`src/dsl.rs`** - DSL functions (`df.sql()`, `df.if()`, etc.)
- **`src/monitoring.rs`** - Monitoring functions
- **`src/explain.rs`** - Explain function
- **`src/types.rs`** - Core types

## Step 3: E2E Test Updates

### Test File Naming Convention
```
tests/e2e/sql/
├── 00_setup_playground.sql      # Setup test data
├── 01_simple_sql.sql            # Basic tests
├── 02_sequence.sql              # Sequence operator
├── ...
├── 11_scenario_etl.sql          # Scenario tests
├── 12_scenario_*.sql            # More scenarios
└── 17_race.sql                  # Feature tests
```

### Test File Structure
```sql
-- Test: [Feature Name]
-- Tests [what variants/features]
-- Expected: [expected behavior]

-- Setup
DROP TABLE IF EXISTS test_table;
CREATE TABLE test_table (...);

-- Test variant A
SELECT df.start(...);

-- Test variant B (if applicable)
SELECT df.start(...);

-- Wait for completion
SELECT pg_sleep(N);

-- Verify
DO $$
DECLARE
    status TEXT;
BEGIN
    -- Check status
    SELECT s INTO status FROM df.status(inst_id) s;
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
    
    -- Additional assertions...
    
    RAISE NOTICE 'TEST PASSED: feature_name';
END $$;

-- Cleanup
DROP TABLE test_table;
SELECT 'TEST PASSED' AS result;
```

### Running Tests
```bash
# Run all E2E tests
./scripts/test-e2e-local.sh

# Run specific test
./scripts/test-e2e-local.sh 04_parallel

# Keep server running for debugging
./scripts/test-e2e-local.sh --keep

# Connect to debug
psql -h localhost -p 28817 -d postgres
```

## Step 4: Ensure USER_GUIDE Examples Have E2E Coverage

Every example in `USER_GUIDE.md` should have a corresponding E2E test to ensure documentation stays accurate as code evolves.

### USER_GUIDE Example → E2E Test Mapping

| USER_GUIDE Section | Example | E2E Test File |
|--------------------|---------|---------------|
| Getting Started | Simple query | `01_simple_sql.sql` |
| Function Examples | 1. Simple Query | `01_simple_sql.sql` |
| Function Examples | 2. Sequential Steps | `02_sequence.sql`, `15_scenario_three_step.sql` |
| Function Examples | 3. Multi-Step ETL | `11_scenario_etl.sql` |
| Function Examples | 4. With Variables | `03_variables.sql`, `14_scenario_order_processing.sql` |
| Function Examples | 5. Parallel Execution | `04_parallel_join.sql`, `12_scenario_parallel_counts.sql`, `16_scenario_join3.sql` |
| Function Examples | 6. Conditional Logic | `05_conditional_true.sql`, `06_conditional_false.sql`, `13_scenario_conditional_load.sql` |
| Function Examples | 7. Task Queue Processor | `14_scenario_order_processing.sql` (similar pattern) |
| Loops & Cron Jobs | Eternal Loops | `08_loop_cancel.sql` |
| Loops & Cron Jobs | df.sleep() | `07_sleep.sql` |
| DSL Reference | Race operator | `17_race.sql` |
| Monitoring | df.explain() | `10_explain.sql` |
| Monitoring | list_instances, status, result | `09_monitoring.sql` |

### Checking Coverage

**Run this checklist when updating USER_GUIDE.md:**

1. **List all examples in USER_GUIDE.md:**
   ```bash
   grep -n "SELECT df.start" USER_GUIDE.md | head -30
   ```

2. **List all E2E tests:**
   ```bash
   ls tests/e2e/sql/*.sql
   ```

3. **For each USER_GUIDE example, verify:**
   - [ ] There's an E2E test that exercises the same pattern
   - [ ] The E2E test uses the same syntax (operators vs functions)
   - [ ] The E2E test actually passes

4. **If an example lacks coverage:**
   - Create a new scenario test in `tests/e2e/sql/`
   - Name it appropriately (e.g., `18_scenario_<pattern>.sql`)
   - Follow the test file structure from Step 3

### Example Coverage Audit

Before finalizing documentation changes, run this audit:

```bash
# Run all E2E tests to ensure they pass
./scripts/test-e2e-local.sh

# Count examples in USER_GUIDE vs tests
echo "USER_GUIDE examples:"
grep -c "SELECT df.start" USER_GUIDE.md

echo "E2E scenario tests:"
ls tests/e2e/sql/*scenario*.sql | wc -l
```

### Adding Missing Coverage

If USER_GUIDE has an example without E2E coverage:

1. **Identify the pattern** - What DSL features does it use?
2. **Check existing tests** - Maybe coverage exists under a different name
3. **Create new test if needed** - Use `@pg_durable-create-scenario-test.md` prompt
4. **Verify the example works** - Copy-paste from USER_GUIDE into test

### What Requires E2E Coverage

**Must have tests:**
- Every operator (`~>`, `|=>`, `&`, `|`, `?>`, `!>`, `@>`)
- Every DSL function (`df.sql`, `df.sleep`, `df.join`, `df.race`, `df.if`, `df.loop`)
- Every monitoring function (`df.status`, `df.result`, `df.list_instances`, etc.)
- Variable substitution patterns
- Complex nested structures (loops containing conditionals, etc.)

**Nice to have:**
- Edge cases mentioned in documentation
- Error handling examples
- Performance-sensitive patterns

## Step 5: Validation Checklist

### Documentation
- [ ] USER_GUIDE.md examples use current syntax (`df.` schema)
- [ ] All operators documented (`~>`, `|=>`, `&`, `|`, `?>`, `!>`, `@>`)
- [ ] All functions documented in reference table
- [ ] Quick Reference Card is accurate
- [ ] No references to old `durable.` schema

### Tests
- [ ] New features have E2E tests
- [ ] Tests cover both operator and function variants where applicable
- [ ] Tests clean up after themselves
- [ ] Tests have clear PASSED/FAILED output
- [ ] `./scripts/test-e2e-local.sh` passes all tests

### Code
- [ ] `cargo build --features pg17` succeeds
- [ ] `cargo clippy --features pg17` has no warnings
- [ ] `cargo pgrx test --features pg17` passes

## Common Issues to Watch For

1. **Outdated schema name** - Using `durable.` instead of `df.`
2. **Missing operator documentation** - New operators not in reference
3. **Broken examples** - SQL that doesn't match current API
4. **Incomplete test variants** - Missing operator or function variant
5. **Hardcoded instance IDs** - Tests that don't generate unique IDs
6. **Missing cleanup** - Tests that leave tables/functions behind

## Quality Standards

### Good Documentation
- **Prescriptive**: "Do X, then Y" not "You could do X"
- **Complete**: Shows full context, not just fragments
- **Accurate**: Actually compiles and works
- **Helpful**: Explains why, not just how

### Good Examples
```sql
-- ✅ GOOD: Complete, explains purpose
-- Process orders in parallel with timeout protection
SELECT df.start(
    'SELECT id FROM orders WHERE status = ''pending'' LIMIT 1' |=> 'order_id'
    ~> (
        'UPDATE orders SET status = ''processing'' WHERE id = $order_id'
        | df.sleep(30)  -- 30 second timeout
    ),
    'process-order'
);
```

### Poor Examples
```sql
-- ❌ BAD: Incomplete, no context
df.start('SELECT 1')
```

## Ask Before Making Large Changes

If documentation updates require:
- Creating new guide documents
- Removing entire sections
- Restructuring organization
- Adding new example files
- Implementing more than 3 new tests

Then summarize the proposed changes and ask for confirmation before proceeding.

## Step 6: Final Validation

After completing documentation and test updates:

1. Run `./scripts/test-e2e-local.sh` - All tests should pass
2. Verify USER_GUIDE.md examples by copy-pasting into psql
3. Check that new features are documented
4. Verify no broken internal links

