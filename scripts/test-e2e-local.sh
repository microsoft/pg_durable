#!/bin/bash
# BEGIN_USAGE
# test-e2e-local.sh - Run local E2E tests across all required PostgreSQL modes.
#
# Usage: ./scripts/test-e2e-local.sh [options] [test_filter] [repeat_count]
#
# Options:
#   --keep                    Leave PostgreSQL running after tests for investigation
#   --clean                   Start with a fresh database cluster
#   --verbose, -v             Show NOTICE messages and full test output
#   --pg-version VER          PostgreSQL major version to use (default: 17)
#   --no-preload              Run only the shared_preload_libraries enforcement phase
#   --standard                Run only the standard preload-enabled phase
#   --connlimit-backpressure  Run only the connection limit backpressure phase
#   --connlimit-timeout       Run only the connection limit timeout phase
#   --connlimit-startup       Run only the connection limit startup-validation phase
#   --http-disabled           Run only the HTTP-disabled (no http Cargo feature) phase
#   --http-allow-all          Run only the http-allow-all Cargo feature phase
#   --help, -h                Show this help
#
# Examples:
#   ./scripts/test-e2e-local.sh
#   ./scripts/test-e2e-local.sh 04_parallel
#   ./scripts/test-e2e-local.sh 04_parallel 5
#   ./scripts/test-e2e-local.sh --keep
#   ./scripts/test-e2e-local.sh --clean --pg-version 18
#   ./scripts/test-e2e-local.sh --no-preload
#   ./scripts/test-e2e-local.sh --connlimit-backpressure --connlimit-timeout
#   ./scripts/test-e2e-local.sh --http-disabled
#   ./scripts/test-e2e-local.sh --http-allow-all
# END_USAGE

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/tests/e2e/sql"

KEEP_RUNNING=false
CLEAN_START=false
VERBOSE=false
TEST_FILTER=""
REPEAT_COUNT=1
PG_VERSION="17"
EXPLICIT_PHASES=false
SETUP_PLAYGROUND_APPLIED=false
E2E_ROLE_ENSURED=false
VERSION_SHOWN=false
CURRENT_FEATURES=""  # tracks what Cargo features the installed .so was built with

declare -a REQUESTED_PHASES=()
declare -a MATCHED_TESTS=()
declare -a ACTIVE_PHASES=()

ALL_PHASES=(
    "no-preload"
    "standard"
    "connlimit-backpressure"
    "connlimit-timeout"
    "connlimit-startup"
    "http-disabled"
    "http-allow-all"
)

PGRX_HOME="$HOME/.pgrx"
PG_USER="postgres"
PG_DB="postgres"
E2E_USER="df_e2e_user"
NO_PRELOAD_TEST="00_requires_shared_preload"
SETUP_TEST="00_setup_playground"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_usage() {
    sed -n '/^# BEGIN_USAGE/,/^# END_USAGE/{ /^# BEGIN_USAGE/d; /^# END_USAGE/d; s/^# \{0,1\}//; p }' "$0"
}

contains_value() {
    local wanted="$1"
    shift || true
    local value

    for value in "$@"; do
        if [ "$value" = "$wanted" ]; then
            return 0
        fi
    done

    return 1
}

add_requested_phase() {
    local phase="$1"

    if ! contains_value "$phase" "${ALL_PHASES[@]}"; then
        echo "Error: unsupported phase '$phase'"
        exit 1
    fi

    if ! contains_value "$phase" "${REQUESTED_PHASES[@]}"; then
        REQUESTED_PHASES+=("$phase")
    fi
}

phase_label() {
    case "$1" in
        no-preload)
            echo "shared_preload_libraries enforcement"
            ;;
        standard)
            echo "standard suite"
            ;;
        connlimit-backpressure)
            echo "connection limit backpressure"
            ;;
        connlimit-timeout)
            echo "connection limit timeout"
            ;;
        connlimit-startup)
            echo "connection limit startup validation"
            ;;
        http-disabled)
            echo "HTTP disabled (no http Cargo feature)"
            ;;
        http-allow-all)
            echo "HTTP allow-all (http-allow-all Cargo feature)"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

