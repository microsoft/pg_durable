#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-epoch-race.sh - Regression test for the extension epoch race that could
# certify a stale duroxide runtime across DROP/CREATE EXTENSION (GitHub issue #333).
#
# The background worker used to write its readiness record and epoch sentinel only
# after runtime initialization. If a DROP EXTENSION / CREATE EXTENSION replaced the
# provider objects mid-initialization, the sentinel landed in the NEW epoch's `df`
# schema, so the stale runtime — bound to provider objects that no longer existed —
# was incorrectly certified as current and never restarted. Readiness then timed out.
#
# This test makes the race deterministic using a build-in test hook
# (PG_DURABLE_TEST_PAUSE_BEFORE_READY_MS) that pauses the worker between epoch
# capture / runtime initialization and readiness publication. During that pause the
# test drops and recreates the extension, then verifies:
#   1. The worker tears down the stale runtime and reinitializes (log evidence).
#   2. The worker eventually becomes ready.
#   3. `_worker_ready` describes the CURRENT provider epoch (a durable function runs).
#
# Usage: ./scripts/test-epoch-race.sh [options]
#
# Options:
#   --pg-version VER   PostgreSQL major version (default: 17)
#   --pause-ms MS      Worker init->ready pause window (default: 4000)
#   --verbose, -v      Show detailed output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PG_VERSION="${PG_VERSION:-17}"
PAUSE_MS=4000
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-version)
            PG_VERSION="$2"; shift 2 ;;
        --pause-ms)
            PAUSE_MS="$2"; shift 2 ;;
        --verbose|-v)
            VERBOSE=true; shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^[^#]/{ /^[^#]/d; s/^# \{0,1\}//; p }' "$0"
            exit 0 ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

PG_PORT="$((28800 + PG_VERSION))"
PGRX_HOME="$HOME/.pgrx"
DATA_DIR="$PGRX_HOME/data-$PG_VERSION"
LOG_FILE="$PGRX_HOME/$PG_VERSION.log"

shopt -s nullglob
PGRX_CANDIDATES=("$PGRX_HOME"/"$PG_VERSION".*/pgrx-install/bin)
shopt -u nullglob
if [ "${#PGRX_CANDIDATES[@]}" -eq 0 ]; then
    echo "Error: pgrx PostgreSQL $PG_VERSION not installed (run: cargo pgrx init)"
    exit 1
fi

PGRX_BIN="${PGRX_CANDIDATES[0]}"
PSQL="$PGRX_BIN/psql"
PG_CTL="$PGRX_BIN/pg_ctl"
PG_ISREADY="$PGRX_BIN/pg_isready"
PG_CONFIG="$PGRX_BIN/pg_config"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

log()  { echo -e "$*"; }
info() { log "${CYAN}$*${NC}"; }
ok()   { log "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { log "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Server helpers
# ---------------------------------------------------------------------------

configure_standard() {
    local conf="$DATA_DIR/postgresql.conf"
    sed -i.bak '/^[#[:space:]]*shared_preload_libraries/d' "$conf"
    sed -i.bak '/^[#[:space:]]*pg_durable\./d' "$conf"
    rm -f "$conf.bak"
    : > "$DATA_DIR/postgresql.auto.conf"
    cat >> "$conf" <<EOF
port = $PG_PORT
shared_preload_libraries = 'pg_durable'
pg_durable.worker_role = 'postgres'
pg_durable.database = 'postgres'
pg_durable.enable_superuser_instances = on
EOF
}

# Start the server. The worker's test pause is controlled via the
# PG_DURABLE_TEST_PAUSE_BEFORE_READY_MS environment variable, which the postmaster
# (and thus the background worker) inherits from this shell. Pass an empty value to
# disable the pause.
start_server() {
    local pause="${1:-}"
    PG_DURABLE_TEST_PAUSE_BEFORE_READY_MS="$pause" \
        "$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start >/dev/null 2>&1
    local attempts=0
    until "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres -q >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 60 ]; then
            echo "PostgreSQL did not become ready on port $PG_PORT"
            return 1
        fi
        sleep 0.5
    done
}

stop_server() {
    "$PG_CTL" -D "$DATA_DIR" stop -m fast -t 20 >/dev/null 2>&1 || \
        "$PG_CTL" -D "$DATA_DIR" stop -m immediate >/dev/null 2>&1 || true
}

wait_for_worker() {
    local attempts=0
    local dx_schema ready
    while [ "$attempts" -lt 120 ]; do
        dx_schema=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres \
            -Atqc "SELECT df.duroxide_schema();" 2>/dev/null | tr -d ' \n' || echo "_duroxide")
        ready=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres \
            -Atqc "SELECT COALESCE((SELECT TRUE FROM ${dx_schema}._worker_ready WHERE schema_version >= 1), FALSE);" \
            2>/dev/null | tr -d ' \n' || echo "f")
        [ "$ready" = "t" ] && return 0
        sleep 0.5
        attempts=$((attempts + 1))
    done
    echo "Worker did not become ready within 60 s"
    return 1
}

