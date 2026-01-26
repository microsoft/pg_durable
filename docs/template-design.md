
# Function Templates Design Document

**Status**: Draft  
**Date**: January 25, 2026  
**Feature**: Reusable variableized workflow templates  
**Specification**: See [spec-templates.md](spec-templates.md) for the complete feature specification

---

## Overview

This document provides a detailed design and implementation plan for the **Function Templates** feature in pg_durable, as specified in [spec-templates.md](spec-templates.md). Templates enable users to register variableizable, reusable workflows using the SQL-native DSL syntax, promoting DRY principles and safer workflow management.

**Key Design Decision:** Templates store DSL as **text strings** (like `df.explain()` input) with `{placeholder}` syntax. The DSL is parsed at instantiation time after variable substitution, not at registration time.

### Goals

1. Enable registration of reusable workflow patterns with explicit variables
2. Support safe variable substitution without SQL injection risks
3. Maintain full compatibility with existing DSL operators and functions
4. Provide clear lifecycle management (create, instantiate, drop)
5. Ensure template changes don't affect already-running instances

### Non-Goals

- Complex template version graphs (v1 supports a simple linear version history with a single active version per name and inactive historical rows)
- Template inheritance or composition
- Runtime variable modification of running instances
- Template import/export across databases

---

## Database Schema

### New Table: `df.templates`

```sql
CREATE TABLE IF NOT EXISTS df.templates (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    dsl_template TEXT NOT NULL,           -- DSL with {param} placeholders
    active BOOLEAN NOT NULL DEFAULT true, -- Whether this version is active
    created_at TIMESTAMPTZ DEFAULT now(),
    created_by TEXT DEFAULT current_user,
    description TEXT                       -- Optional user-provided description
);

-- Partial unique index: only one active template per name
CREATE UNIQUE INDEX IF NOT EXISTS idx_templates_name_active_unique 
    ON df.templates(name) WHERE active = true;

-- Index for listing templates by user
CREATE INDEX IF NOT EXISTS idx_templates_created_by 
    ON df.templates(created_by);

-- Add comments
COMMENT ON TABLE df.templates IS 
    'Stores reusable workflow templates with variableized DSL definitions';
COMMENT ON COLUMN df.templates.id IS 
    'Auto-generated unique template identifier';
COMMENT ON COLUMN df.templates.name IS 
    'Template name (unique among active templates)';
COMMENT ON COLUMN df.templates.dsl_template IS 
    'DSL expression with {param} placeholders for substitution';
COMMENT ON COLUMN df.templates.active IS 
    'Whether this template version is active (only one active version per name)';
```

### Extended Schema: `df.instances`

The existing `df.instances` table should track which template was used:

```sql
-- Add template_id column to instances table
ALTER TABLE df.instances 
    ADD COLUMN IF NOT EXISTS template_id BIGINT REFERENCES df.templates(id);

-- Index for finding instances by template_id
CREATE INDEX IF NOT EXISTS idx_instances_template_id 
    ON df.instances(template_id) 
    WHERE template_id IS NOT NULL;

-- Add comments
COMMENT ON COLUMN df.instances.template_id IS 
    'Foreign key to template used to create this instance (NULL for non-template instances). References preserve template history even if template is marked inactive.';
```

---
## Unified Variable Model

The variable system used by both direct `df.start` calls and `df.start_template` is unified and builds on the existing `df.vars` table:

- **Global variables** are stored in `df.vars` via `df.setvar(name, value)` and must be set before calling `df.start` or `df.start_template`.
- **Local variables** are supplied per-instance as a `JSONB` object:
    - For direct starts: `df.start(fut, label, local_vars := jsonb_build_object(...))`.
    - For templates: `df.start_template(template_name, label, params := jsonb_build_object(...))`.
- At start time, pg_durable:
    1. Captures a snapshot of `df.vars` as `global_vars`.
    2. Parses the `JSONB` argument into a `local_vars` map.
    3. Produces a merged `vars` map where `local_vars` override `global_vars` on key conflicts.