phase_for_test() {
    case "$1" in
        "$NO_PRELOAD_TEST")
            echo "no-preload"
            ;;
        44_connection_limit_backpressure)
            echo "connlimit-backpressure"
            ;;
        45_connection_limit_timeout)
            echo "connlimit-timeout"
            ;;
        46_connection_limit_startup_validation)
            echo "connlimit-startup"
            ;;
        47_http_dsl_disabled)
            echo "http-disabled"
            ;;
        48_http_allow_all)
            echo "http-allow-all"
            ;;
        *)
            echo "standard"
            ;;
    esac
}

test_user_for() {
    case "$1" in
        00_requires_shared_preload|22_cross_connection|23_transactions|25_extension_creation_security|26_superuser_*|27_user_isolation|28_bgw_lifecycle|29_database_validation|34_multi_database|35_heartbeat_liveness|37_rls|38_rls_vars)
            echo "$PG_USER"
            ;;
        *)
            echo "$E2E_USER"
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
            if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --pg-version requires a numeric argument"
                exit 1
            fi
            PG_VERSION="$2"
            shift 2
            ;;
        --no-preload)
            EXPLICIT_PHASES=true
            add_requested_phase "no-preload"
            shift
            ;;
        --standard)
            EXPLICIT_PHASES=true
            add_requested_phase "standard"
            shift
            ;;
        --connlimit-backpressure)
            EXPLICIT_PHASES=true
            add_requested_phase "connlimit-backpressure"
            shift
            ;;
        --connlimit-timeout)
            EXPLICIT_PHASES=true
            add_requested_phase "connlimit-timeout"
            shift
            ;;
        --connlimit-startup)
            EXPLICIT_PHASES=true
            add_requested_phase "connlimit-startup"
            shift
            ;;
        --http-disabled)
            EXPLICIT_PHASES=true
            add_requested_phase "http-disabled"
            shift
            ;;
        --http-allow-all)
            EXPLICIT_PHASES=true
            add_requested_phase "http-allow-all"
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        --*)
            echo "Error: unknown option '$1'"
            exit 1
            ;;
        *)
            if [ -z "$TEST_FILTER" ]; then
                TEST_FILTER="$1"
            elif [ "$REPEAT_COUNT" = "1" ]; then
                REPEAT_COUNT="$1"
            else
                echo "Error: unexpected argument '$1'"
                exit 1
            fi
            shift
            ;;
    esac
done

if ! [[ "$REPEAT_COUNT" =~ ^[0-9]+$ ]] || [ "$REPEAT_COUNT" -lt 1 ]; then
    echo "Error: repeat_count must be a positive integer"
    exit 1
fi

PG_PORT="$((28800 + PG_VERSION))"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
LOG_FILE="$PGRX_HOME/$PG_VERSION.log"
CONF_FILE="$DATA_DIR/postgresql.conf"

shopt -s nullglob
PGRX_CANDIDATES=("$PGRX_HOME"/"$PG_VERSION".*/pgrx-install/bin)
shopt -u nullglob
if [ "${#PGRX_CANDIDATES[@]}" -eq 0 ]; then
    echo "Error: pgrx PostgreSQL $PG_VERSION not installed"
    echo "Run: cargo pgrx init"
    exit 1
fi

PGRX_BIN="${PGRX_CANDIDATES[0]}"
PSQL="$PGRX_BIN/psql"
PG_CTL="$PGRX_BIN/pg_ctl"
PG_ISREADY="$PGRX_BIN/pg_isready"
PG_CONFIG="$PGRX_BIN/pg_config"

stop_server() {
    if [ -d "$DATA_DIR" ] && "$PG_CTL" status -D "$DATA_DIR" >/dev/null 2>&1; then
        echo -e "${YELLOW}Stopping PostgreSQL...${NC}"
        "$PG_CTL" -D "$DATA_DIR" stop -m fast >/dev/null 2>&1 || true
        sleep 1
    fi
}

cleanup() {
    if [ "$KEEP_RUNNING" = false ]; then
        stop_server
        return
    fi

    echo ""
    echo -e "${GREEN}PostgreSQL left running on port $PG_PORT${NC}"
    echo "Connect: $PSQL -h localhost -p $PG_PORT -d $PG_DB"
    echo "Logs:    tail -f $LOG_FILE"
    echo "Stop:    ./scripts/pg-stop.sh"
}

trap cleanup EXIT

remove_conf_key() {
    local key="$1"
    local escaped_key="${key//./\\.}"
    sed -i.bak "/^[#[:space:]]*${escaped_key}[[:space:]]*=/d" "$CONF_FILE"
}

