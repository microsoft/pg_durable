# Extension Creation Security Test

## Test: 25_extension_creation_security.sql

### Purpose
This test validates that the pg_durable extension enforces critical security requirements during installation:

1. **Superuser-only installation**: Only superusers can create the extension
2. **Schema creation enforcement**: The extension must create the 'df' schema; attackers cannot pre-create it

### Security Rationale

#### Superuser Requirement
The pg_durable extension requires superuser privileges to install (specified in `pg_durable.control` with `superuser = true`). This is necessary because:
- The extension creates a background worker that executes with elevated privileges
- The extension uses security-sensitive PostgreSQL APIs
- This follows the trusted extension model (similar to pg_cron, postgis, etc.)

#### Schema Pre-creation Prevention
The extension must always create the 'df' schema to prevent privilege escalation attacks:
- If an attacker could pre-create the schema, they might be able to control objects within it
- The extension enforces this by declaring the schema with `#[pg_schema]` in the Rust code
- PostgreSQL will fail extension creation if the schema already exists

### Test Structure

The test:
1. Drops the existing extension (if present)
2. Tests non-superuser creation (should fail)
3. Tests creation with pre-existing 'df' schema (should fail)
4. Restores the extension for subsequent tests

### Expected Behavior

#### Test 1: Non-superuser Creation
```
SET ROLE test_nonsuperuser;
CREATE EXTENSION pg_durable;
-- Expected: ERROR: permission denied
```

#### Test 2: Pre-existing Schema
```
CREATE SCHEMA df;
CREATE EXTENSION pg_durable;
-- Expected: ERROR: schema "df" already exists
```

### Running the Test

```bash
# Run all E2E tests (includes this test)
./scripts/test-e2e-local.sh

# Run only this test
./scripts/test-e2e-local.sh 25_extension
```

### References
- [Security Model Specification](../../../docs/spec-security-model.md)
- [pg_durable.control](../../../pg_durable.control)
- [Extension Schema Declaration](../../../src/lib.rs#L38-L39)