The orchestrator receives a `FunctionInput` payload that includes:

- `global_vars`: the captured snapshot from `df.vars`.
- `local_vars`: per-instance variables supplied with the start call.
- `vars`: the merged view used for `{placeholder}` substitution in DSL and for downstream features.

`df.start_template` uses the same model: its `params` argument is treated as `local_vars` for the started instance, providing a consistent precedence and substitution behavior across direct and template-based workflows.

---

## API Functions

### 1. `df.create_template()` - Register Template

**Signature:**
```sql
df.create_template(
    name TEXT,
    dsl_template TEXT,
    description TEXT DEFAULT NULL
) RETURNS TEXT
```

**Implementation (Rust):**

The Rust implementation stores the DSL text and enforces a single active version per `name`:

```rust
#[pg_extern(schema = "df")]
fn create_template(
    name: &str,
    dsl_template: &str,
    description: default!(Option<&str>, "NULL"),
) -> Result<String, String> {
    if name.is_empty() {
        return Err("Template name cannot be empty".to_string());
    }

    // Enforce one active template per name
    let exists_query = format!(
        "SELECT 1 FROM df.templates WHERE name = '{}' AND active = true",
        name.replace('\'', "''")
    );
    let exists: bool = Spi::get_one::<i32>(&exists_query).ok().flatten().is_some();
    if exists {
        return Err(format!(
            "Template '{}' already exists. Use df.update_template() to modify it or df.drop_template() to deactivate it.",
            name
        ));
    }

    // Persist template definition
    // ... matches the df.templates schema described above ...

    Ok(format!("Template '{}' registered successfully", name))
}
```

### 2. `df.start_template()` - Instantiate Template

**Signature:**
```sql
df.start_template(
    template_name TEXT,
    label TEXT DEFAULT NULL,
    params JSONB DEFAULT '{}'
) RETURNS TEXT
```

`params` participates in the unified variable model as the per-instance `local_vars` map. When `df.start_template` is invoked, pg_durable captures `df.vars` as `global_vars`, parses `params` into `local_vars`, merges them into `vars` (with `local_vars` taking precedence), performs `{placeholder}` substitution in the template DSL, and then starts the workflow using the rendered DSL.

**Implementation (Rust):**

```rust
#[pg_extern(schema = "df")]
fn start_template(
    template_name: &str,
    label: Option<&str>,
    params: pgrx::JsonB,
) -> Result<String, String> {
    // Load template from database
    let load_query = r#"
        SELECT name, dsl_template, description
        FROM df.templates
        WHERE name = $1
    "#;
    
    let result: Option<(String, String, Option<String>)> = 
        Spi::get_one_with_args(
            load_query,
            vec![(PgBuiltInOids::TEXTOID.oid(), template_name.into_datum())],
        )?;
    
    let (_name, dsl_template, _description) = result
        .ok_or_else(|| format!("Template '{}' not found", template_name))?;
    
    // Start the workflow (variable substitution happens during orchestration)
    let instance_id = dsl::start(&dsl_template, label, params);
    
    // Parse JSONB params into HashMap
    let params_json: serde_json::Value = serde_json::from_str(&params.0.to_string())
        .map_err(|e| format!("Failed to parse variables: {}", e))?;
    
    let mut param_map = std::collections::HashMap::new();
    if let Some(obj) = params_json.as_object() {
        for (key, value) in obj {
            // Validate variable key is a safe identifier
            if !key.chars().all(|c| c.is_alphanumeric() || c == '_') {
                return Err(format!("Invalid variable name: '{}'. Only alphanumeric and underscore allowed.", key));
            }
            
            let value_str = match value {
                serde_json::Value::String(s) => s.clone(),
                serde_json::Value::Number(n) => n.to_string(),
                serde_json::Value::Bool(b) => b.to_string(),
                _ => return Err(format!("Unsupported variable value type for key '{}'", key)),
            };
            param_map.insert(key.clone(), value_str);
        }
    } else {
        return Err("Variables must be a JSON object".to_string());
    }
    
    // Substitute variables to get rendered DSL
    // Note: substitute() validates that all required params are present,
    // no extra params exist, and all variable values are safe (via validate_variable_value)
    let rendered_dsl = tmpl.substitute(&param_map)?;
    
    // Start the workflow using the rendered DSL
    // This will parse the DSL and create the function graph
    let instance_id = crate::dsl::start(&rendered_dsl, label)?;
    
    // Update instance with template_id for audit trail
    let update_query = r#"
        UPDATE df.instances
        SET template_id = $1
        WHERE id = $2
    "#;
    
    Spi::run_with_args(
        update_query,
        Some(vec![
            (PgBuiltInOids::INT8OID.oid(), template_id.into_datum()),
            (PgBuiltInOids::TEXTOID.oid(), instance_id.clone().into_datum()),
        ]),
    )?
    
    Ok(instance_id)
}
```

