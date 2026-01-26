# Function Template Proposal: pg_durable

## Overview

This proposal introduces **Function Templates** to pg_durable, enabling users to register variableizable, reusable workflows using the same SQL-native DSL syntax as `df.start`. It also extends `df.start` itself with an optional `local_vars JSONB` argument so callers can supply per-instance variables (beyond those stored in `df.vars`) in a unified way. Templates can then be instantiated later by supplying required variables, promoting maintainability, DRY principles, and safer reuse for complex orchestration scenarios.

---

## Background: Existing Variable & Templating Model

Before this spec, pg_durable already supported a basic variable and templating model:

- `df.setvar(name, value)` stores global variables in the `df.vars` table.
- When `df.start(fut, ...)` is called, the current contents of `df.vars` are captured and frozen for that instance. Later changes to `df.vars` do not affect the running workflow.
- The DSL passed to `df.start` (and other `df.*` DSL helpers) can contain `{variable_name}` placeholders, which are resolved using that captured snapshot during orchestration.

Reusing DSL strings as templates was possible but awkward. Users typically either:

- Copied DSL expressions into each call site manually, or
- Stored DSL text in their own tables and wrote custom PL/pgSQL wrappers that used dynamic SQL to evaluate the stored expression (similar in spirit to how `df.explain_expression` evaluates a text expression via SPI).

There was no first-class notion of a template stored in pg_durable itself, no built-in variable metadata, and no direct link from instances back to a reusable definition.

---

## Template Registration Syntax

A new UDF `df.create_template` is used to register templates.

### Syntax

```sql
SELECT df.create_template(
    'template_name',                   -- Unique template identifier
    $$...workflow DSL with {param}...$$,  -- DSL with placeholders (as string literal)
    'Optional description'             -- Optional: human-readable description
);
```

**Important:** The DSL must be provided as a **string literal** using dollar quoting (`$$`) or escaped quotes, similar to `df.explain()`. The operators are not executed during template registration—they remain as text to be parsed during instantiation.

**Example:** Variableize the schema name for parallel counts.

```sql
SELECT df.create_template(
    'user_order_counts',
    $$'SELECT COUNT(*) as user_count FROM {schema_name}.users'
    & 'SELECT COUNT(*) as order_count FROM {schema_name}.orders'
    ~> 'INSERT INTO {schema_name}.logs (msg) VALUES (''Parallel counts complete'')'$$,
    'Count users and orders in parallel for a given schema'
);
```

**Notes:**
- Placeholders are indicated by `{variable_name}` for clarity and SQL-compatibility.
- Placeholder format: alphanumeric groups separated by single underscore or period (e.g., `{schema_name}`, `{table.column}`).
- The `description` variable is optional but recommended for documenting template purpose and usage.
- `df.create_template` will fail if an active template with the same name already exists. Use `df.update_template` to modify existing templates.
- The DSL is stored as text and parsed at instantiation time, similar to how `df.explain()` works.
- Templates support versioning: updating a template creates a new version while preserving the old one.

---

## Template Instantiation Syntax

Once registered, templates are instantiated with a new UDF `df.start_template`, supplying variable values and an optional label.

### Syntax

```sql
SELECT df.start_template(
    'template_name',           -- Name of registered template
    'instance_label',          -- Optional workflow label
    '{"param1": "value1", "param2": "value2"}'::jsonb  -- Variables as JSONB
);
```

**Example:**

```sql
SELECT df.start_template(
    'user_order_counts',
    'parallel-counts',
    '{"schema_name": "playground"}'::jsonb
);
```

**Note:** You can also use `jsonb_build_object()` for more ergonomic variable construction:

```sql
SELECT df.start_template(
    'user_order_counts',
    'parallel-counts',
    jsonb_build_object('schema_name', 'playground')
);
```

**Behavior:**
- Variable substitution replaces all `{param}` placeholders in the template DSL.
- The fully rendered DSL is then executed using the normal pg_durable function graph logic.
 - Internally, `params` is treated as the per-instance `local_vars` map: a snapshot of `df.vars` is captured as global variables, `params` is parsed as local variables, and the two maps are merged with local values overriding globals on key conflicts. The merged map drives `{placeholder}` substitution and is passed to the orchestrator, sharing the same unified variable model as `df.start(fut, label, local_vars)`.

---

## Template Deletion Syntax

Templates can be marked as inactive using `df.drop_template`.

### Syntax

```sql
SELECT df.drop_template('template_name');
```

**Example:**

```sql
SELECT df.drop_template('user_order_counts');
```

