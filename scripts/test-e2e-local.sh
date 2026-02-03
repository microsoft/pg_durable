#!/bin/bash
# test-e2e-local.sh - Run E2E tests locally using pgrx PostgreSQL
#
# Usage: ./scripts/test-e2e-local.sh [options] [test_filter] [repeat_count]
#
# Options:
#   --keep            Leave PostgreSQL running after tests for investigation
#   --clean           Start with fresh database (wipes all data)
#   --verbose         Show all NOTICE messages and full error output
#   -v                Same as --verbose
#   --pg-version VER  PostgreSQL major version to use (default: 17)
#   --no-preload      Start PostgreSQL WITHOUT shared_preload_libraries=pg_durable
#                     (runs only 00_requires_shared_preload test)
#
# Examples:
#   ./scripts/test-e2e-local.sh                         # Run all tests, stop server after
#   ./scripts/test-e2e-local.sh --keep                  # Run all tests, keep server running
#   ./scripts/test-e2e-local.sh --verbose               # Run all tests with NOTICE messages
#   ./scripts/test-e2e-local.sh 04_parallel             # Run matching test
#   ./scripts/test-e2e-local.sh 04_parallel 5           # Run 5 times
#   ./scripts/test-e2e-local.sh --keep 04_parallel      # Run test, keep server
#   ./scripts/test-e2e-local.sh -v 27_database_guc      # Run test with verbose output
#   ./scripts/test-e2e-local.sh --pg-version 18         # Run all tests against PG18
#   ./scripts/test-e2e-local.sh --no-preload            # Test shared_preload_libraries enforcement

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/tests/e2e/sql"

# Defaults
KEEP_RUNNING=false
CLEAN_START=false
VERBOSE=false
NO_PRELOAD=false
TEST_FILTER=""
REPEAT_COUNT=1
PG_VERSION="17"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_RUNNING=true
            shift
            ;;
        --clean)
            CLEAN_START=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --pg-version)
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --pg-version requires a numeric argument, got: $2"
                exit 1
            fi
            PG_VERSION="$2"
            shift 2
            ;;
        --no-preload)
            NO_PRELOAD=true
            shift
            ;;
        *)
            if [ -z "$TEST_FILTER" ]; then
                TEST_FILTER="$1"
            else
                REPEAT_COUNT="$1"
            fi
            shift
            ;;
    esac
done

# pgrx settings
PGRX_HOME="$HOME/.pgrx"
PG_PORT="$((28800 + PG_VERSION))"
PG_USER="postgres"
PG_DB="postgres"

# Default non-privileged role for E2E tests (created by 00_setup_playground.sql)
E2E_USER="df_e2e_user"

# Find pgrx binaries
PGRX_BIN=$(ls -d $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin 2>/dev/null | head -1)
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

# Test that requires --no-preload mode (no shared_preload_libraries)
NO_PRELOAD_TEST="00_requires_shared_preload"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "================================================"
echo "pg_durable E2E Tests (Local)"
echo -e "PostgreSQL: ${CYAN}PG${PG_VERSION}${NC} (port ${PG_PORT})"
if [ -n "$TEST_FILTER" ]; then
    echo -e "Filter: ${CYAN}$TEST_FILTER${NC}"
fi
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo -e "Repeat: ${CYAN}$REPEAT_COUNT times${NC}"
fi
if [ "$KEEP_RUNNING" = true ]; then
    echo -e "Mode: ${YELLOW}Keep server running after tests${NC}"
fi
if [ "$VERBOSE" = true ]; then
    echo -e "Mode: ${YELLOW}Verbose output (show NOTICE messages)${NC}"
fi
if [ "$NO_PRELOAD" = true ]; then
    echo -e "Mode: ${YELLOW}No-preload (testing shared_preload_libraries enforcement)${NC}"
fi
echo "================================================"
echo ""

# Function to stop server
stop_server() {
    if "$PG_ISREADY" -h localhost -p $PG_PORT -U postgres &>/dev/null; then
        echo -e "${YELLOW}Stopping PostgreSQL...${NC}"
        "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
    fi
}