set_conf_line() {
    remove_conf_key "$1"
    echo "$1 = $2" >> "$CONF_FILE"
}

clear_connlimit_gucs() {
    sed -i.bak '/^[#[:space:]]*pg_durable\.max_/d; /^[#[:space:]]*pg_durable\.execution_/d' "$CONF_FILE"
}

ensure_data_dir() {
    if [ ! -d "$DATA_DIR" ]; then
        echo "Initializing database..."
        "$PGRX_BIN/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
    fi
}

wait_for_server() {
    local attempts=0

    until "$PG_ISREADY" -h localhost -p "$PG_PORT" -U "$PG_USER" -q >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo "PostgreSQL did not become ready on port $PG_PORT"
            exit 1
        fi
        sleep 0.5
    done
}

restart_server() {
    stop_server
    echo -e "${YELLOW}Starting PostgreSQL...${NC}"
    "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    wait_for_server
}

build_extension() {
    echo "Building and installing extension..."
    cd "$PROJECT_DIR"
    cargo pgrx install --pg-config="$PG_CONFIG" --features http-allow-test-domains >/dev/null 2>&1
    CURRENT_FEATURES="http-allow-test-domains"
}

build_extension_no_http() {
    echo "Building extension (no http features)..."
    cd "$PROJECT_DIR"
    cargo pgrx install --pg-config="$PG_CONFIG" --no-default-features >/dev/null 2>&1
    CURRENT_FEATURES="none"
}

build_extension_http_allow_all() {
    echo "Building extension (http-allow-all feature)..."
    cd "$PROJECT_DIR"
    cargo pgrx install --pg-config="$PG_CONFIG" --features http-allow-all >/dev/null 2>&1
    CURRENT_FEATURES="http-allow-all"
}

show_version_once() {
    if [ "$VERSION_SHOWN" = false ]; then
        echo -n "pg_durable version: "
        "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -t -c "SELECT df.version();" 2>/dev/null | tr -d ' \n'
        echo ""
        VERSION_SHOWN=true
    fi
}

grant_e2e_df_usage() {
    "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT df.grant_usage('$E2E_USER');" >/dev/null 2>&1
}

ensure_e2e_role() {
    if [ "$E2E_ROLE_ENSURED" = false ]; then
        "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" <<'SQL' >/dev/null
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user') THEN
        CREATE ROLE df_e2e_user LOGIN;
    END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA public TO df_e2e_user;
GRANT ALL ON ALL TABLES IN SCHEMA public TO df_e2e_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO df_e2e_user;
SQL

        E2E_ROLE_ENSURED=true
    fi

    grant_e2e_df_usage
}

wait_for_worker_ready() {
    local ready="f"
    local attempts=0

    while [ "$attempts" -lt 120 ]; do
        ready=$("$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -Atqc "SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'duroxide' AND table_name = '_worker_ready') THEN EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1) ELSE FALSE END;" 2>/dev/null | tr -d ' \n' || true)
        if [ "$ready" = "t" ]; then
            return
        fi
        sleep 0.5
        attempts=$((attempts + 1))
    done

    echo "Background worker did not become ready. Check server logs."
    exit 1
}

recreate_extension() {
    # Run DROP and CREATE in one transaction so the BGW's migration runner
    # cannot race between them. The migration runner creates
    # "CREATE SCHEMA IF NOT EXISTS duroxide" independently, which would cause
    # CREATE EXTENSION to fail with "schema already exists" if there is any gap.
    "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" <<'SQL' >/dev/null 2>&1
BEGIN;
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
COMMIT;
SQL
}

configure_phase() {
    local phase="$1"

    ensure_data_dir
    set_conf_line "port" "$PG_PORT"
    clear_connlimit_gucs

    case "$phase" in
        no-preload)
            remove_conf_key "shared_preload_libraries"
            ;;
        standard)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            ;;
        connlimit-backpressure)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            set_conf_line "pg_durable.max_user_connections" "2"
            ;;
        connlimit-timeout)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            set_conf_line "pg_durable.max_user_connections" "1"
            set_conf_line "pg_durable.execution_acquire_timeout" "2"
            ;;
        connlimit-startup)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            set_conf_line "pg_durable.max_duroxide_connections" "1"
            ;;
        http-disabled)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            ;;
        http-allow-all)
            set_conf_line "shared_preload_libraries" "'pg_durable'"
            set_conf_line "pg_durable.worker_role" "'postgres'"
            set_conf_line "pg_durable.database" "'postgres'"
            ;;
    esac
}

