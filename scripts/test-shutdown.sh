#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-shutdown.sh - Regression test for pg_durable_worker graceful shutdown
#
# Exercises multiple stop/start cycles across different server states to verify
# that pg_durable_worker exits promptly on SIGTERM and does not leave a stale
# postmaster.pid behind (GitHub issue #308).
#
# Scenarios tested:
#   A — Idle worker:  worker ready, no running functions, clean stop
#   B — Active work:  worker mid-execution, clean stop
#   C — Rapid cycle:  back-to-back stop/start to detect postmaster.pid conflicts
#
# Usage: ./scripts/test-shutdown.sh [options]
#
# Options:
#   --pg-version VER     PostgreSQL major version (default: 17)
#   --timeout SEC        pg_ctl graceful-stop deadline (default: 20)
#   --latency-limit SEC  Max clean-stop duration (default: 3)
#   --cycles N           Number of stop/start cycles per scenario (default: 2)
#   --verbose, -v        Show detailed output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PG_VERSION="${PG_VERSION:-17}"
STOP_TIMEOUT=20
# A clean stop measures ~1.2s, dominated by SHUTDOWN_CHECK_INTERVAL. 3s leaves
# headroom for loaded CI while still catching a regression to the old ~8s path.
SHUTDOWN_LATENCY_LIMIT=3
CYCLES=2
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-version)
            PG_VERSION="$2"; shift 2 ;;
        --timeout)
            STOP_TIMEOUT="$2"; shift 2 ;;
        --latency-limit)
            SHUTDOWN_LATENCY_LIMIT="$2"; shift 2 ;;
        --cycles)
            CYCLES="$2"; shift 2 ;;
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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

log() { echo -e "$*"; }
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

start_server() {
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

# Render milliseconds as seconds with 2 decimals, e.g. 1210 -> 1.21
fmt_secs() {
    printf '%d.%02d' "$(($1 / 1000))" "$(($1 % 1000 / 10))"
}

# Stop the server and return the elapsed time in milliseconds. Whole-second
# resolution is too coarse to distinguish a ~1.2s clean stop from a regression.
# Prints elapsed ms to stdout; returns 0 on clean stop, 1 on fallback.
timed_stop() {
    local start end rc=0
    start=$(date +%s%3N)

    if ! "$PG_CTL" -D "$DATA_DIR" stop -m fast -t "$STOP_TIMEOUT" >/dev/null 2>&1; then
        rc=1
        "$PG_CTL" -D "$DATA_DIR" stop -m immediate >/dev/null 2>&1 || true
    fi

    end=$(date +%s%3N)
    echo "$((end - start))"
    return $rc
}

ensure_extension() {
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres >/dev/null 2>&1 <<'SQL'
BEGIN;
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
COMMIT;
SQL
}

launch_long_function() {
    # Fire-and-forget: start a durable function that sleeps for a while.
    "$PSQL" -h localhost -p "$PG_PORT" -U postgres -d postgres >/dev/null 2>&1 <<'SQL'
SELECT df.start(
    df.sql('SELECT pg_sleep(60)'),
    'shutdown-test-long-sleep'
);
SQL
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

info "Building pg_durable extension..."
cd "$PROJECT_DIR"
if ! cargo pgrx install --pg-config="$PG_CONFIG" --features http-allow-test-domains > /tmp/pg_durable-shutdown-build.log 2>&1; then
    echo -e "${RED}Build failed:${NC}"
    cat /tmp/pg_durable-shutdown-build.log
    exit 1
fi
info "Build complete"

if [ ! -d "$DATA_DIR" ]; then
    "$PGRX_BIN/initdb" -D "$DATA_DIR" -U postgres --no-locale -E UTF8 >/dev/null 2>&1
fi
configure_standard

# Make sure we start from a clean state
"$PG_CTL" -D "$DATA_DIR" stop -m immediate >/dev/null 2>&1 || true
sleep 1

# ---------------------------------------------------------------------------
# Scenario A: Idle worker — stop with no running functions
# ---------------------------------------------------------------------------

info ""
info "=== Scenario A: idle worker ($CYCLES cycles) ==="

for cycle in $(seq 1 "$CYCLES"); do
    info "  Cycle $cycle: starting server..."
    start_server
    ensure_extension
    wait_for_worker

    elapsed_ms=$(timed_stop) && clean=true || clean=false
    elapsed=$(fmt_secs "$elapsed_ms")
    if [ "$VERBOSE" = true ]; then
        log "    stop took ${elapsed}s (limit ${SHUTDOWN_LATENCY_LIMIT}s)"
    fi

    if [ "$clean" = true ] && [ "$elapsed_ms" -le "$((SHUTDOWN_LATENCY_LIMIT * 1000))" ]; then
        ok "Scenario A cycle $cycle: clean stop in ${elapsed}s"
    else
        fail "Scenario A cycle $cycle: stop took ${elapsed}s or required immediate fallback"
    fi

    sleep 1
done

# ---------------------------------------------------------------------------
# Scenario B: Active work — stop while a durable function is running
# ---------------------------------------------------------------------------

info ""
info "=== Scenario B: active worker ($CYCLES cycles) ==="

for cycle in $(seq 1 "$CYCLES"); do
    info "  Cycle $cycle: starting server with a running function..."
    start_server
    ensure_extension
    wait_for_worker

    launch_long_function
    # Give the function a moment to start executing
    sleep 2

    elapsed_ms=$(timed_stop) && clean=true || clean=false
    elapsed=$(fmt_secs "$elapsed_ms")
    if [ "$VERBOSE" = true ]; then
        log "    stop took ${elapsed}s (limit ${SHUTDOWN_LATENCY_LIMIT}s)"
    fi

    if [ "$clean" = true ] && [ "$elapsed_ms" -le "$((SHUTDOWN_LATENCY_LIMIT * 1000))" ]; then
        ok "Scenario B cycle $cycle: clean stop in ${elapsed}s"
    else
        fail "Scenario B cycle $cycle: stop took ${elapsed}s or required immediate fallback"
    fi

    sleep 1
done

# ---------------------------------------------------------------------------
# Scenario C: Rapid cycle — verify no stale postmaster.pid after restart
# ---------------------------------------------------------------------------

info ""
info "=== Scenario C: rapid stop/start cycle ($CYCLES rounds) ==="

for cycle in $(seq 1 "$CYCLES"); do
    info "  Cycle $cycle: stop..."
    # Server may still be running from previous scenario
    if "$PG_CTL" status -D "$DATA_DIR" >/dev/null 2>&1; then
        elapsed_ms=$(timed_stop) && clean=true || clean=false
        sleep 1
    else
        clean=true
    fi

    info "  Cycle $cycle: start..."
    if start_server 2>/dev/null; then
        ok "Scenario C cycle $cycle: restart succeeded (no stale postmaster.pid)"
        ensure_extension
        wait_for_worker || true
    else
        fail "Scenario C cycle $cycle: restart failed (possible stale postmaster.pid)"
    fi
done

# Final cleanup
"$PG_CTL" -D "$DATA_DIR" stop -m fast -t "$STOP_TIMEOUT" >/dev/null 2>&1 || \
    "$PG_CTL" -D "$DATA_DIR" stop -m immediate >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "================================================"
echo -e "Shutdown test results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "================================================"

[ "$FAIL" -eq 0 ]
