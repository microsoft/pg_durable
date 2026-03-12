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

# Find the previous version by looking for upgrade SQL scripts
PREV_VERSION=$(ls "$PROJECT_DIR/sql/pg_durable--"*"--${CURRENT_VERSION}.sql" 2>/dev/null \
    | head -1 \
    | sed "s|.*/pg_durable--\(.*\)--${CURRENT_VERSION}\.sql|\1|")

if [ -z "$PREV_VERSION" ]; then
    echo "No upgrade script found for version $CURRENT_VERSION"
    echo "Expected: sql/pg_durable--<prev>--${CURRENT_VERSION}.sql"
    exit 1
fi

# First version for this major: the single install SQL fixture we keep per major version.
# Only the first version needs a standalone install SQL; intermediate versions are
# reconstructed by chaining ALTER EXTENSION UPDATE from the first version.
FIRST_VERSION=""
for f in "$PROJECT_DIR"/sql/pg_durable--*.sql; do
    fname=$(basename "$f")
    # Match pg_durable--X.Y.Z.sql but NOT pg_durable--X.Y.Z--A.B.C.sql
    if [[ "$fname" =~ ^pg_durable--([0-9]+\.[0-9]+\.[0-9]+)\.sql$ ]]; then
        ver="${BASH_REMATCH[1]}"
        ver_major=$(echo "$ver" | cut -d. -f1)
        if [ "$ver_major" = "$CURRENT_MAJOR" ]; then
            FIRST_VERSION="$ver"
            break
        fi
    fi
done

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

