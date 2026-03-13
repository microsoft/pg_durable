# Migration System

This project uses a custom migration system for PostgreSQL schema management. Migrations are stored as SQL files in the `migrations/` directory and are automatically applied when the provider is initialized.

## Migration Files

Migrations are numbered sequentially and follow the naming pattern:
```
0001_initial_schema.sql
0002_add_feature.sql
0003_update_indexes.sql
...
```

The version number is extracted from the filename prefix (before the first underscore).

## How It Works

1. **Schema Creation**: When creating a `PostgresProvider`, if a custom schema is specified (not "public"), the schema is created automatically.

2. **Migration Execution**: The migration runner:
   - Loads all `.sql` files from the `migrations/` directory
   - Sorts them by version number
   - Checks which migrations have already been applied (tracked in `_duroxide_migrations` table)
   - Applies pending migrations in order
   - Records each applied migration

3. **Schema Isolation**: Each schema has its own migration tracking table (`{schema}._duroxide_migrations`), allowing independent migration history per schema.

## Migration Tracking

Migrations are tracked in a table called `_duroxide_migrations` located in each schema:

```sql
CREATE TABLE {schema}._duroxide_migrations (
    version BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

## Writing Migrations

When writing migrations:

1. **Use schema-relative names**: Migrations are executed with `SET LOCAL search_path`, so use unqualified table names:
   ```sql
   CREATE TABLE instances (...);
   ```
   Not:
   ```sql
   CREATE TABLE public.instances (...);
   ```

2. **Multiple statements**: Migrations can contain multiple SQL statements separated by semicolons:
   ```sql
   CREATE TABLE table1 (...);
   CREATE TABLE table2 (...);
   CREATE INDEX idx1 ON table1(...);
   ```

3. **Idempotent operations**: Use `IF NOT EXISTS` clauses to make migrations idempotent:
   ```sql
   CREATE TABLE IF NOT EXISTS instances (...);
   CREATE INDEX IF NOT EXISTS idx_instances ON instances(...);
   ```

4. **Backward compatibility**: Use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for adding columns to existing tables.

## Example Migration

```sql
-- Migration: 0002_add_timestamps.sql
-- Description: Add timestamp columns to worker_queue

ALTER TABLE worker_queue ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS idx_worker_processed ON worker_queue(processed_at);
```

## Adding a New Migration

1. Create a new file in `migrations/` with the next sequential number
2. Use a descriptive name: `0002_add_feature.sql`
3. Write idempotent SQL statements
4. Test the migration locally
5. Commit the migration file

## Testing Migrations

Migrations are automatically applied when creating a `PostgresProvider`. Each test schema gets its own migration history, so you can test migrations in isolation.

## Migration Execution Context

- Migrations run inside transactions
- Each migration is executed atomically (all-or-nothing)
- The `search_path` is set to the target schema for each migration
- Migrations run in the order specified by their version numbers

## Troubleshooting

### Migration not found
- Ensure the migrations directory exists relative to where the code is executed
- The migration runner tries multiple paths: `./migrations`, `../migrations`, and `$CARGO_MANIFEST_DIR/migrations`

### Migration already applied
- Check the `_duroxide_migrations` table in your schema
- If you need to re-run a migration, manually delete its entry from the tracking table (use with caution!)

### Schema conflicts
- Each schema maintains its own migration history
- Migrations can be applied independently to different schemas

## Migration History

| Version | Name | Description |
|---------|------|-------------|
| 0001 | initial_schema | Complete schema with all tables, indexes, and stored procedures. All timestamps are NOT NULL and provided by Rust provider via `p_now_ms` parameter (single clock source). Includes attempt_count for poison message detection. |
