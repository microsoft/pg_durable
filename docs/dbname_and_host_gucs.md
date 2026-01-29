# Design: Database and Host Configuration for pg_durable

**Status**: Implemented
**Date**: 2026-01-20

## Overview

This document describes the GUC configuration and security model for pg_durable, focusing on:
1. Database connection configuration (host/socket directory and target database)
2. OS-level peer authentication for all connections
3. Extension-based schema creation with worker-based initialization

## Goals

1. **Unix Domain Sockets**: Use Unix domain sockets exclusively for all connections to avoid network overhead and improve security
2. **Configurable Database**: Allow administrators to specify which database the background worker connects to
3. **Peer Authentication**: Use OS-level peer authentication (no custom roles needed)
4. **Clean Extension Model**: Extension creates schema structure, worker populates it
5. **Simple Security**: Rely on PostgreSQL's built-in authentication mechanisms

## Design

### 1. Configuration Parameters (GUCs)

#### 1.1. `pg_durable.host`

**Purpose**: Specify the Unix domain socket directory for PostgreSQL connections.

**Type**: String
**Context**: `postmaster` (requires server restart)
**Default**: Empty string (uses PostgreSQL's default Unix socket directory)

**Behavior**:
- If empty/not set: Use PostgreSQL's default Unix socket directory (typically `/tmp` or `/var/run/postgresql`)
- If set: Use the specified directory path

**Example**:
```sql
-- postgresql.conf
pg_durable.host = '/var/run/postgresql'
```

**Note**: Only Unix socket directories are supported - network connections are not allowed.

#### 1.2. `pg_durable.database_name`

**Purpose**: Specify the database to which the background worker connects.

**Type**: String
**Context**: `postmaster` (requires server restart)
**Default**: `"postgres"`

**Behavior**:
- Background worker connects to this database on startup
- All duroxide internal tables (`duroxide` schema) live in this database
- All `df.*` user-facing tables live in this database

**Example**:
```sql
-- postgresql.conf
pg_durable.database_name = 'myapp_db'
```

### 2. Security Model

#### 2.1. Peer Authentication

**Purpose**: Use OS-level authentication for all database connections.

**Mechanism**: Connection strings use an empty user field, triggering PostgreSQL's peer authentication which authenticates based on the OS user running the process (typically the `postgres` user).

**Privileges**:
- Worker runs as the OS user that started PostgreSQL
- No custom database roles created
- Relies on PostgreSQL's built-in security model

**Rationale**:
- Simpler security model
- No role management overhead
- Consistent with how PostgreSQL background workers typically operate
- Reduced attack surface

#### 2.2. Schema Ownership

**The `duroxide` Schema**:
- Created by `CREATE EXTENSION pg_durable` (via SQL script)
- Owner: The role that created the extension
- Contains duroxide internal tables (workflow state, history, etc.)
- Populated by background worker on first startup

**The `df` Schema**:
- Created by pgrx-generated SQL during `CREATE EXTENSION`
- Contains user-facing tables and functions
- Owner: The role that created the extension

#### 2.3. Connection Context

**Single Connection Context**:
- User: OS user (via peer authentication)
- Database: Target database (from `pg_durable.database_name` GUC)
- Used for: All operations (duroxide state management, workflow orchestration, user function execution)
- Connection string: `postgresql:///?host={host}&port={port}&dbname={database_name}`

**Note**: Empty user field in connection string triggers peer authentication.

### 3. Connection String Construction

**Single Helper Function**:

```rust
pub fn postgres_connection_string() -> String {
    let host = get_host();
    let port = get_port();
    let database = get_database_name();
    
    format!("postgresql:///?host={}&port={}&dbname={}", host, port, database)
}
```

**Format**:
```
postgresql:///?host={host}&port={port}&dbname={database_name}
```

**Parameter Sources**:
- `host`: `pg_durable.host` GUC (empty = PostgreSQL's default Unix socket dir)
- `port`: Read from `PostPortNumber` system GUC
- `dbname`: `pg_durable.database_name` GUC (default: "postgres")

**Examples**:
```rust
// With default GUCs (empty host, "postgres" database)
postgres_connection_string()
// -> "postgresql:///?host=/tmp&port=5432&dbname=postgres"

// With custom host and database
postgres_connection_string()
// -> "postgresql:///?host=/var/run/postgresql&port=5432&dbname=myapp_db"
```

**Note**: The `host` parameter with a directory path makes PostgreSQL/sqlx use Unix domain sockets. The `port` is required to identify the correct socket file (e.g., `.s.PGSQL.5432`).

### 4. Background Worker Initialization Flow

**Startup Sequence** (`duroxide_worker_main`):

```
1. Attach signal handlers
2. Initialize tracing
3. Read GUCs (pg_durable.database_name, pg_durable.host, PostPortNumber)
4. Initialize tokio runtime
5. [async] Enter wait loop:
   a. Connect to target database (peer auth)
   b. Check if pg_durable extension is created (query pg_extension)
   c. Check if duroxide schema exists
   d. If not ready: sleep 1 second, retry
   e. Max 60 retries (1 minute timeout)
   f. Once both conditions met: break wait loop
6. [async] Create sqlx connection pool (peer auth)
7. [async] Initialize duroxide runtime with PostgresProvider
   - PostgresProvider creates duroxide tables if they don't exist
   - Worker populates the duroxide schema created by extension
8. [async] Enter main loop (check for shutdown signals, execute workflows)
9. Shutdown tokio runtime
```

**Error Handling**:
- Extension not created within timeout: Log error and exit
- Schema doesn't exist: Log error and exit
- Duroxide initialization failure: Log error and exit
- PostgreSQL will automatically restart the worker

**Key Design Decision**: Extension creates empty schema, worker populates it with duroxide tables. This avoids mixing synchronous SQL with async sqlx during extension creation.

### 5. Extension Creation (`CREATE EXTENSION pg_durable`)

**Extension Creation Flow**:

```sql
-- In sql/pg_durable--0.1.0.sql (or pgrx-generated SQL)

-- 1. Verify current database matches pg_durable.database_name GUC
DO $$
DECLARE
    current_db TEXT := current_database();
    target_db TEXT;
BEGIN
    SELECT setting INTO target_db FROM pg_settings WHERE name = 'pg_durable.database_name';
    IF target_db IS DISTINCT FROM current_db THEN
        RAISE EXCEPTION 'Cannot create pg_durable extension in database %. Expected database: %. Set pg_durable.database_name or create extension in the correct database.',
            current_db, target_db;
    END IF;
END $$;

-- 2. Verify pg_durable is in shared_preload_libraries
DO $$
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM pg_settings 
        WHERE name = 'shared_preload_libraries' 
        AND setting LIKE '%pg_durable%'
    ) THEN
        RAISE EXCEPTION 'pg_durable must be loaded via shared_preload_libraries. Add to postgresql.conf and restart PostgreSQL.';
    END IF;
END $$;

-- 3. Create duroxide schema (empty - worker will populate)
CREATE SCHEMA IF NOT EXISTS duroxide;

-- 4. Create df schema and tables (pgrx-generated SQL)
-- ... rest of extension SQL ...
```

**Responsibilities**:
- Validate GUC configuration
- Create empty `duroxide` schema
- Create `df` schema with user-facing tables and functions
- Validation ensures worker will be able to connect successfully

**Worker's Responsibility**:
- Wait for extension creation
- Connect to database with duroxide schema
- Initialize duroxide-pg-opt runtime (creates duroxide tables)
- Execute durable workflows

**Rationale**:
- Extension creation is fast and synchronous
- Worker handles async initialization
- Clean separation of concerns
- DROP EXTENSION CASCADE properly removes everything

### 6. Error Cases and Diagnostics

**Common Error Scenarios**:

1. **Extension created in wrong database**:
   - Error during `CREATE EXTENSION` (validation catches this)
   - Message: "Cannot create pg_durable extension in database X. Expected database: Y"

2. **Extension created before shared_preload_libraries configured**:
   - Error during `CREATE EXTENSION` (validation catches this)
   - Message: "pg_durable must be loaded via shared_preload_libraries"

3. **Worker times out waiting for extension**:
   - Error in worker logs after 60 seconds
   - Worker exits and PostgreSQL restarts it
   - Check: Was extension created? Is database name correct?

4. **Connection failures**:
   - Check: Is socket directory accessible?
   - Check: Does OS user have permission?
   - Check: Is PostgreSQL running?

### 7. Testing Strategy

#### Unit Tests
- Test `postgres_connection_string()` with various GUC combinations
- Test GUC default values
- Test PostPortNumber reading

#### E2E Tests

**Test 1: Fresh Installation**
- Start PostgreSQL with pg_durable in shared_preload_libraries
- Verify worker starts and waits
- Create extension in correct database
- Verify worker detects extension and initializes
- Run durable function

**Test 2: Wrong Database**
- Try creating extension in database different from `pg_durable.database_name`
- Verify error message during `CREATE EXTENSION`

**Test 3: Missing shared_preload_libraries**
- Try creating extension without shared_preload_libraries
- Verify error message during `CREATE EXTENSION`

**Test 4: Custom Socket Directory**
- Set `pg_durable.host = '/custom/socket/dir'`
- Verify connections work

**Test 5: Extension Ownership**
- Create extension
- Verify duroxide schema exists
- Verify `DROP EXTENSION pg_durable CASCADE` removes duroxide schema

#### Manual Testing
- Test on fresh PostgreSQL instance
- Test with multiple databases
- Verify with `lsof` that Unix sockets are used
- Check process owner matches PostgreSQL server user

## Migration Path

### For New Installations

1. **Configure postgresql.conf**:
   ```
   shared_preload_libraries = 'pg_durable'
   pg_durable.database_name = 'postgres'  # or your database
   pg_durable.host = ''  # or custom socket directory
   ```

2. **Restart PostgreSQL**

3. **Create extension** (in target database):
   ```sql
   CREATE EXTENSION pg_durable;
   ```

4. **Verify** worker is running:
   - Check PostgreSQL logs for "pg_durable background worker initialized"
   - Run a test durable function

### For Existing Installations (from older versions)

Users upgrading from versions with `durable_worker` role will need to:

1. **Update postgresql.conf**:
   ```
   # Old GUCs (remove):
   # pg_durable.socket_dir = '...'
   # pg_durable.database = '...'
   
   # New GUCs:
   shared_preload_libraries = 'pg_durable'
   pg_durable.host = ''  # or custom path
   pg_durable.database_name = 'postgres'  # or your database
   ```

2. **Restart PostgreSQL**

3. **Drop and recreate extension** (in target database):
   ```sql
   -- Warning: This will cancel running orchestrations
   DROP EXTENSION pg_durable CASCADE;
   CREATE EXTENSION pg_durable;
   ```

4. **Optional: Remove old role** (if it exists):
   ```sql
   DROP ROLE IF EXISTS durable_worker;
   ```

## Security Considerations

1. **Principle of Least Privilege**: Worker runs as PostgreSQL's OS user with standard permissions
2. **Unix Sockets Only**: Network connections are not supported, reducing attack surface
3. **Peer Authentication**: Leverages PostgreSQL's built-in OS-level authentication
4. **Schema Isolation**: Duroxide internal tables are isolated in a dedicated schema
5. **No Custom Roles**: Simpler security model, easier to audit and maintain

## Implementation Details

### Key Files Modified

- `src/lib.rs`: GUC definitions (`pg_durable.host`, `pg_durable.database_name`)
- `src/types.rs`: Connection string helper (`postgres_connection_string()`)
- `src/worker.rs`: Worker initialization and wait loop
- `sql/pg_durable--0.1.0.sql`: Extension creation with validation (if using manual SQL)

### Constants

```rust
// src/types.rs
pub const DUROXIDE_SCHEMA: &str = "duroxide";
```

### Helper Functions

```rust
// src/types.rs
pub fn get_host() -> String;
pub fn get_port() -> u16;
pub fn get_database_name() -> String;
pub fn postgres_connection_string() -> String;
```

## Known Limitations

1. **Single Database**: Only one target database per PostgreSQL instance
2. **Unix Sockets Only**: Windows support would require additional work
3. **Extension Drop**: Running orchestrations may error during `DROP EXTENSION CASCADE`
4. **No Live Migration**: Upgrades require extension recreation (loses running workflows)

## Future Enhancements

1. **Multi-Database Support**: Allow pg_durable in multiple databases
2. **Graceful Shutdown**: Handle `DROP EXTENSION` more gracefully
3. **User Context Preservation**: Track and use the role that called `df.start()` for function execution
4. **Network Socket Support**: Optional TCP connections for remote management

## References

- PostgreSQL GUC documentation: https://www.postgresql.org/docs/current/runtime-config-custom.html
- PostgreSQL background workers: https://www.postgresql.org/docs/current/bgworker.html
- PostgreSQL peer authentication: https://www.postgresql.org/docs/current/auth-peer.html
- sqlx connection strings: https://docs.rs/sqlx/latest/sqlx/postgres/struct.PgConnectOptions.html