**Behavior:**
- Marks the active template as inactive (soft delete).
- The template row is preserved in the database for audit and historical purposes.
- Does **not** affect any currently running or completed instances that were started from this template.
- Returns an error if no active template with the given name exists.
- Template name must be provided as a non-null string.

**Safety Considerations:**
- Inactive templates cannot be instantiated but remain in the database.
- Consider the impact on any automated systems or scheduled jobs that rely on the template.
- Templates can be recreated with the same name after being dropped.

---

## Template Update Syntax

Templates can be updated using `df.update_template`.

### Syntax

```sql
SELECT df.update_template(
    'template_name',
    dsl_template := $$...new DSL...$$,  -- Optional: new DSL (creates new version)
    description := 'New description'     -- Optional: new description
);
```

**Examples:**

**Update DSL (creates new version):**
```sql
SELECT df.update_template(
    'user_order_counts',
    dsl_template := $$'SELECT COUNT(*) as user_count FROM {schema_name}.users'
    & 'SELECT COUNT(*) as order_count FROM {schema_name}.orders'
    & 'SELECT COUNT(*) as product_count FROM {schema_name}.products'
    ~> 'INSERT INTO {schema_name}.logs (msg) VALUES (''Parallel counts complete'')'$$
);
```

**Update description only (in-place update):**
```sql
SELECT df.update_template(
    'user_order_counts',
    description := 'Updated: Count users, orders, and products in parallel'
);
```

**Update both (creates new version with new description):**
```sql
SELECT df.update_template(
    'user_order_counts',
    dsl_template := $$...new DSL...$$,
    description := 'New description for new version'
);
```

**Behavior:**
- If `dsl_template` is provided: marks the old version inactive and creates a new active version with the new DSL.
- If `dsl_template` is provided without a new description: the old description (if any) is preserved in the new version.
- If only `description` is provided: updates the description in place without creating a new version.
- At least one variable (`dsl_template` or `description`) must be provided.
- Returns an error if no active template with the given name exists.

---

## Template Inspection

### View Template Definition

Retrieve the stored DSL and metadata for a template using `df.get_template`.

#### Syntax

```sql
SELECT df.get_template('template_name');
```

**Example:**

```sql
SELECT df.get_template('user_order_counts');
```

**Returns:** A JSON object containing the template definition:
```json
{
  "name": "user_order_counts",
  "dsl_template": "'SELECT COUNT(*) as user_count FROM {schema_name}.users' & ...",
  "created_at": "2026-01-26T10:30:00Z",
  "created_by": "alice",
  "description": null
}
```

### List All Templates

Retrieve a list of registered templates with optional filtering using `df.list_templates`.

#### Syntax

```sql
SELECT * FROM df.list_templates(
    name_filter := NULL,       -- Optional: pattern match on template name (e.g., '%user%')
    created_by_filter := NULL  -- Optional: exact match on created_by user
);
```

**Examples:**

```sql
-- List all templates
SELECT * FROM df.list_templates();

-- Find templates with 'etl' in the name
SELECT * FROM df.list_templates(name_filter := '%etl%');

-- Find templates created by a specific user
SELECT * FROM df.list_templates(created_by_filter := 'alice');

-- Combine both filters
SELECT * FROM df.list_templates(
    name_filter := '%order%',
    created_by_filter := 'bob'
);
```

**Returns:** A table with columns:
- `name` (TEXT): Template name
- `description` (TEXT): Template description (NULL if not provided)
- `created_by` (TEXT): User who created the template
- `created_at` (TIMESTAMPTZ): When the template was created

**Behavior:**
- Returns all templates if no filters are provided.
- `name_filter` supports SQL LIKE pattern matching (use `%` wildcards for simple substring searches).
- `created_by_filter` performs exact string matching.
- Both filters can be combined (AND logic).
- Results are ordered by creation time (newest first).

---

### Explain Template Execution Plan

Visualize what a template would do with specific variables using `df.explain_template`.

#### Syntax

```sql
SELECT df.explain_template('template_name');
```

**Behavior:**
- Loads the template
- Calls `df.explain()` on the stored DSL (placeholders remain visible)
- Returns the execution plan without creating an instance

**Returns:** A text explanation of the workflow, showing the graph structure with substituted values.

---

## Audit & Reporting

Instances started from templates keep a direct reference to the template version that created them:

- `df.instances.template_id` is a foreign key to `df.templates(id)` (NULL for non-template instances).
- The reference is preserved even if the template is later updated or marked inactive, since updates create new template rows instead of overwriting existing ones.

This enables straightforward auditing and reporting using standard SQL, without any additional helper functions:

