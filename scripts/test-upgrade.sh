#!/bin/bash
# test-upgrade.sh - Test extension upgrade paths
#
# Validates:
#   Scenario A:  Schema produced by ALTER EXTENSION UPDATE matches fresh CREATE EXTENSION
#   Scenario B1: New .so works correctly against all previous versions' schemas
#                (same major version — customers may never run ALTER EXTENSION UPDATE)
#   Scenario B2: Data created under the previous version remains accessible after upgrade
#
# Usage: ./scripts/test-upgrade.sh [options]
#
# Options:
#   --pg-version VER  PostgreSQL major version to use (default: 17)
#   --keep            Leave PostgreSQL running after tests for investigation
#   --verbose         Show SQL output and detailed diff
#   -v                Same as --verbose
#
# Prerequisites:
#   - cargo pgrx init (PostgreSQL installed)
#   - sql/pg_durable--<first>.sql (first version install SQL for current major) exists

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PG_VERSION="17"
KEEP_RUNNING=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pg-version)
            if ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                echo "Error: --pg-version requires a numeric argument, got: ${2:-<missing>}"
                exit 1
            fi
            PG_VERSION="$2"
            shift 2
            ;;
        --keep)
            KEEP_RUNNING=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# pgrx settings
PGRX_HOME="$HOME/.pgrx"
PG_PORT="$((28800 + PG_VERSION))"

# Find pgrx binaries
PGRX_BIN=$(ls -d "$PGRX_HOME/$PG_VERSION."*/pgrx-install/bin 2>/dev/null | head -1)
if [ -z "$PGRX_BIN" ]; then
    echo "Error: pgrx PostgreSQL $PG_VERSION not installed"
    echo "Run: cargo pgrx init"
    exit 1
fi

PSQL="$PGRX_BIN/psql"
PG_CTL="$PGRX_BIN/pg_ctl"
PG_ISREADY="$PGRX_BIN/pg_isready"
PG_CONFIG="$PGRX_BIN/pg_config"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
LOG_FILE="$PGRX_HOME/$PG_VERSION.log"
EXTENSION_DIR=$("$PG_CONFIG" --sharedir)/extension

# Version detection: read current version from Cargo.toml
CURRENT_VERSION=$(grep '^version' "$PROJECT_DIR/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)

first_fixture_for_major() {
    local target_major="$1"
    local version=""

    for f in "$PROJECT_DIR"/sql/pg_durable--*.sql; do
        local fname
        fname=$(basename "$f")
        if [[ "$fname" =~ ^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)\.sql$ ]]; then
            local candidate="${BASH_REMATCH[1]}"
            local candidate_major
            candidate_major=$(echo "$candidate" | cut -d. -f1)
            if [ "$candidate_major" = "$target_major" ]; then
                version+="$candidate"$'\n'
            fi
        fi
    done

    if [ -n "$version" ]; then
        printf '%s' "$version" | sort -V | head -1
    fi
}