**SQL Wrapper:**
```sql
CREATE OR REPLACE FUNCTION df.start_template(
    template_name TEXT,
    label TEXT DEFAULT NULL,
    params JSONB DEFAULT '{}'
) RETURNS TEXT AS $$
DECLARE
    instance_id TEXT;
BEGIN
    -- Call Rust implementation
    SELECT * INTO instance_id 
    FROM df.start_template_impl(template_name, label, params);
    
    RAISE NOTICE 'Started instance % from template ''%''', instance_id, template_name;
    
    RETURN instance_id;
END;
$$ LANGUAGE plpgsql;
```

### 3. `df.drop_template()` - Delete Template

**Signature:**
```sql
df.drop_template(name TEXT) RETURNS TEXT
```

**Implementation (Rust):**

```rust
#[pg_extern(schema = "df")]
fn drop_template(name: &str) -> Result<String, String> {
    // Check if template exists
    let exists_query = "SELECT 1 FROM df.templates WHERE name = $1";
    let exists: bool = Spi::get_one_with_args(
        exists_query,
        vec![(PgBuiltInOids::TEXTOID.oid(), name.into_datum())],
    )
    .unwrap_or(None)
    .is_some();
    
    if !exists {
        return Err(format!("Template '{}' does not exist", name));
    }
    
    // Delete template
    let delete_query = "DELETE FROM df.templates WHERE name = $1";
    Spi::run_with_args(
        delete_query,
        Some(vec![(PgBuiltInOids::TEXTOID.oid(), name.into_datum())]),
    )?;
    
    Ok(format!("Template '{}' dropped successfully", name))
}
```

### 4. `df.get_template()` - View Template Definition

**Signature:**
```sql
df.get_template(name TEXT) RETURNS JSONB
```

**Implementation:**
```sql
CREATE OR REPLACE FUNCTION df.get_template(template_name TEXT)
RETURNS JSONB AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'name', name,
        'dsl_template', dsl_template,
        'created_at', created_at,
        'created_by', created_by,
        'description', description
    ) INTO result
    FROM df.templates
    WHERE name = template_name;
    
    IF result IS NULL THEN
        RAISE EXCEPTION 'Template ''%'' not found', template_name;
    END IF;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;
```

### 5. `df.list_templates()` - List Templates

**Signature:**
```sql
df.list_templates(
    name_filter TEXT DEFAULT NULL,
    created_by_filter TEXT DEFAULT NULL
) RETURNS TABLE(
    name TEXT,
    description TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ
)
```

**Implementation:**
```sql
CREATE OR REPLACE FUNCTION df.list_templates(
    name_filter TEXT DEFAULT NULL,
    created_by_filter TEXT DEFAULT NULL
)
RETURNS TABLE(
    name TEXT,
    description TEXT,
    created_by TEXT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.name,
        t.description,
        t.created_by,
        t.created_at
    FROM df.templates t
    WHERE 
        (name_filter IS NULL OR t.name LIKE name_filter)
        AND (created_by_filter IS NULL OR t.created_by = created_by_filter)
    ORDER BY t.created_at DESC;
END;
$$ LANGUAGE plpgsql;
```

