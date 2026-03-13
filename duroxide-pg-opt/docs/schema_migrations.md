# Schema Migrations

This document explains how duroxide-pg-opt handles PostgreSQL schema migrations, ensuring safe upgrades without data loss.

## Overview

duroxide-pg-opt uses an **automatic migration system** that applies schema changes on provider startup. This eliminates the need for manual `DROP SCHEMA CASCADE` operations when upgrading versions.

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     PostgresProvider::new()                              │
│                                                                         │
│   1. Connect to PostgreSQL                                              │
│   2. Create schema if not exists (for non-public schemas)               │
│   3. Load migrations from embedded migrations/ directory                │
│   4. Check _duroxide_migrations table for applied versions              │
│   5. Apply pending migrations in order                                  │
│   6. Record each applied migration                                      │
│                                                                         │
│   Result: Schema is always up-to-date with library version              │
└─────────────────────────────────────────────────────────────────────────┘
```

### Migration Tracking Table

Each schema maintains its own migration history:

```sql
CREATE TABLE {schema}._duroxide_migrations (
    version BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

### Migration File Structure

Migrations are stored in the `migrations/` directory and embedded at compile time:

```
migrations/
├── 0001_initial_schema.sql           # Complete baseline schema
├── 0002_add_deletion_and_pruning.sql # Delta migration
├── 0002_diff.md                      # Documents changes from 0001
└── README.md                         # Developer guide
```

## Upgrade Path

### Automatic Upgrades (Recommended)

When you update duroxide-pg-opt to a new version:

1. The new version includes updated migration files
2. On first startup, `PostgresProvider::new()` detects pending migrations
3. Migrations are applied automatically in a transaction
4. Your existing data (orchestrations, history, queues) is preserved

```rust
// Just create the provider - migrations are automatic
let provider = PostgresProvider::new("postgres://...").await?;
// Schema is now up-to-date!
```

### What Gets Migrated

Delta migrations (0002+) can:
- Add new columns: `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
- Add new indexes: `CREATE INDEX IF NOT EXISTS`
- Add/update stored procedures: `CREATE OR REPLACE FUNCTION`
- Add new tables: `CREATE TABLE IF NOT EXISTS`

### What's Preserved

Migrations are designed to preserve:
- ✅ Running orchestrations
- ✅ Pending work items in queues
- ✅ Complete event history
- ✅ Instance metadata and locks

## Safety Guarantees

### Idempotent Migrations

All migrations use idempotent SQL patterns:

```sql
-- Safe to run multiple times
CREATE TABLE IF NOT EXISTS instances (...);
ALTER TABLE instances ADD COLUMN IF NOT EXISTS parent_instance_id TEXT;
CREATE INDEX IF NOT EXISTS idx_instances_parent ON instances(parent_instance_id);
```

### Transactional Application

Each migration runs in a transaction:
- If any statement fails, the entire migration is rolled back
- The migration tracking table is only updated on success
- Partial migrations cannot occur

### Version Ordering

Migrations are applied in strict version order:
- `0001` must complete before `0002` starts
- Gaps in version numbers are not allowed
- Each version is applied exactly once

## Checking Migration Status

### Via SQL

```sql
-- Check applied migrations in a schema
SELECT version, name, applied_at 
FROM my_schema._duroxide_migrations 
ORDER BY version;
```

### Via Logs

Enable debug logging to see migration activity:

```
RUST_LOG=duroxide_pg_opt=debug cargo run
```

Output:
```
DEBUG Loaded 2 migrations for schema my_schema
DEBUG Applied migrations: [1]
DEBUG Applying migration 2: 0002_add_deletion_and_pruning.sql
INFO Applied migration 2: 0002_add_deletion_and_pruning.sql
```

## Troubleshooting

### "function does not exist" Error

**Cause:** Library version is newer than database schema.

**Solution:** This should auto-resolve on restart. If not:
```sql
-- Check current migration state
SELECT * FROM your_schema._duroxide_migrations;
```

### "column does not exist" Error

**Cause:** Same as above - schema is behind library version.

**Solution:** Ensure the provider is initialized properly. Migrations run in `PostgresProvider::new()`.

### Manual Reset (Data Loss!)

If you need to completely reset the schema (losing all data):

```sql
DROP SCHEMA your_schema CASCADE;
```

On next provider startup, the schema will be recreated from scratch.

## Writing New Migrations

See [migrations/README.md](../migrations/README.md) for detailed guidelines on:
- Migration file naming conventions
- SQL patterns for safe schema changes
- Testing migrations
- Creating companion diff documentation

### Key Rules

1. **Never modify 0001_initial_schema.sql** - It's the baseline for existing deployments
2. **Use delta migrations** (0002+) for all schema changes
3. **Make operations idempotent** - Use `IF NOT EXISTS`, `IF EXISTS`
4. **Create a diff.md file** - Document what changed from the previous version
5. **Test on existing data** - Ensure migrations preserve state

## Version Compatibility

| duroxide-pg-opt | Schema Version | Notes |
|-----------------|----------------|-------|
| 0.1.7+ | 2 | Added parent_instance_id, deletion/pruning procedures |
| 0.1.0-0.1.6 | 1 | Initial schema |

## Related Documentation

- [migrations/README.md](../migrations/README.md) - Developer guide for writing migrations
- [migrations/0002_diff.md](../migrations/0002_diff.md) - Example diff documentation