# Find the previous version by looking for upgrade SQL scripts
PREV_VERSION=$(for f in "$PROJECT_DIR"/sql/pg_durable--*--"${CURRENT_VERSION}".sql; do
    fname=$(basename "$f")
    if [[ "$fname" =~ ^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)--${CURRENT_VERSION//./\.}\.sql$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
done | sort -V | tail -1)

if [ -z "$PREV_VERSION" ]; then
    echo "No upgrade script found for version $CURRENT_VERSION"
    echo "Expected: sql/pg_durable--<prev>--${CURRENT_VERSION}.sql"
    exit 1
fi

FIRST_VERSION=$(first_fixture_for_major "$CURRENT_MAJOR")

if [ -z "$FIRST_VERSION" ]; then
    echo "No install SQL fixture found for major version $CURRENT_MAJOR"
    echo "Expected: sql/pg_durable--<first-version>.sql"
    exit 1
fi

# Discover all previous versions from upgrade scripts (for B1 generalized testing).
# Each upgrade script pg_durable--FROM--TO.sql tells us FROM is a previous version.
# B1 tests the current .so against ALL previous schemas, not just the immediately previous one.
ALL_PREV_VERSIONS=()
for f in "$PROJECT_DIR"/sql/pg_durable--*--*.sql; do
    fname=$(basename "$f")
    if [[ "$fname" =~ ^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)--([0-9]+\.[0-9]+\.[0-9]+)\.sql$ ]]; then
        from_ver="${BASH_REMATCH[1]}"
        from_major=$(echo "$from_ver" | cut -d. -f1)
        if [ "$from_major" = "$CURRENT_MAJOR" ]; then
            ALL_PREV_VERSIONS+=("$from_ver")
        fi
    fi
done
IFS=$'\n' ALL_PREV_VERSIONS=($(sort -V -u <<< "${ALL_PREV_VERSIONS[*]}")); unset IFS

# Test databases — must use the pg_durable.database (default: postgres)
# since the extension enforces it can only be created in that database.
# Tests run sequentially: create → snapshot → drop → next test.
PG_DB="postgres"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "================================================"
echo "pg_durable Upgrade Tests"
echo -e "PostgreSQL: ${CYAN}PG${PG_VERSION}${NC} (port ${PG_PORT})"
echo -e "First version (major ${CURRENT_MAJOR}): ${CYAN}${FIRST_VERSION}${NC}"
echo -e "Scenario A upgrade path: ${CYAN}${PREV_VERSION} → ${CURRENT_VERSION}${NC}"
if [ ${#ALL_PREV_VERSIONS[@]} -gt 0 ]; then
    echo -e "Scenario B1 compat versions: ${CYAN}${ALL_PREV_VERSIONS[*]}${NC}"
else
    echo -e "Scenario B1 compat versions: ${YELLOW}(none in major ${CURRENT_MAJOR}; B1 skipped)${NC}"
fi
echo "================================================"
echo ""

# ============================================================================
# Server lifecycle
# ============================================================================

stop_server() {
    if "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres &>/dev/null; then
        "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
    fi
}

cleanup_databases() {
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" 2>/dev/null || true
}

cleanup() {
    cleanup_databases
    if [ "$KEEP_RUNNING" = false ]; then
        stop_server
    else
        echo ""
        echo -e "${GREEN}PostgreSQL left running on port $PG_PORT${NC}"
        echo "Connect: $PSQL -h localhost -p $PG_PORT -d $PG_DB"
        echo "Stop:    ./scripts/pg-stop.sh"
    fi
}
trap cleanup EXIT

# Build and install the current version
echo -e "${YELLOW}Building and installing extension (v${CURRENT_VERSION})...${NC}"
cd "$PROJECT_DIR"
cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1

# Copy checked-in install SQL fixtures to the extension directory so older
# schemas from previous majors can be reconstructed during upgrade tests.
for fixture in "$PROJECT_DIR"/sql/pg_durable--*.sql; do
    fixture_name=$(basename "$fixture")
    if [[ "$fixture_name" =~ ^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)\.sql$ ]]; then
        cp "$fixture" "$EXTENSION_DIR/$fixture_name"
    fi
done

# Initialize data directory if needed
if [ ! -d "$DATA_DIR" ]; then
    "$PGRX_BIN/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
fi

# Configure (shared_preload_libraries required — extension enforces it in _PG_init)
if [ -f "$DATA_DIR/postgresql.conf" ]; then
    if ! grep -q "^shared_preload_libraries.*pg_durable" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        sed -i.bak '/^#*shared_preload_libraries/d' "$DATA_DIR/postgresql.conf"
        echo "shared_preload_libraries = 'pg_durable'" >> "$DATA_DIR/postgresql.conf"
    fi
    if ! grep -q "^pg_durable.worker_role = 'postgres'" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        sed -i.bak '/^#*pg_durable.worker_role/d' "$DATA_DIR/postgresql.conf"
        echo "pg_durable.worker_role = 'postgres'" >> "$DATA_DIR/postgresql.conf"
    fi
    if ! grep -q "^pg_durable.database = 'postgres'" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        sed -i.bak '/^#*pg_durable.database/d' "$DATA_DIR/postgresql.conf"
        echo "pg_durable.database = 'postgres'" >> "$DATA_DIR/postgresql.conf"
    fi
    if ! grep -q "^port = $PG_PORT$" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        sed -i.bak '/^#*port = /d' "$DATA_DIR/postgresql.conf"
        echo "port = $PG_PORT" >> "$DATA_DIR/postgresql.conf"
    fi
fi

# If the server is already running, restart it so both the freshly installed
# shared_preload library binary and any config updates take effect.
if "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres &>/dev/null; then
    echo -e "${YELLOW}Restarting PostgreSQL to reload extension and config...${NC}"
    stop_server
fi

echo -e "${YELLOW}Starting PostgreSQL...${NC}"
"$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
sleep 2

# Clean up any leftover test databases
cleanup_databases

PASSED=0
FAILED=0
TESTS_RUN=0

run_test() {
    local test_name="$1"
    local test_func="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "  $test_name ... "
    if eval "$test_func"; then
        echo -e "${GREEN}PASSED${NC}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAILED${NC}"
        FAILED=$((FAILED + 1))
    fi
}

# ============================================================================
# Helpers
# ============================================================================

run_sql_capture() {
    local sql="$1"
    local result

    result=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>&1) || {
        echo ""
        echo "    SQL failed: $sql"
        echo "    Error: $result" | sed 's/^/    /'
        return 1
    }

    printf '%s' "$result"
}

assert_sql_equals() {
    local sql="$1"
    local expected="$2"
    local result

    result=$(run_sql_capture "$sql") || return 1
    if [ "$result" != "$expected" ]; then
        echo ""
        echo "    SQL: $sql"
        echo "    Expected: $expected"
        echo "    Got: $result"
        return 1
    fi
}

assert_sql_contains() {
    local sql="$1"
    local expected_fragment="$2"
    local result

    result=$(run_sql_capture "$sql") || return 1
    if [[ "$result" != *"$expected_fragment"* ]]; then
        echo ""
        echo "    SQL: $sql"
        echo "    Expected fragment: $expected_fragment"
        echo "    Got: $result"
        return 1
    fi
}

assert_sql_empty() {
    local sql="$1"
    local result

    result=$(run_sql_capture "$sql") || return 1
    if [ -n "$result" ]; then
        echo ""
        echo "    SQL: $sql"
        echo "    Expected no rows"
        echo "    Got: $result"
        return 1
    fi
}

setup_b1_tables() {
    run_sql_capture "DROP TABLE IF EXISTS test_upgrade_b1_log; CREATE TABLE test_upgrade_b1_log (id SERIAL PRIMARY KEY, msg TEXT);" >/dev/null
}

setup_b2_tables() {
    run_sql_capture "DROP TABLE IF EXISTS test_upgrade_b2_log; CREATE TABLE test_upgrade_b2_log (id SERIAL PRIMARY KEY, kind TEXT, msg TEXT);" >/dev/null
}

# Polls duroxide._worker_ready until the BGW has initialized the duroxide
# schema. Must be called after CREATE EXTENSION before any df.start() calls.
#
# For v0.2.0+ the BGW writes a row to duroxide._worker_ready after ApplyAll
# completes. For schemas that predate that table (v0.1.1 and earlier), falls
# back to polling df._worker_epoch — the BGW writes that sentinel only after
# PostgresProvider::new_with_config() completes.
wait_for_ready() {
    local attempts=0
    local has_worker_ready
    has_worker_ready=$(run_sql_capture "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'duroxide' AND table_name = '_worker_ready')") || true

    while [ $attempts -lt 60 ]; do
        if [ "$has_worker_ready" = "t" ]; then
            result=$(run_sql_capture "SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1)") || return 1
        else
            # Old schemas (pre-0.2.0) don't have duroxide._worker_ready.
            # The BGW writes a row to df._worker_epoch after ApplyAll
            # completes, so a non-empty _worker_epoch means migrations
            # are done.
            result=$(run_sql_capture "SELECT EXISTS(SELECT 1 FROM df._worker_epoch)") || return 1
        fi
        [ "$result" = "t" ] && return 0
        sleep 0.5
        attempts=$((attempts + 1))
    done
    echo ""
    echo "    Timed out waiting for duroxide._worker_ready after 30s"
    return 1
}

# Creates the extension at a specific version by installing from that major's
# first checked-in fixture and chaining ALTER EXTENSION UPDATE if needed.
create_extension_at_version() {
    local target_version="$1"
    local target_major
    local base_version

    target_major=$(echo "$target_version" | cut -d. -f1)
    base_version=$(first_fixture_for_major "$target_major")

    if [ -z "$base_version" ]; then
        echo "No install SQL fixture found for major version $target_major"
        echo "Expected: sql/pg_durable--<first-version>.sql"
        return 1
    fi

    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION pg_durable VERSION '${base_version}';" >/dev/null 2>&1
    if [ "$target_version" != "$base_version" ]; then
        "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
            -v ON_ERROR_STOP=1 \
            -c "ALTER EXTENSION pg_durable UPDATE TO '${target_version}';" >/dev/null 2>&1
    fi
}

# ============================================================================
# Schema snapshot query
# ============================================================================

# Captures the df schema structure in a deterministic, comparable format
SCHEMA_QUERY="
-- Tables and columns
SELECT 'column' AS obj_type,
       c.table_name,
       c.column_name,
       c.data_type,
       c.column_default,
       c.is_nullable,
       c.ordinal_position::text
FROM information_schema.columns c
WHERE c.table_schema = 'df'
ORDER BY c.table_name, c.ordinal_position;

-- Types (excluding implicit row types for tables)
SELECT 'type' AS obj_type,
             t.typname AS type_name,
             CASE t.typtype
                     WHEN 'd' THEN 'domain'
                     WHEN 'e' THEN 'enum'
                     WHEN 'r' THEN 'range'
                     WHEN 'c' THEN 'composite'
                     ELSE t.typtype::text
             END AS type_kind,
             COALESCE(pg_catalog.format_type(t.typbasetype, t.typtypmod), '') AS base_type,
             COALESCE(string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder), '') AS labels,
             '' AS extra1,
             '' AS extra2