# Function to ensure shared_preload_libraries is configured
ensure_config() {
    if [ -d "$DATA_DIR" ]; then
        # Check if shared_preload_libraries is correctly set
        if ! grep -q "^shared_preload_libraries.*pg_durable" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            echo "Configuring shared_preload_libraries..."
            # Remove any existing shared_preload_libraries lines (commented or not)
            sed -i.bak '/^#*shared_preload_libraries/d' "$DATA_DIR/postgresql.conf"
            echo "shared_preload_libraries = 'pg_durable'" >> "$DATA_DIR/postgresql.conf"
        fi
        # Ensure worker_role is set
        if ! grep -q "^pg_durable.worker_role" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            echo "Configuring pg_durable.worker_role..."
            echo "pg_durable.worker_role = 'postgres'" >> "$DATA_DIR/postgresql.conf"
        fi
        # Ensure database is set to 'postgres' (pg_regress may have changed it to contrib_regression)
        if ! grep -q "^pg_durable.database = 'postgres'" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            echo "Configuring pg_durable.database..."
            sed -i.bak '/^#*pg_durable.database/d' "$DATA_DIR/postgresql.conf"
            echo "pg_durable.database = 'postgres'" >> "$DATA_DIR/postgresql.conf"
        fi
        # Ensure port is set
        if ! grep -q "^port = $PG_PORT" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            sed -i.bak '/^#*port = /d' "$DATA_DIR/postgresql.conf"
            echo "port = $PG_PORT" >> "$DATA_DIR/postgresql.conf"
        fi
    fi
}

# Function to configure PostgreSQL WITHOUT shared_preload_libraries (for --no-preload mode)
ensure_config_no_preload() {
    if [ -d "$DATA_DIR" ]; then
        # Remove shared_preload_libraries so pg_durable is NOT preloaded
        sed -i.bak '/^#*shared_preload_libraries/d' "$DATA_DIR/postgresql.conf"
        # Ensure port is set
        if ! grep -q "^port = $PG_PORT" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            sed -i.bak '/^#*port = /d' "$DATA_DIR/postgresql.conf"
            echo "port = $PG_PORT" >> "$DATA_DIR/postgresql.conf"
        fi
    fi
}

# Function to start server
start_server() {
    # Clean start if requested
    if [ "$CLEAN_START" = true ] && [ -d "$DATA_DIR" ]; then
        stop_server
        echo "Removing old data directory..."
        rm -rf "$DATA_DIR"
    fi
    
    # Build and install extension first (before starting server)
    echo "Building and installing extension..."
    cd "$PROJECT_DIR"
    cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1
    
    # Initialize if needed
    if [ ! -d "$DATA_DIR" ]; then
        echo "Initializing database..."
        "$PGRX_BIN/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
    fi
    
    # Ensure config is correct (with or without preload)
    if [ "$NO_PRELOAD" = true ]; then
        ensure_config_no_preload
    else
        ensure_config
    fi
    
    # If server is running, we need to:
    # 1. Drop extension + duroxide schema (to clear any stale schema from previous duroxide-pg-opt version)
    # 2. Restart server (so background worker reconnects with fresh cached plans)
    if "$PG_ISREADY" -h localhost -p $PG_PORT -U postgres &>/dev/null; then
        # Drop extension (CASCADE also drops the owned duroxide schema)
        "$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
        echo -e "${YELLOW}Restarting PostgreSQL to reload extension...${NC}"
        stop_server
    fi
    
    # Start server
    echo -e "${YELLOW}Starting PostgreSQL...${NC}"
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    sleep 2
    
    if [ "$NO_PRELOAD" = true ]; then
        # Drop extension if it exists from a previous run (e.g., unit tests)
        # so the no-preload test can verify CREATE EXTENSION fails correctly
        "$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
    else
        # Always drop and recreate extension to ensure PL/pgSQL functions from extension_sql!
        # are up to date. Without this, a cached data directory (e.g. from CI) may have stale
        # PL/pgSQL operator functions even though the Rust .so is updated by cargo pgrx install.
        "$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
        "$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1
    fi
}

# Cleanup on exit (unless --keep)
cleanup() {
    if [ "$KEEP_RUNNING" = false ]; then
        stop_server
    else
        echo ""
        echo -e "${GREEN}PostgreSQL left running on port $PG_PORT${NC}"
        echo "Connect: $PSQL -h localhost -p $PG_PORT -d $PG_DB"
        echo "Logs:    tail -f $LOG_FILE"
        echo "Stop:    ./scripts/pg-stop.sh"
    fi
}
trap cleanup EXIT

# Start server
start_server

# Show version and run setup (only when extension is loaded, not in --no-preload mode)
if [ "$NO_PRELOAD" = false ]; then
    echo -n "pg_durable version: "
    "$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -t -c "SELECT df.version();" 2>/dev/null | tr -d ' \n'
    echo ""
    echo ""

    # Run shared E2E setup (outside the repeat loop since it only needs to run once)
    "$PSQL" -h localhost -p $PG_PORT -U "$PG_USER" -d $PG_DB -v ON_ERROR_STOP=1 -f "$SQL_DIR/00_setup_playground.sql" >/dev/null