### 6. `df.explain_template()` - Explain Template

**Signature:**
```sql
df.explain_template(template_name TEXT) RETURNS TEXT
```

**Implementation (Rust):**

```rust
#[pg_extern(schema = "df")]
fn explain_template(template_name: &str) -> Result<String, String> {
    // Load active template (vars are ignored; placeholders remain)
    let load_query = format!(
        "SELECT dsl_template \
         FROM df.templates \
         WHERE name = '{}' AND active = true",
        template_name.replace('\'', "''")
    );

    let dsl_template: Option<String> = Spi::connect(|client| {
        let table = client.select(&load_query, None, &[]).ok()?;

        for row in table {
            if let Ok(Some(dsl_template)) = row.get::<String>(1) {
                return Some(dsl_template);
            }
        }
        None
    });

    let dsl_template =
        dsl_template.ok_or_else(|| format!("Active template '{}' not found", template_name))?;

    // Call df.explain on the DSL (variables are shown as {placeholders})
    Ok(explain::explain(&dsl_template))
}
```

**SQL Wrapper:**
```sql
CREATE OR REPLACE FUNCTION df.explain_template(
    template_name TEXT
) RETURNS TEXT AS $$
DECLARE
    result TEXT;
BEGIN
    SELECT * INTO result FROM df.explain_template_impl(template_name, params);
    RETURN result;
END;
$$ LANGUAGE plpgsql;
```

---

## Security Considerations

### SQL Injection Prevention

1. **Strict variable validation**: All variable values validated against regex patterns
2. **No dynamic SQL in substitution**: Variables replace placeholders in static DSL, not executed directly
3. **Whitelist approach**: Only allow alphanumeric, underscore, and dot characters for identifiers
4. **Dangerous pattern detection**: Block common SQL injection patterns (comments, semicolons, etc.)

### Access Control

Future enhancement (not in v1):
```sql
-- Template permissions table
CREATE TABLE df.template_permissions (
    template_name TEXT REFERENCES df.templates(name) ON DELETE CASCADE,
    role_name TEXT NOT NULL,
    can_instantiate BOOLEAN DEFAULT true,
    can_modify BOOLEAN DEFAULT false,
    can_drop BOOLEAN DEFAULT false,
    PRIMARY KEY (template_name, role_name)
);
```

### Audit Logging

Template usage is automatically tracked via the `template_id` foreign key column in `df.instances`:

```sql
-- Find all instances from a specific template
SELECT i.id, i.status, i.created_at, t.name as template_name, t.created_by as template_author
FROM df.instances i
JOIN df.templates t ON i.template_id = t.id
WHERE t.name = 'etl_template';

-- Audit: track who's using which templates
SELECT 
    t.name as template,
    t.created_by as template_author,
    COUNT(*) as instance_count
FROM df.instances i
JOIN df.templates t ON i.template_id = t.id
GROUP BY t.name, t.created_by;
```

---

## Error Handling

### Registration Errors

| Error Case | Error Message |
|-----------|---------------|
| Empty template name | "Template name cannot be empty" |
| Template already exists | "Template 'X' already exists. Use df.update_template() to modify it or df.drop_template() to deactivate it." |
| Invalid variable placeholder format | "Invalid variable placeholder format '{X}': placeholders must be alphanumeric groups separated by single underscore or period" |
| Invalid DSL syntax | "Invalid DSL syntax: <error details>" (optional/future: validation at registration time) |

### Instantiation Errors

| Error Case | Error Message |
|-----------|---------------|
| Template not found | "Template 'X' not found" |
| Missing variable | "Missing required variable: X" |
| Extra variable | "Unknown variable: X" |
| Invalid variable value | "Variable value contains invalid characters: X" |
| Invalid DSL syntax | "Failed to parse DSL: <error details>" |
| DSL execution error | "Failed to start workflow: <error>" |