prepare_phase() {
    local phase="$1"

    # Phases that need a different Cargo feature build must rebuild before
    # the server restarts so the new .so is already in place.
    case "$phase" in
        http-disabled)
            build_extension_no_http
            ;;
        http-allow-all)
            build_extension_http_allow_all
            ;;
        no-preload|standard|connlimit-backpressure|connlimit-timeout|connlimit-startup)
            # Rebuild if previous phase changed the Cargo features
            if [ "$CURRENT_FEATURES" != "http-allow-test-domains" ]; then
                build_extension
            fi
            ;;
    esac

    configure_phase "$phase"

    # Drop the extension (and its owned duroxide schema) *before* restarting so
    # the BGW cannot find a pre-existing pg_durable extension on the next boot
    # and race past its "waiting for CREATE EXTENSION" poll loop before
    # recreate_extension runs.  The || true makes this a no-op when the server
    # is not yet running (e.g. first phase on a clean data dir).
    "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "DROP EXTENSION IF EXISTS pg_durable CASCADE; DROP SCHEMA IF EXISTS duroxide CASCADE;" \
        >/dev/null 2>&1 || true

    restart_server

    if [ "$phase" = "no-preload" ]; then
        "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "DROP EXTENSION IF EXISTS pg_durable CASCADE;" >/dev/null 2>&1
        return
    fi

    recreate_extension
    show_version_once

    case "$phase" in
        standard)
            if [ "$SETUP_PLAYGROUND_APPLIED" = false ]; then
                "$PSQL" -h localhost -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f "$SQL_DIR/$SETUP_TEST.sql" >/dev/null
                SETUP_PLAYGROUND_APPLIED=true
                E2E_ROLE_ENSURED=true
            else
                ensure_e2e_role
                wait_for_worker_ready
            fi
            ;;
        connlimit-backpressure|connlimit-timeout)
            ensure_e2e_role
            wait_for_worker_ready
            ;;
        connlimit-startup)
            ;;
        http-disabled|http-allow-all)
            ensure_e2e_role
            wait_for_worker_ready
            ;;
    esac
}