FROM pg_type t
JOIN pg_namespace n ON t.typnamespace = n.oid
LEFT JOIN pg_enum e ON e.enumtypid = t.oid
WHERE n.nspname = 'df'
    AND t.typtype IN ('c', 'd', 'e', 'r')
    AND NOT EXISTS (
            SELECT 1
            FROM pg_class c
            WHERE c.reltype = t.oid
    )
GROUP BY t.typname, t.typtype, t.typbasetype, t.typtypmod
ORDER BY t.typname;

-- Constraints
SELECT 'constraint' AS obj_type,
       tc.table_name,
       tc.constraint_name,
       tc.constraint_type,
       string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS columns,
       '' AS extra1,
       '' AS extra2
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
  AND tc.table_schema = kcu.table_schema
WHERE tc.table_schema = 'df'
GROUP BY tc.table_name, tc.constraint_name, tc.constraint_type
ORDER BY tc.table_name, tc.constraint_name;

-- RLS policies
SELECT 'policy' AS obj_type,
       p.tablename AS table_name,
       p.policyname AS policy_name,
       p.cmd AS command,
       p.qual AS using_expr,
       p.with_check AS check_expr,
       p.permissive
FROM pg_policies p
WHERE p.schemaname = 'df'
ORDER BY p.tablename, p.policyname;