### Deletion Errors

| Error Case | Error Message |
|-----------|---------------|
| Template not found | "Template 'X' does not exist" |

---

## Testing Strategy

### Unit Tests (Rust)

```rust
Unit tests cover template registration and start/explain behavior (omitted for brevity).
```

### E2E Tests (SQL)

Create test file: `tests/e2e/sql/15_templates.sql`

```sql
-- Test 1: Template registration
SELECT df.create_template(
    'test_template',
    'SELECT COUNT(*) FROM {schema_name}.users',
    'Test template for counting users by schema'
);

-- Verify registration
SELECT name FROM df.templates WHERE name = 'test_template';

-- Test 2: Template instantiation
CREATE TEMP TABLE test_users (id INT, name TEXT);
INSERT INTO test_users VALUES (1, 'Alice'), (2, 'Bob');

CREATE TEMP TABLE _test_state (instance_id TEXT);
INSERT INTO _test_state SELECT df.start_template(
    'test_template',
    'test-label',
    jsonb_build_object('schema_name', 'pg_temp')
);

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
END $$;

-- Test 3: Duplicate registration should fail
DO $$
BEGIN
    PERFORM df.create_template('test_template', 'SELECT {x}', 'Duplicate');
    RAISE EXCEPTION 'Should have failed on duplicate template';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%already exists%' THEN
            RAISE;
        END IF;
END $$;

-- Test 4: Missing variable should fail
DO $$
BEGIN
    PERFORM df.start_template('test_template', NULL, '{}'::jsonb);
    RAISE EXCEPTION 'Should have failed on missing variable';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%Missing required variable%' THEN
            RAISE;
        END IF;
END $$;

-- Test 5: Drop template
SELECT df.drop_template('test_template');

-- Verify deletion
SELECT CASE
    WHEN NOT EXISTS(SELECT 1 FROM df.templates WHERE name = 'test_template')
    THEN 'Template dropped successfully'
    ELSE 'TEST FAILED: Template still exists'
END;

-- Test 6: Complex template with multiple operators
SELECT df.create_template(
    'parallel_counts',
    'SELECT COUNT(*) as users FROM {schema_name}.test_users'
    & 'SELECT 1 as dummy'
    ~> 'SELECT ''done'' as result'
);

INSERT INTO _test_state SELECT df.start_template(
    'parallel_counts',
    'parallel-test',
    jsonb_build_object('schema_name', 'pg_temp')
);

-- Poll for completion
DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: status = %', status;
    END IF;
END $$;

-- Cleanup
SELECT df.drop_template('parallel_counts');
DROP TABLE _test_state;
DROP TABLE test_users;

SELECT 'TEST PASSED' AS result;
```

### Integration Tests

Test template instantiation with all DSL operators:
- Sequential (`~>`)
- Parallel (`&`)
- Race (`|`)
- Conditional (`?> / !>`)
- Named results (`|=>`)
- Loops (`df.loop`)
- HTTP calls (`df.http`)

---

## Performance Considerations

### Template Storage

- Templates stored as text in PostgreSQL table (no external dependencies)
- Indexed by name for O(1) lookup
- Small footprint (typically < 1KB per template)
- Human-readable and portable (can version control, export, share)

### Instantiation Overhead

- Variable substitution is string replacement: O(n) where n = DSL length
- Validation is regex-based: O(m) where m = number of variables
- DSL parsing happens at instantiation (same as `df.start()` with literal DSL)
- Total overhead: negligible compared to workflow execution time
- **Late binding**: DSL parsing at instantiation means templates benefit from DSL improvements automatically

### Caching (Future Enhancement)

Consider an in-memory cache for frequently used templates (stored as DSL text) if lookup latency becomes a bottleneck.

---

## Future Enhancements

### Template Versioning