else
    echo ""
fi

# Run tests
TOTAL_PASSED=0
TOTAL_FAILED=0

for run in $(seq 1 $REPEAT_COUNT); do
    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo -e "${CYAN}=== Run $run of $REPEAT_COUNT ===${NC}"
    fi
    
    PASSED=0
    FAILED=0

    for test_file in "$SQL_DIR"/*.sql; do
        [ -f "$test_file" ] || continue
        
        test_name=$(basename "$test_file" .sql)
        
        # In --no-preload mode, only run the shared_preload_libraries enforcement test
        if [ "$NO_PRELOAD" = true ] && [[ "$test_name" != *"$NO_PRELOAD_TEST"* ]]; then
            continue
        fi

        # In normal mode, skip tests that have specific requirements:
        # - shared_preload_libraries enforcement test (requires server without preload)
        # - setup_playground (already run explicitly as shared setup)
        if [ "$NO_PRELOAD" = false ]; then
            if [[ "$test_name" == *"$NO_PRELOAD_TEST"* ]] || [[ "$test_name" == "00_setup_playground" ]]; then
                continue
            fi
        fi

        # Apply filter
        if [ -n "$TEST_FILTER" ] && [[ ! "$test_name" == *"$TEST_FILTER"* ]]; then
            continue
        fi
        
        echo -n "  $test_name ... "

        # Tests run as the non-privileged E2E user unless they need superuser:
        # 00_requires_shared_preload attempts create extension
        # 22 and 23 use dblink passwordless connections
        # 25 tests extension creation security
        # 26 tests superuser scenarios
        # 27 creates users and tests permissions
        # 28 drops/creates the extension
        # 29 uses dblink and creates pg_durable in a different database
        PSQL_USER="$E2E_USER"
        if [[ "$test_name" == "00_requires_shared_preload" \
           || "$test_name" == "22_cross_connection" \
           || "$test_name" == "23_transactions" \
           || "$test_name" == "25_extension_creation_security" \
           || "$test_name" == 26_superuser_* \
           || "$test_name" == "27_user_isolation" \
           || "$test_name" == "28_bgw_lifecycle" \
           || "$test_name" == "29_database_validation" ]]; then
            PSQL_USER="$PG_USER"
        fi
        
        # In verbose mode, show output as it happens
        if [ "$VERBOSE" = true ]; then
            echo ""  # Newline before verbose output
            "$PSQL" -h localhost -p $PG_PORT -U "$PSQL_USER" -d $PG_DB -v ON_ERROR_STOP=1 -v client_min_messages=notice -f "$test_file"
            exit_code=$?

            if [ $exit_code -eq 0 ]; then
                echo -e "  ${GREEN}PASS${NC}"
                PASSED=$((PASSED + 1))
            else
                echo -e "  ${RED}FAIL${NC}"
                FAILED=$((FAILED + 1))
            fi
        else
            # Non-verbose mode: capture output and show summary
            output=$("$PSQL" -h localhost -p $PG_PORT -U "$PSQL_USER" -d $PG_DB -v ON_ERROR_STOP=1 -f "$test_file" 2>&1)
            exit_code=$?
            
            if [ $exit_code -eq 0 ]; then
                if echo "$output" | grep -q "TEST PASSED"; then
                    echo -e "${GREEN}PASS${NC}"
                    PASSED=$((PASSED + 1))
                elif echo "$output" | grep -q "TEST FAILED"; then
                    echo -e "${RED}FAIL${NC}"
                    echo "$output" | grep -E "(NOTICE|ERROR|TEST FAILED)" | tail -15
                    FAILED=$((FAILED + 1))
                else
                    echo -e "${GREEN}PASS${NC}"
                    PASSED=$((PASSED + 1))
                fi
            else
                echo -e "${RED}FAIL${NC}"
                echo "$output" | grep -E "(NOTICE|ERROR)" | tail -15
                FAILED=$((FAILED + 1))
            fi
        fi
    done
    
    TOTAL_PASSED=$((TOTAL_PASSED + PASSED))
    TOTAL_FAILED=$((TOTAL_FAILED + FAILED))
    
    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo -e "  Run $run: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
        echo ""
    fi
done

echo ""
echo "================================================"
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo "Total Results ($REPEAT_COUNT runs):"
fi
echo -e "Results: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
echo "================================================"

[ $TOTAL_FAILED -eq 0 ]