-- RLS enabled status
SELECT 'rls_enabled' AS obj_type,
       c.relname AS table_name,
       CASE WHEN c.relrowsecurity THEN 'enabled' ELSE 'disabled' END AS status,
       '' AS col3,
       '' AS col4,
       '' AS col5,
       '' AS col6
FROM pg_class c
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE n.nspname = 'df' AND c.relkind = 'r'
ORDER BY c.relname;

-- Indexes
SELECT 'index' AS obj_type,
       tab.relname AS table_name,
       idx.relname AS index_name,
       pg_get_indexdef(i.indexrelid) AS index_def,
       CASE WHEN i.indisunique THEN 'unique' ELSE 'nonunique' END AS uniqueness,
       '' AS extra1,
       '' AS extra2
FROM pg_index i
JOIN pg_class idx ON idx.oid = i.indexrelid
JOIN pg_class tab ON tab.oid = i.indrelid
JOIN pg_namespace n ON tab.relnamespace = n.oid
WHERE n.nspname = 'df'
ORDER BY tab.relname, idx.relname;

-- Table grants
SELECT 'grant_table' AS obj_type,
       g.table_name,
       g.grantee,
       g.privilege_type,
       g.is_grantable,
       '' AS extra1,
       '' AS extra2
FROM information_schema.role_table_grants g
WHERE g.table_schema = 'df'
ORDER BY g.table_name, g.grantee, g.privilege_type;