```sql
-- Find all instances created from a specific template name
SELECT i.id,
       i.status,
       i.created_at,
       t.name       AS template_name,
       t.created_by AS template_author
FROM df.instances i
JOIN df.templates t ON i.template_id = t.id
WHERE t.name = 'etl_template';

-- Aggregate usage by template and author
SELECT t.name       AS template,
       t.created_by AS template_author,
       COUNT(*)     AS instance_count
FROM df.instances i
JOIN df.templates t ON i.template_id = t.id
GROUP BY t.name, t.created_by
ORDER BY instance_count DESC;
```

Because `template_id` points at a specific version row in `df.templates`, historical instances continue to reference the template definition that was active at the time they were started.

---

## Variableization Rules & Validation

- **Automatic variable extraction**: Not performed at registration time; templates store DSL text as-is.
- **Placeholder syntax**: Use `{param}`. Curly braces are SQL-friendly and distinctive. Placeholders must be alphanumeric groups separated by single underscore or period.
- **Value validation**: Substitution happens during orchestration using the supplied vars; registration does not validate variable values.
- **Missing/Extra variables**: Registration does not enforce required/extra vars; substitution occurs at execution time.
- **JSONB variables**: Variables are passed as JSONB objects for flexible key-value mapping, consistent with PostgreSQL best practices.

---

## Template Support in Operators and Functions

Templates may use all of pg_durable's workflow operators and helper functions (`~>`, `&`, `df.join()`, etc.), including nested expressions and variable substitution. Variableization applies to SQL identifiers and literal values only.

**Example using `df.join`:**

```sql
SELECT df.create_template(
    'user_order_counts_func',
    $$df.join('SELECT COUNT(*) as user_count FROM {schema_name}.users', 'SELECT COUNT(*) as order_count FROM {schema_name}.orders') ~> 'INSERT INTO {schema_name}.logs (msg) VALUES (''Done'')'$$
);
```

---

## Error Handling & Safety

- **Registration**:
    - Error if an active template with the same name already exists.
    - Basic validation of template structure (non-empty name, valid DSL).
    - Placeholder format validation: must be alphanumeric groups separated by single underscore or period.
    - DSL syntax is not fully validated at registration—validation happens at instantiation.
- **Update**:
    - Error if no active template with the given name exists.
    - Error if neither dsl_template nor description is provided.
    - When updating DSL: old version is marked inactive, new version is created.
    - When updating only description: in-place update without versioning.
- **Instantiation**:
    - Error if no active template with the given name exists.
    - Error if missing or extra variables.
    - Variable values must match strict identifier or literal regex.
    - All substitutions are performed before DSL parsing.
    - DSL syntax errors are caught during parsing at instantiation time.
- **Deletion**:
    - Error if no active template with the given name exists.
    - Template is marked inactive (soft delete), not removed from database.

---

## Migration & Compatibility

- Existing callers of `df.start(fut, label)` remain valid and keep their behavior. The new optional `local_vars JSONB` parameter extends `df.start` but is backwards compatible: instances that do not pass `local_vars` continue to rely solely on the captured snapshot of `df.vars`.
- Templates use the same DSL syntax as `df.start` and `df.explain`—no new language to learn.
- Template DSL is stored as text (like `df.explain` input) and parsed at instantiation time.
- Use `df.get_template()` to view template definition and `df.explain_template()` to preview execution.

---

## Example: Full Lifecycle

**Register template:**

```sql
SELECT df.create_template(
    'etl_template',
    $$'SELECT * FROM {source_table} LIMIT {batch_size}::int' |=> 'batch'
    ~> 'INSERT INTO {target_table} SELECT * FROM ($batch) AS source'$$,
    'ETL template for batch processing'
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

**Update template DSL:**

```sql
SELECT df.update_template(
    'etl_template',
    dsl_template := $$'SELECT * FROM {source_table} LIMIT {batch_size}::int' |=> 'batch'
    ~> 'INSERT INTO {target_table} SELECT * FROM ($batch) AS source'
    ~> 'UPDATE {status_table} SET processed = true WHERE id = {batch_id}'$$
);
```

**Update template description:**

```sql
SELECT df.update_template(
    'etl_template',
    description := 'ETL template with status tracking'
);
```

**Drop template:**

```sql
SELECT df.drop_template('etl_template');
```

---

## Summary

- **pg_durable** gains SQL-native templates using `{param}` placeholders with automatic variable extraction.
- **Safe, ergonomic, and familiar user experience.**
- **Template versioning** preserves history while allowing updates.
- **Promotes DRY workflows and easier migration of imperative logic into reusable orchestration.**

---