ensure_extension() {
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres >/dev/null 2>&1 <<'SQL'
BEGIN;
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
COMMIT;
SQL
}

# Run a durable function end-to-end. Success proves the worker's runtime is bound to
# the CURRENT provider epoch: the fetch_work_item / fetch_orchestration_item provider
# functions and their backing tables must exist and be the ones this runtime polls.
run_durable_function() {
    local inst status attempts=0
    inst=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres -Atqc \
        "SELECT df.start(df.sql('SELECT 42'), 'epoch-race-check');" 2>/dev/null | tr -d ' \n')
    [ -n "$inst" ] || return 1
    while [ "$attempts" -lt 300 ]; do
        status=$("$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres -Atqc \
            "SELECT lower(s) FROM df.status('$inst') s;" 2>/dev/null | tr -d ' \n')
        case "$status" in
            completed) return 0 ;;
            failed|cancelled) return 1 ;;
        esac
        sleep 0.1
        attempts=$((attempts + 1))
    done
    return 1
}

cleanup() {
    stop_server
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

info "Building pg_durable extension..."
cd "$PROJECT_DIR"
if ! cargo pgrx install --pg-config="$PG_CONFIG" --features http-allow-test-domains \
        > /tmp/pg_durable-epoch-race-build.log 2>&1; then
    echo -e "${RED}Build failed:${NC}"
    cat /tmp/pg_durable-epoch-race-build.log
    exit 1
fi
info "Build complete"

if [ ! -d "$DATA_DIR" ]; then
    "$PGRX_BIN/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
fi
configure_standard

# ---------------------------------------------------------------------------
# Scenario: DROP/CREATE EXTENSION during the worker's init->ready pause
# ---------------------------------------------------------------------------

info "=== Epoch race: drop/recreate extension during worker initialization ==="

# 1. Start without the pause and install the extension so the worker is healthy.
info "Starting server and installing extension..."
start_server ""
ensure_extension
if ! wait_for_worker; then
    fail "Baseline worker readiness failed before the race scenario"
    stop_server
    exit 1
fi
ok "Baseline worker is ready"

# 2. Restart with the pause enabled. On restart the worker captures the current
#    epoch, initializes a runtime, then pauses before publishing readiness.
info "Restarting server with a ${PAUSE_MS}ms init->ready pause..."
stop_server
# Record where the current log ends so we only inspect messages from this restart.
LOG_MARK=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
start_server "$PAUSE_MS"

# 3. During the pause window, replace the extension epoch. The just-initialized
#    runtime is now stale: its provider objects have been dropped and recreated.
info "Dropping and recreating the extension mid-initialization..."
# Small delay so the worker has reached the pause; well within the pause window.
sleep 1
ensure_extension

# 4. The worker must tear down the stale runtime and reinitialize against the new
#    epoch, then become ready.
info "Waiting for worker to recover and become ready..."
if wait_for_worker; then
    ok "Worker became ready after drop/recreate during initialization"
else
    fail "Worker did NOT become ready after drop/recreate (stale-runtime race)"
fi

# 5. Log evidence that the stale runtime was detected and torn down.
if tail -n +"$((LOG_MARK + 1))" "$LOG_FILE" 2>/dev/null \
        | grep -q "extension epoch changed"; then
    ok "Worker logged stale-runtime teardown ('extension epoch changed')"
else
    fail "Expected 'extension epoch changed' teardown log not found"
fi

# 6. Prove readiness describes the CURRENT epoch: a durable function must complete,
#    which requires the runtime to poll live provider functions/tables.
info "Running a durable function against the current epoch..."
if run_durable_function; then
    ok "Durable function completed — readiness reflects the current provider epoch"
else
    fail "Durable function did not complete — runtime not bound to current epoch"
fi

if [ "$VERBOSE" = true ]; then
    info "--- Worker log (this restart) ---"
    tail -n +"$((LOG_MARK + 1))" "$LOG_FILE" 2>/dev/null | grep "pg_durable:" || true
fi

stop_server

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
info "=== Summary ==="
log "  Passed: $PASS"
log "  Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}EPOCH RACE TEST FAILED${NC}"
    exit 1
fi
echo -e "${GREEN}EPOCH RACE TEST PASSED${NC}"