-- Routine grants
SELECT 'grant_routine' AS obj_type,
       p.proname AS routine_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
       a.privilege_type,
       CASE WHEN a.is_grantable THEN 'YES' ELSE 'NO' END AS is_grantable,
       grantor.rolname AS grantor
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
LEFT JOIN pg_roles grantee ON grantee.oid = a.grantee
JOIN pg_roles grantor ON grantor.oid = a.grantor
WHERE n.nspname = 'df'
ORDER BY p.proname,
         pg_get_function_identity_arguments(p.oid),
         CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
         a.privilege_type,
         grantor.rolname;

-- Schema grants
SELECT 'grant_schema' AS obj_type,
       n.nspname AS schema_name,
    CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END AS grantee,
       a.privilege_type,
       CASE WHEN a.is_grantable THEN 'YES' ELSE 'NO' END AS is_grantable,
       grantor.rolname AS grantor,
       '' AS extra2
FROM pg_namespace n
CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a
LEFT JOIN pg_roles grantee ON grantee.oid = a.grantee
JOIN pg_roles grantor ON grantor.oid = a.grantor
WHERE n.nspname = 'df'
ORDER BY grantee.rolname, a.privilege_type, grantor.rolname;

-- Functions (name and argument types — not the body, which may differ due to OID references)
SELECT 'function' AS obj_type,
       p.proname AS func_name,
       pg_get_function_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS return_type,
       '' AS extra1,
       '' AS extra2,
       '' AS extra3
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'df'
ORDER BY p.proname, pg_get_function_arguments(p.oid);
"

snapshot_schema() {
    local outfile="$1"
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -t -A -F '|' -c "$SCHEMA_QUERY" > "$outfile" 2>/dev/null
}

# ============================================================================
# Scenario A: Schema upgrade correctness
# ============================================================================

echo ""
echo -e "${CYAN}Scenario A: Schema Upgrade Correctness${NC}"
echo "  Testing: CREATE EXTENSION VERSION '$PREV_VERSION' + ALTER EXTENSION UPDATE = fresh CREATE EXTENSION"
echo ""

test_schema_upgrade() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Step 1: Upgrade path — create at previous version, upgrade to current
    create_extension_at_version "$PREV_VERSION"
    if ! "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "ALTER EXTENSION pg_durable UPDATE TO '${CURRENT_VERSION}';" >/dev/null 2>&1; then
        echo ""
        echo -e "    ${RED}ALTER EXTENSION UPDATE failed${NC}"
        rm -rf "$tmpdir"
        return 1
    fi
    snapshot_schema "$tmpdir/upgraded.txt"

    # Step 2: Fresh install at current version
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1
    snapshot_schema "$tmpdir/fresh.txt"

    # Clean up
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1

    # Compare
    if diff -u "$tmpdir/fresh.txt" "$tmpdir/upgraded.txt" > "$tmpdir/diff.txt" 2>&1; then
        rm -rf "$tmpdir"
        return 0
    else
        echo ""
        echo -e "    ${RED}Schema mismatch between fresh install and upgrade:${NC}"
        # Show a concise diff
        head -40 "$tmpdir/diff.txt" | sed 's/^/    /'
        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "    Full diff:"
            cat "$tmpdir/diff.txt" | sed 's/^/    /'
        fi
        rm -rf "$tmpdir"
        return 1
    fi
}

run_test "Schema comparison (upgrade vs fresh install)" test_schema_upgrade

# ============================================================================
# Scenario B1: Binary backward compatibility
# ============================================================================

# --- B1 test functions ---

B1_INSTANCE_ID=""

test_b1_setvar() {
    assert_sql_equals "SELECT df.setvar('test_key', 'test_value');" "OK"
}

test_b1_getvar() {
    assert_sql_equals "SELECT df.getvar('test_key');" "test_value"
}

