#!/bin/bash
# test-e2e-local.sh - Run E2E tests locally using pgrx PostgreSQL
#
# Usage: ./scripts/test-e2e-local.sh [options] [test_filter] [repeat_count]
#
# Options:
#   --keep       Leave PostgreSQL running after tests for investigation
#   --clean      Start with fresh database (wipes all data)
#
# Examples:
#   ./scripts/test-e2e-local.sh                    # Run all tests, stop server after
#   ./scripts/test-e2e-local.sh --keep             # Run all tests, keep server running
#   ./scripts/test-e2e-local.sh 04_parallel        # Run matching test
#   ./scripts/test-e2e-local.sh 04_parallel 5      # Run 5 times
#   ./scripts/test-e2e-local.sh --keep 04_parallel # Run test, keep server

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/tests/e2e/sql"

# Defaults
KEEP_RUNNING=false
CLEAN_START=false
TEST_FILTER=""
REPEAT_COUNT=1

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
PG_VERSION="17"
PG_PORT="28817"
PG_USER="$USER"
PG_DB="postgres"

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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "================================================"
echo "pg_durable E2E Tests (Local)"
if [ -n "$TEST_FILTER" ]; then
    echo -e "Filter: ${CYAN}$TEST_FILTER${NC}"
fi
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo -e "Repeat: ${CYAN}$REPEAT_COUNT times${NC}"
fi
if [ "$KEEP_RUNNING" = true ]; then
    echo -e "Mode: ${YELLOW}Keep server running after tests${NC}"
fi
echo "================================================"
echo ""

# Function to stop server
stop_server() {
    if "$PG_ISREADY" -h localhost -p $PG_PORT &>/dev/null; then
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
        # Ensure port is set
        if ! grep -q "^port = $PG_PORT" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            sed -i.bak '/^#*port = /d' "$DATA_DIR/postgresql.conf"
            echo "port = $PG_PORT" >> "$DATA_DIR/postgresql.conf"
        fi
    fi
}

# Function to start server
start_server() {
    if ! "$PG_ISREADY" -h localhost -p $PG_PORT &>/dev/null; then
        echo -e "${YELLOW}Starting PostgreSQL...${NC}"
        
        # Clean start if requested
        if [ "$CLEAN_START" = true ] && [ -d "$DATA_DIR" ]; then
            echo "Removing old data directory..."
            rm -rf "$DATA_DIR"
        fi
        
        # Initialize if needed
        if [ ! -d "$DATA_DIR" ]; then
            echo "Initializing database..."
            "$PGRX_BIN/initdb" -D "$DATA_DIR" --no-locale -E UTF8 >/dev/null 2>&1
        fi
        
        # Ensure config is correct (works for both new and existing data dirs)
        ensure_config
        
        # Install extension
        echo "Building and installing extension..."
        cd "$PROJECT_DIR"
        cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1
        
        # Start server
        "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
        sleep 2
        
        # Drop and recreate extension (picks up schema changes)
        "$PSQL" -h localhost -p $PG_PORT -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE; CREATE EXTENSION pg_durable;" >/dev/null 2>&1
    else
        # Server already running - check if config needs update (requires restart)
        if ! grep -q "^shared_preload_libraries.*pg_durable" "$DATA_DIR/postgresql.conf" 2>/dev/null; then
            echo -e "${YELLOW}Restarting PostgreSQL to load pg_durable worker...${NC}"
            stop_server
            ensure_config
            "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
            sleep 2
        fi
        # Reinstall extension
        cd "$PROJECT_DIR"
        cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1
        "$PSQL" -h localhost -p $PG_PORT -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE; CREATE EXTENSION pg_durable;" >/dev/null 2>&1
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

# Show version
echo -n "pg_durable version: "
"$PSQL" -h localhost -p $PG_PORT -d $PG_DB -t -c "SELECT df.version();" 2>/dev/null | tr -d ' \n'
echo ""
echo ""

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
        
        # Apply filter
        if [ -n "$TEST_FILTER" ] && [[ ! "$test_name" == *"$TEST_FILTER"* ]]; then
            continue
        fi
        
        echo -n "  $test_name ... "
        
        output=$("$PSQL" -h localhost -p $PG_PORT -d $PG_DB -v ON_ERROR_STOP=1 -f "$test_file" 2>&1)
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            if echo "$output" | grep -q "TEST PASSED"; then
                echo -e "${GREEN}PASS${NC}"
                ((PASSED++))
            elif echo "$output" | grep -q "TEST FAILED"; then
                echo -e "${RED}FAIL${NC}"
                echo "$output" | grep -E "(NOTICE|ERROR|TEST FAILED)" | tail -15
                ((FAILED++))
            else
                echo -e "${GREEN}PASS${NC}"
                ((PASSED++))
            fi
        else
            echo -e "${RED}FAIL${NC}"
            echo "$output" | grep -E "(NOTICE|ERROR)" | tail -15
            ((FAILED++))
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

