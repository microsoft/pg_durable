#!/bin/bash
# test-connlimit-e2e.sh - Run connection limit E2E tests with custom GUCs
#
# These tests require Postmaster-level GUC changes (server restart).
# Runs separately from test-e2e-local.sh.
#
# Usage: ./scripts/test-connlimit-e2e.sh [--verbose] [--pg-version N]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/tests/e2e/sql"

VERBOSE=false
PG_VERSION="17"

while [[ $# -gt 0 ]]; do
    case $1 in
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
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# pgrx settings
PGRX_HOME="$HOME/.pgrx"
PG_PORT="$((28800 + PG_VERSION))"
PG_USER="postgres"
PG_DB="postgres"
E2E_USER="df_e2e_user"

# Find pgrx binaries
PGRX_BIN=$(ls -d $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin 2>/dev/null | head -1)
if [ -z "$PGRX_BIN" ]; then
    echo "Error: pgrx PostgreSQL $PG_VERSION not installed"
    exit 1
fi

PSQL="$PGRX_BIN/psql"
PG_CTL="$PGRX_BIN/pg_ctl"
PG_ISREADY="$PGRX_BIN/pg_isready"
PG_CONFIG="$PGRX_BIN/pg_config"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
LOG_FILE="$PGRX_HOME/$PG_VERSION.log"

PASSED=0
FAILED=0

stop_server() {
    if "$PG_ISREADY" -h localhost -p $PG_PORT -U postgres &>/dev/null; then
        "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
        sleep 1
    fi
}

# Set custom GUCs in postgresql.conf and restart
apply_gucs() {
    local gucs=("$@")
    # Remove any existing pg_durable.max_* and pg_durable.execution_* lines
    sed -i.bak '/^pg_durable\.max_/d; /^pg_durable\.execution_/d' "$DATA_DIR/postgresql.conf"
    for guc in "${gucs[@]}"; do
        echo "$guc" >> "$DATA_DIR/postgresql.conf"
    done
    stop_server
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    sleep 2
}

# Remove custom GUCs and restart with defaults
restore_defaults() {
    sed -i.bak '/^pg_durable\.max_/d; /^pg_durable\.execution_/d' "$DATA_DIR/postgresql.conf"
    stop_server
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    sleep 2
}

run_test() {
    local test_file="$1"
    local test_name=$(basename "$test_file" .sql)
    local psql_user="$2"

    printf "  %-45s ... " "$test_name"

    if [ "$VERBOSE" = true ]; then
        echo ""
        "$PSQL" -h localhost -p $PG_PORT -U "$psql_user" -d $PG_DB \
            -v ON_ERROR_STOP=1 -v client_min_messages=notice -f "$test_file"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            echo -e "  ${GREEN}PASS${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "  ${RED}FAIL${NC}"
            FAILED=$((FAILED + 1))
        fi
    else
        output=$("$PSQL" -h localhost -p $PG_PORT -U "$psql_user" -d $PG_DB \
            -v ON_ERROR_STOP=1 -f "$test_file" 2>&1)
        exit_code=$?
        if [ $exit_code -eq 0 ] && echo "$output" | grep -q "TEST PASSED"; then
            echo -e "${GREEN}PASS${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}FAIL${NC}"
            echo "$output" | grep -E "(NOTICE|ERROR|TEST FAILED)" | tail -15
            FAILED=$((FAILED + 1))
        fi
    fi
}

# Restore defaults on any exit (including set -e failures)
trap restore_defaults EXIT

# Ensure extension is installed and server is running
echo -e "${CYAN}=== Connection Limit E2E Tests ===${NC}"
echo ""

# Build and install
echo "Building and installing extension..."
cd "$PROJECT_DIR"
cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1

# Ensure server is running with default config first
if ! "$PG_ISREADY" -h localhost -p $PG_PORT -U postgres &>/dev/null; then
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    sleep 2
fi

# Ensure extension exists
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION IF NOT EXISTS pg_durable;" >/dev/null 2>&1

# Ensure the E2E test user exists with required privileges
# (normally created by 00_setup_playground.sql, but this script must be self-contained)
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB <<'SETUP_EOF' >/dev/null 2>&1
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user') THEN
        CREATE ROLE df_e2e_user LOGIN;
    END IF;
END $$;
GRANT USAGE ON SCHEMA public TO df_e2e_user;
GRANT CREATE ON SCHEMA public TO df_e2e_user;
GRANT ALL ON ALL TABLES IN SCHEMA public TO df_e2e_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO df_e2e_user;
SETUP_EOF

# --- Test 1: Backpressure (max_user_connections=2) ---
echo -e "\n${YELLOW}[1/3] Backpressure test (max_user_connections=2)${NC}"
apply_gucs "pg_durable.max_user_connections = 2"

# Recreate extension after restart
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1

# Wait for worker readiness (poll duroxide._worker_ready directly)
for i in $(seq 1 30); do
    ready=$("$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -t -c \
        "SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1);" 2>/dev/null | tr -d ' \n')
    [ "$ready" = "t" ] && break
    sleep 1
done

run_test "$SQL_DIR/44_connection_limit_backpressure.sql" "$E2E_USER"

# --- Test 2: Timeout (max_user_connections=1, execution_acquire_timeout=2) ---
echo -e "\n${YELLOW}[2/3] Timeout test (max_user_connections=1, timeout=2s)${NC}"
apply_gucs "pg_durable.max_user_connections = 1" "pg_durable.execution_acquire_timeout = 2"

"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1

for i in $(seq 1 30); do
    ready=$("$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -t -c \
        "SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1);" 2>/dev/null | tr -d ' \n')
    [ "$ready" = "t" ] && break
    sleep 1
done

run_test "$SQL_DIR/45_connection_limit_timeout.sql" "$E2E_USER"

# --- Test 3: Startup validation (max_duroxide_connections=1) ---
echo -e "\n${YELLOW}[3/3] Startup validation (max_duroxide_connections=1)${NC}"
apply_gucs "pg_durable.max_duroxide_connections = 1"

"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1

# Don't wait for readiness — the test verifies worker DOESN'T become ready
run_test "$SQL_DIR/46_connection_limit_startup_validation.sql" "$PG_USER"

# --- Restore defaults ---
echo -e "\n${YELLOW}Restoring default GUC values...${NC}"
restore_defaults

# Recreate extension with defaults to leave clean state
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
"$PSQL" -h localhost -p $PG_PORT -U $PG_USER -d $PG_DB -c "CREATE EXTENSION pg_durable;" >/dev/null 2>&1

echo ""
echo "================================================"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}Connection limit tests: $PASSED passed, $FAILED failed${NC}"
else
    echo -e "${RED}Connection limit tests: $PASSED passed, $FAILED failed${NC}"
fi
echo "================================================"

exit $FAILED