```sql
ALTER TABLE df.templates ADD COLUMN version INT DEFAULT 1;
ALTER TABLE df.templates DROP CONSTRAINT templates_pkey;
ALTER TABLE df.templates ADD PRIMARY KEY (name, version);
```

### Template Sharing/Export

```sql
-- Export template as JSON
CREATE FUNCTION df.export_template(name TEXT) RETURNS JSONB;

-- Import template from JSON
CREATE FUNCTION df.import_template(template JSONB) RETURNS TEXT;
```

### Template Categories/Tags

```sql
ALTER TABLE df.templates ADD COLUMN tags TEXT[];
CREATE INDEX idx_templates_tags ON df.templates USING GIN(tags);
```

### Variable Defaults

```sql
ALTER TABLE df.templates ADD COLUMN variable_defaults JSONB;

-- Example:
-- variable_defaults: {"batch_size": "100", "timeout": "30"}
```

### Template Analytics

```sql
CREATE TABLE df.template_usage (
    template_name TEXT,
    instance_id TEXT,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    status TEXT,
    execution_time_ms BIGINT
);

-- Track most-used templates, success rates, avg execution time
```

---

## Example: Full Lifecycle

**Register template:**

```sql
SELECT df.create_template(
    'etl_template',
    ARRAY['source_table', 'target_table', 'batch_size'],
    $$'SELECT * FROM {source_table} LIMIT {batch_size}::int' |=> 'batch'
    ~> 'INSERT INTO {target_table} SELECT * FROM ($batch) AS source'$$
);
```

**Start a workflow from the template:**

```sql
SELECT df.start_template(
    'etl_template',
    'my-etl-job',
    '{"source_table": "raw_orders", "target_table": "processed_orders", "batch_size": "100"}'::jsonb
);
```

**Alternative using jsonb_build_object:**

```sql
SELECT df.start_template(
    'etl_template',
    'my-etl-job',
    jsonb_build_object(
        'source_table', 'raw_orders',
        'target_table', 'processed_orders',
        'batch_size', '100'
    )
);
```

**Explain what the template will do:**

```sql
SELECT df.explain_template('etl_template');
```

**List all templates:**

```sql
-- All templates
SELECT * FROM df.list_templates();

-- Filter by name pattern
SELECT * FROM df.list_templates(name_filter := '%etl%');

-- Filter by creator
SELECT * FROM df.list_templates(created_by_filter := 'alice');
```

**Get template details:**

```sql
SELECT df.get_template('etl_template');
```

**Drop template when no longer needed:**

```sql
SELECT df.drop_template('etl_template');
```

---

## Open Questions

1. **Variable type hints**: Should we support typed variables (e.g., `schema_name::identifier`, `count::int`)?
   - **Decision**: Not in v1. Keep it simple with string substitution and validation.

2. **Nested placeholders**: Should `{{param}}` be different from `{param}`?
   - **Decision**: Single curly braces only for v1.

3. **Placeholder escaping**: How to include literal `{text}` in template?
   - **Decision**: Use double braces `{{` and `}}` to escape (future enhancement).

4. **Template visibility**: Should templates be per-user or global?
   - **Decision**: Global by default, with `created_by` tracking for auditing.

5. **Template namespace**: Should template names support schema qualification (`schema.template_name`)?
   - **Decision**: Not in v1. All templates in `df` schema.

---

## References

- [spec-templates.md](spec-templates.md) - Original feature specification
- [USER_GUIDE.md](../USER_GUIDE.md) - User documentation
- [src/dsl.rs](../src/dsl.rs) - DSL implementation
- [src/types.rs](../src/types.rs) - Core types

---

## Change Log

| Date | Version | Change |
|------|---------|--------|
| 2026-01-25 | 0.1.0 | Initial draft |
| 2026-01-26 | 0.2.0 | Updated to use JSONB variables (matching spec); added filters to list_templates; updated return columns |
___BEGIN___COMMAND_DONE_MARKER___0