if [ ${#ALL_PREV_VERSIONS[@]} -eq 0 ]; then
    echo "No previous versions found in upgrade scripts for major version $CURRENT_MAJOR"
    exit 1
fi

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
echo -e "Scenario B1 compat versions: ${CYAN}${ALL_PREV_VERSIONS[*]}${NC}"
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

# Copy first version install SQL to extension directory
cp "$PROJECT_DIR/sql/pg_durable--${FIRST_VERSION}.sql" "$EXTENSION_DIR/pg_durable--${FIRST_VERSION}.sql"

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
    if ! grep -q "^pg_durable.worker_role" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        echo "pg_durable.worker_role = 'postgres'" >> "$DATA_DIR/postgresql.conf"
    fi
    if ! grep -q "^pg_durable.database" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        echo "pg_durable.database = 'postgres'" >> "$DATA_DIR/postgresql.conf"
    fi
    if ! grep -q "^port = $PG_PORT" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
        sed -i.bak '/^#*port = /d' "$DATA_DIR/postgresql.conf"
        echo "port = $PG_PORT" >> "$DATA_DIR/postgresql.conf"
    fi
fi

# Start server (if not already running)
if ! "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres &>/dev/null; then
    echo -e "${YELLOW}Starting PostgreSQL...${NC}"
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    sleep 2
fi

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

# Creates the extension at a specific version by installing at FIRST_VERSION
# and chaining ALTER EXTENSION UPDATE if needed.
create_extension_at_version() {
    local target_version="$1"
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION pg_durable VERSION '${FIRST_VERSION}';" >/dev/null 2>&1
    if [ "$target_version" != "$FIRST_VERSION" ]; then
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

# Helper to run SQL against the compat database and check for success
run_compat_sql() {
    local sql="$1"
    local result
    result=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -t -A -v ON_ERROR_STOP=1 -c "$sql" 2>&1) && return 0
    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "    SQL: $sql"
        echo "    Error: $result" | sed 's/^/    /'
    fi
    return 1
}

# --- B1 test functions ---

test_b1_setvar() {
    run_compat_sql "SELECT df.setvar('test_key', 'test_value');"
}

test_b1_getvar() {
    run_compat_sql "SELECT df.getvar('test_key');"
}

test_b1_unsetvar() {
    run_compat_sql "SELECT df.unsetvar('test_key');"
}

test_b1_clearvars() {
    run_compat_sql "SELECT df.clearvars();"
}

test_b1_version() {
    run_compat_sql "SELECT df.version();"
}

test_b1_dsl_construction() {
    # Test that DSL functions work (graph construction, no execution)
    run_compat_sql "SELECT df.sql('SELECT 1');"
}

test_b1_dsl_chain() {
    run_compat_sql "SELECT df.sql('SELECT 1') ~> df.sql('SELECT 2');"
}

test_b1_status_nonexistent() {
    # Should return empty, not error
    run_compat_sql "SELECT df.status('nonexistent-id');"
}

test_b1_list_instances() {
    run_compat_sql "SELECT * FROM df.list_instances();"
}

# Run B1 tests against each previous version's schema
for B1_VERSION in "${ALL_PREV_VERSIONS[@]}"; do
    echo ""
    echo -e "${CYAN}Scenario B1: Binary Backward Compatibility (v${B1_VERSION} schema)${NC}"
    echo "  Testing: v${CURRENT_VERSION} .so against v${B1_VERSION} schema (no ALTER EXTENSION UPDATE)"
    echo ""

    # Reconstruct old schema: install first version, then chain upgrades to target
    create_extension_at_version "$B1_VERSION"

    run_test "B1 [v${B1_VERSION}]: df.setvar()" test_b1_setvar
    run_test "B1 [v${B1_VERSION}]: df.getvar()" test_b1_getvar
    run_test "B1 [v${B1_VERSION}]: df.unsetvar()" test_b1_unsetvar
    run_test "B1 [v${B1_VERSION}]: df.clearvars()" test_b1_clearvars
    run_test "B1 [v${B1_VERSION}]: df.version()" test_b1_version
    run_test "B1 [v${B1_VERSION}]: df.sql() construction" test_b1_dsl_construction
    run_test "B1 [v${B1_VERSION}]: DSL chain (~>)" test_b1_dsl_chain
    run_test "B1 [v${B1_VERSION}]: df.status() on nonexistent" test_b1_status_nonexistent
    run_test "B1 [v${B1_VERSION}]: df.list_instances()" test_b1_list_instances
done

# ============================================================================
# Scenario B2: Data compatibility after upgrade
# ============================================================================

echo ""
echo -e "${CYAN}Scenario B2: Data Compatibility After Upgrade${NC}"
echo "  Testing: data created under v${PREV_VERSION} remains accessible after ALTER EXTENSION UPDATE"
echo ""

test_b2_data_survives_upgrade() {
    # Step 1: Install previous version and create test data
    create_extension_at_version "$PREV_VERSION"

    # Create data under old schema
    if ! run_compat_sql "SELECT df.setvar('b2_key', 'b2_value');"; then
        return 1
    fi

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

    # Step 3: Verify data is still accessible
    local val
    val=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d "$PG_DB" \
        -t -A -v ON_ERROR_STOP=1 -c "SELECT df.getvar('b2_key');" 2>&1) || return 1
    if [ "$val" != "b2_value" ]; then
        if [ "$VERBOSE" = true ]; then
            echo ""
            echo "    Expected 'b2_value', got '$val'"
        fi
        return 1
    fi
    return 0
}

test_b2_functions_work_after_upgrade() {
    # Extension already upgraded from previous test — verify functions work
    run_compat_sql "SELECT df.sql('SELECT 1');"
}

test_b2_new_data_after_upgrade() {
    # Can create new data after upgrade
    run_compat_sql "SELECT df.setvar('b2_new_key', 'new_value');" && \
    run_compat_sql "SELECT df.getvar('b2_new_key');"
}

test_b2_status_after_upgrade() {
    run_compat_sql "SELECT df.status('nonexistent-id');"
}

test_b2_list_instances_after_upgrade() {
    run_compat_sql "SELECT * FROM df.list_instances();"
}

run_test "B2: Pre-upgrade data survives ALTER EXTENSION UPDATE" test_b2_data_survives_upgrade
run_test "B2: DSL construction after upgrade" test_b2_functions_work_after_upgrade
run_test "B2: New data creation after upgrade" test_b2_new_data_after_upgrade
run_test "B2: df.status() after upgrade" test_b2_status_after_upgrade
run_test "B2: df.list_instances() after upgrade" test_b2_list_instances_after_upgrade

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