test_b1_unsetvar() {
    assert_sql_equals "SELECT df.unsetvar('test_key');" "OK" &&
    assert_sql_empty "SELECT df.getvar('test_key');"
}

test_b1_clearvars() {
    assert_sql_equals "SELECT df.setvar('clear_key', 'clear_value');" "OK" &&
    assert_sql_equals "SELECT df.clearvars();" "OK" &&
    assert_sql_empty "SELECT df.getvar('clear_key');"
}

test_b1_version() {
    assert_sql_contains "SELECT df.version();" "$CURRENT_VERSION"
}

test_b1_dsl_construction() {
    assert_sql_contains "SELECT df.sql('SELECT 1');" '"node_type":"SQL"'
}

test_b1_dsl_chain() {
    assert_sql_contains "SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2');" '"node_type":"THEN"'
}

# Verify that release_extension_owned_duroxide_objects de-registered all
# duroxide objects from the extension.  On a fresh install there are none;
# on a v0.1.1-schema upgrade the BGW must have removed them before this runs.
test_b1_no_extension_owned_duroxide_objects() {
    assert_sql_equals \
        "SELECT COUNT(*)::int = 0
           FROM (
             -- extension-owned tables in duroxide schema
             SELECT 1
               FROM pg_class c
               JOIN pg_namespace n  ON n.oid = c.relnamespace
               JOIN pg_depend d     ON d.objid = c.oid
                                   AND d.classid = 'pg_class'::regclass
                                   AND d.deptype = 'e'
               JOIN pg_extension e  ON e.oid = d.refobjid
                                   AND e.extname = 'pg_durable'
              WHERE n.nspname = 'duroxide' AND c.relkind = 'r'
             UNION ALL
             -- extension-owned indexes in duroxide schema
             SELECT 1
               FROM pg_class c
               JOIN pg_namespace n  ON n.oid = c.relnamespace
               JOIN pg_depend d     ON d.objid = c.oid
                                   AND d.classid = 'pg_class'::regclass
                                   AND d.deptype = 'e'
               JOIN pg_extension e  ON e.oid = d.refobjid
                                   AND e.extname = 'pg_durable'
              WHERE n.nspname = 'duroxide' AND c.relkind = 'i'
             UNION ALL
             -- extension-owned sequences in duroxide schema
             SELECT 1
               FROM pg_class c
               JOIN pg_namespace n  ON n.oid = c.relnamespace
               JOIN pg_depend d     ON d.objid = c.oid
                                   AND d.classid = 'pg_class'::regclass
                                   AND d.deptype = 'e'
               JOIN pg_extension e  ON e.oid = d.refobjid
                                   AND e.extname = 'pg_durable'
              WHERE n.nspname = 'duroxide' AND c.relkind = 'S'
             UNION ALL
             -- extension-owned functions in duroxide schema
             SELECT 1
               FROM pg_proc p
               JOIN pg_namespace n  ON n.oid = p.pronamespace
               JOIN pg_depend d     ON d.objid = p.oid
                                   AND d.classid = 'pg_proc'::regclass
                                   AND d.deptype = 'e'
               JOIN pg_extension e  ON e.oid = d.refobjid
                                   AND e.extname = 'pg_durable'
              WHERE n.nspname = 'duroxide'
             UNION ALL
             -- extension-owned triggers in duroxide schema
             SELECT 1
               FROM pg_trigger t
               JOIN pg_class c      ON c.oid = t.tgrelid
               JOIN pg_namespace n  ON n.oid = c.relnamespace
               JOIN pg_depend d     ON d.objid = t.oid
                                   AND d.classid = 'pg_trigger'::regclass
                                   AND d.deptype = 'e'
               JOIN pg_extension e  ON e.oid = d.refobjid
                                   AND e.extname = 'pg_durable'
              WHERE n.nspname = 'duroxide'
           ) owned;" \
        "t"
}

test_b1_start_and_complete() {
    B1_INSTANCE_ID=$(run_sql_capture "SELECT df.start('INSERT INTO test_upgrade_b1_log (msg) VALUES (''{test_key}'') RETURNING msg', 'b1-var-capture');") || return 1

    if [ -z "$B1_INSTANCE_ID" ]; then
        echo ""
        echo "    df.start() returned an empty instance id"
        return 1
    fi

    assert_sql_equals "SELECT df.wait_for_completion('${B1_INSTANCE_ID}', 30);" "completed" &&
    assert_sql_equals "SELECT msg FROM test_upgrade_b1_log ORDER BY id DESC LIMIT 1;" "test_value"
}