collect_matched_tests() {
    local test_file
    local test_name

    MATCHED_TESTS=()

    for test_file in "$SQL_DIR"/*.sql; do
        [ -f "$test_file" ] || continue
        test_name=$(basename "$test_file" .sql)

        if [ "$test_name" = "$SETUP_TEST" ]; then
            continue
        fi

        if [ -n "$TEST_FILTER" ] && [[ "$test_name" != *"$TEST_FILTER"* ]]; then
            continue
        fi

        MATCHED_TESTS+=("$test_file")
    done

    if [ "${#MATCHED_TESTS[@]}" -eq 0 ]; then
        echo "Error: no E2E tests matched the current selection"
        exit 1
    fi
}

phase_has_tests() {
    local phase="$1"
    local test_file
    local test_name

    for test_file in "${MATCHED_TESTS[@]}"; do
        test_name=$(basename "$test_file" .sql)
        if [ "$(phase_for_test "$test_name")" = "$phase" ]; then
            return 0
        fi
    done

    return 1
}

select_active_phases() {
    local phase

    ACTIVE_PHASES=()

    for phase in "${ALL_PHASES[@]}"; do
        if [ "$EXPLICIT_PHASES" = true ]; then
            if contains_value "$phase" "${REQUESTED_PHASES[@]}" && phase_has_tests "$phase"; then
                ACTIVE_PHASES+=("$phase")
            fi
        else
            if phase_has_tests "$phase"; then
                ACTIVE_PHASES+=("$phase")
            fi
        fi
    done

    if [ "${#ACTIVE_PHASES[@]}" -eq 0 ]; then
        echo "Error: selected phases contain no matching tests"
        exit 1
    fi
}

print_failure_excerpt() {
    local output="$1"
    local excerpt

    excerpt=$(printf '%s\n' "$output" | grep -E "(NOTICE|ERROR|TEST FAILED)" | tail -15 || true)
    if [ -n "$excerpt" ]; then
        printf '%s\n' "$excerpt"
    else
        printf '%s\n' "$output" | tail -15
    fi
}

run_test_file() {
    local test_file="$1"
    local test_name
    local psql_user
    local output

    test_name=$(basename "$test_file" .sql)
    psql_user=$(test_user_for "$test_name")

    printf "  %-45s ... " "$test_name"

    if [ "$VERBOSE" = true ]; then
        echo ""
        if "$PSQL" -h localhost -p "$PG_PORT" -U "$psql_user" -d "$PG_DB" -v ON_ERROR_STOP=1 -v client_min_messages=notice -f "$test_file"; then
            echo -e "  ${GREEN}PASS${NC}"
            return 0
        fi

        echo -e "  ${RED}FAIL${NC}"
        return 1
    fi

    if output=$("$PSQL" -h localhost -p "$PG_PORT" -U "$psql_user" -d "$PG_DB" -v ON_ERROR_STOP=1 -f "$test_file" 2>&1); then
        if printf '%s\n' "$output" | grep -q "TEST FAILED"; then
            echo -e "${RED}FAIL${NC}"
            print_failure_excerpt "$output"
            return 1
        fi

        echo -e "${GREEN}PASS${NC}"
        return 0
    fi

    echo -e "${RED}FAIL${NC}"
    print_failure_excerpt "$output"
    return 1
}

run_phase() {
    local phase="$1"
    local phase_passed=0
    local phase_failed=0
    local test_file
    local test_name
    local phase_tests=()

    for test_file in "${MATCHED_TESTS[@]}"; do
        test_name=$(basename "$test_file" .sql)
        if [ "$(phase_for_test "$test_name")" = "$phase" ]; then
            phase_tests+=("$test_file")
        fi
    done

    if [ "${#phase_tests[@]}" -eq 0 ]; then
        return
    fi

    echo ""
    echo -e "${CYAN}=== $(phase_label "$phase") ===${NC}"
    prepare_phase "$phase"

    for test_file in "${phase_tests[@]}"; do
        if run_test_file "$test_file"; then
            phase_passed=$((phase_passed + 1))
        else
            phase_failed=$((phase_failed + 1))
        fi
    done

    TOTAL_PASSED=$((TOTAL_PASSED + phase_passed))
    TOTAL_FAILED=$((TOTAL_FAILED + phase_failed))

    echo -e "  Phase result: ${GREEN}${phase_passed} passed${NC}, ${RED}${phase_failed} failed${NC}"
}

restore_keep_running_state() {
    if [ "$KEEP_RUNNING" = true ] && [ "${#ACTIVE_PHASES[@]}" -gt 1 ]; then
        echo ""
        echo -e "${YELLOW}Restoring standard PostgreSQL state for investigation...${NC}"
        prepare_phase "standard"
    fi
}

collect_matched_tests
select_active_phases

echo "================================================"
echo "pg_durable E2E Tests (Local)"
echo -e "PostgreSQL: ${CYAN}PG${PG_VERSION}${NC} (port ${PG_PORT})"
if [ -n "$TEST_FILTER" ]; then
    echo -e "Filter: ${CYAN}$TEST_FILTER${NC}"
fi
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo -e "Repeat: ${CYAN}$REPEAT_COUNT times${NC}"
fi
echo -e "Phases: ${CYAN}${ACTIVE_PHASES[*]}${NC}"
if [ "$KEEP_RUNNING" = true ]; then
    echo -e "Mode: ${YELLOW}Keep server running after tests${NC}"
fi
if [ "$VERBOSE" = true ]; then
    echo -e "Mode: ${YELLOW}Verbose output${NC}"
fi
echo "================================================"
echo ""

if [ "$CLEAN_START" = true ] && [ -d "$DATA_DIR" ]; then
    stop_server
    echo "Removing old data directory..."
    rm -rf "$DATA_DIR"
fi

build_extension
ensure_data_dir

TOTAL_PASSED=0
TOTAL_FAILED=0

for run in $(seq 1 "$REPEAT_COUNT"); do
    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo -e "${CYAN}=== Run $run of $REPEAT_COUNT ===${NC}"
    fi

    for phase in "${ACTIVE_PHASES[@]}"; do
        run_phase "$phase"
    done

    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo ""
    fi
done

restore_keep_running_state

echo "================================================"
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo "Total Results ($REPEAT_COUNT runs):"
fi
echo -e "Results: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
echo "================================================"

[ "$TOTAL_FAILED" -eq 0 ]