test_b1_status_instance() {
    assert_sql_equals "SELECT df.status('${B1_INSTANCE_ID}');" "completed"
}

test_b1_result() {
    assert_sql_contains "SELECT df.result('${B1_INSTANCE_ID}');" "test_value"
}

test_b1_status_nonexistent() {
    assert_sql_empty "SELECT df.status('nonexistent-id');"
}

test_b1_list_instances() {
    assert_sql_equals "SELECT EXISTS (SELECT 1 FROM df.list_instances() WHERE instance_id = '${B1_INSTANCE_ID}');" "t"
}

test_b1_instance_info() {
    assert_sql_equals "SELECT lower(status) FROM df.instance_info('${B1_INSTANCE_ID}');" "completed"
}

# Run B1 tests against each previous version's schema
if [ ${#ALL_PREV_VERSIONS[@]} -eq 0 ]; then
    echo ""
    echo -e "${CYAN}Scenario B1: Binary Backward Compatibility${NC}"
    echo "  No previous versions within major ${CURRENT_MAJOR}; skipping direct-contact compatibility checks"
else
    for B1_VERSION in "${ALL_PREV_VERSIONS[@]}"; do
        echo ""
        echo -e "${CYAN}Scenario B1: Binary Backward Compatibility (v${B1_VERSION} schema)${NC}"
        echo "  Testing: v${CURRENT_VERSION} .so against v${B1_VERSION} schema (no ALTER EXTENSION UPDATE)"
        echo ""

        # Reconstruct old schema: install the target major's first version, then chain upgrades to target
        create_extension_at_version "$B1_VERSION"
        setup_b1_tables
        run_test "B1 [v${B1_VERSION}]: Wait for BGW readiness" wait_for_ready
        run_test "B1 [v${B1_VERSION}]: No extension-owned duroxide objects" test_b1_no_extension_owned_duroxide_objects
        B1_INSTANCE_ID=""

        run_test "B1 [v${B1_VERSION}]: df.setvar()" test_b1_setvar
        run_test "B1 [v${B1_VERSION}]: df.getvar()" test_b1_getvar
        run_test "B1 [v${B1_VERSION}]: df.version()" test_b1_version
        run_test "B1 [v${B1_VERSION}]: df.sql() construction" test_b1_dsl_construction
        run_test "B1 [v${B1_VERSION}]: DSL chain (~>)" test_b1_dsl_chain
        run_test "B1 [v${B1_VERSION}]: df.start()/wait_for_completion()" test_b1_start_and_complete
        run_test "B1 [v${B1_VERSION}]: df.status() on real instance" test_b1_status_instance
        run_test "B1 [v${B1_VERSION}]: df.result()" test_b1_result
        run_test "B1 [v${B1_VERSION}]: df.list_instances()" test_b1_list_instances
        run_test "B1 [v${B1_VERSION}]: df.instance_info()" test_b1_instance_info
        run_test "B1 [v${B1_VERSION}]: df.status() on nonexistent" test_b1_status_nonexistent
        run_test "B1 [v${B1_VERSION}]: df.unsetvar()" test_b1_unsetvar
        run_test "B1 [v${B1_VERSION}]: df.clearvars()" test_b1_clearvars
    done
fi

# ============================================================================
# Scenario B2: Data compatibility after upgrade
# ============================================================================

echo ""
echo -e "${CYAN}Scenario B2: Data Compatibility After Upgrade${NC}"
echo "  Testing: data created under v${PREV_VERSION} remains accessible after ALTER EXTENSION UPDATE"
echo ""

B2_PRE_INSTANCE_ID=""
B2_INFLIGHT_INSTANCE_ID=""
B2_POST_INSTANCE_ID=""

test_b2_data_survives_upgrade() {
    # Step 1: Install previous version and create test data
    create_extension_at_version "$PREV_VERSION"
    setup_b2_tables || return 1
    wait_for_ready || return 1

    assert_sql_equals "SELECT df.clearvars();" "OK" || return 1
    assert_sql_equals "SELECT df.setvar('b2_key', 'b2_value');" "OK" || return 1

    B2_PRE_INSTANCE_ID=$(run_sql_capture "SELECT df.start('INSERT INTO test_upgrade_b2_log (kind, msg) VALUES (''pre'', ''{b2_key}'') RETURNING msg', 'b2-pre-upgrade');") || return 1
    B2_INFLIGHT_INSTANCE_ID=$(run_sql_capture "SELECT df.start(df.sleep(2) ~> 'SELECT ''b2-running'' AS value', 'b2-inflight');") || return 1

    assert_sql_equals "SELECT df.wait_for_completion('${B2_PRE_INSTANCE_ID}', 30);" "completed" || return 1

    # Step 2: Upgrade
    if ! "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "ALTER EXTENSION pg_durable UPDATE TO '${CURRENT_VERSION}';" >/dev/null 2>&1; then
        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "    ALTER EXTENSION UPDATE failed"
        fi
        return 1
    fi

    # Step 3: Verify pre-upgrade data is still accessible under the new schema
    assert_sql_equals "SELECT df.getvar('b2_key');" "b2_value" &&
    assert_sql_equals "SELECT owner::text FROM df.vars WHERE name = 'b2_key';" "postgres" &&
    assert_sql_equals "SELECT msg FROM test_upgrade_b2_log WHERE kind = 'pre' ORDER BY id DESC LIMIT 1;" "b2_value"
}

test_b2_pre_upgrade_instance_after_upgrade() {
    assert_sql_equals "SELECT df.status('${B2_PRE_INSTANCE_ID}');" "completed" &&
    assert_sql_contains "SELECT df.result('${B2_PRE_INSTANCE_ID}');" "b2_value" &&
    assert_sql_equals "SELECT lower(status) FROM df.instance_info('${B2_PRE_INSTANCE_ID}');" "completed" &&
    assert_sql_equals "SELECT EXISTS (SELECT 1 FROM df.list_instances() WHERE instance_id = '${B2_PRE_INSTANCE_ID}');" "t"
}

test_b2_inflight_work_after_upgrade() {
    assert_sql_equals "SELECT df.wait_for_completion('${B2_INFLIGHT_INSTANCE_ID}', 30);" "completed" &&
    assert_sql_contains "SELECT df.result('${B2_INFLIGHT_INSTANCE_ID}');" "b2-running"
}

test_b2_new_data_after_upgrade() {
    assert_sql_equals "SELECT df.setvar('b2_new_key', 'new_value');" "OK" || return 1
    assert_sql_equals "SELECT df.getvar('b2_new_key');" "new_value" || return 1

    B2_POST_INSTANCE_ID=$(run_sql_capture "SELECT df.start('INSERT INTO test_upgrade_b2_log (kind, msg) VALUES (''post'', ''{b2_new_key}'') RETURNING msg', 'b2-post-upgrade');") || return 1

    assert_sql_equals "SELECT df.wait_for_completion('${B2_POST_INSTANCE_ID}', 30);" "completed" &&
    assert_sql_equals "SELECT msg FROM test_upgrade_b2_log WHERE kind = 'post' ORDER BY id DESC LIMIT 1;" "new_value"
}

run_test "B2: Pre-upgrade data survives ALTER EXTENSION UPDATE" test_b2_data_survives_upgrade
run_test "B2: Pre-upgrade instance remains queryable" test_b2_pre_upgrade_instance_after_upgrade
run_test "B2: In-flight work completes after upgrade" test_b2_inflight_work_after_upgrade
run_test "B2: New data and execution after upgrade" test_b2_new_data_after_upgrade

# ============================================================================
# Results
# ============================================================================

echo ""
echo "================================================"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}UPGRADE TESTS: $PASSED passed, $FAILED failed (of $TESTS_RUN)${NC}"
    echo "================================================"
    echo ""
    echo "Tip: run with --verbose for detailed output, --keep to investigate"
    exit 1
else
    echo -e "${GREEN}UPGRADE TESTS: All $PASSED tests passed${NC}"
    echo "================================================"
fi
