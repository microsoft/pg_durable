#!/bin/bash
# test-all-local.sh - Run the full test suite locally (unit + E2E + pg_regress)
#
# Usage: ./scripts/test-all-local.sh [options]
#
# Options:
#   --skip-unit       Skip unit tests
#   --skip-e2e        Skip E2E tests
#   --skip-regress    Skip pg_regress tests
#
# Examples:
#   ./scripts/test-all-local.sh                # Run all three suites
#   ./scripts/test-all-local.sh --skip-unit    # Skip unit tests

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# Defaults
RUN_UNIT=true
RUN_E2E=true
RUN_REGRESS=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-unit)    RUN_UNIT=false;    shift ;;
        --skip-e2e)     RUN_E2E=false;     shift ;;
        --skip-regress) RUN_REGRESS=false; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: ./scripts/test-all-local.sh [--skip-unit] [--skip-e2e] [--skip-regress]"
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

# Track results
UNIT_RESULT="skipped"
E2E_RESULT="skipped"
REGRESS_RESULT="skipped"
OVERALL=0

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  pg_durable — Full Test Suite${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""

# ── 1. Unit Tests ────────────────────────────────────────────────────────────
if [ "$RUN_UNIT" = true ]; then
    echo -e "${YELLOW}[1/3] Unit Tests (pgrx)${NC}"
    echo "────────────────────────────────────────────────"
    if ./scripts/test-unit.sh; then
        UNIT_RESULT="passed"
    else
        UNIT_RESULT="FAILED"
        OVERALL=1
    fi
    echo ""
else
    echo -e "${YELLOW}[1/3] Unit Tests — skipped${NC}"
    echo ""
fi

# ── 2. E2E Tests ─────────────────────────────────────────────────────────────
if [ "$RUN_E2E" = true ]; then
    echo -e "${YELLOW}[2/3] E2E Tests${NC}"
    echo "────────────────────────────────────────────────"
    if ./scripts/test-e2e-local.sh; then
        E2E_RESULT="passed"
    else
        E2E_RESULT="FAILED"
        OVERALL=1
    fi
    echo ""
else
    echo -e "${YELLOW}[2/3] E2E Tests — skipped${NC}"
    echo ""
fi

# ── 3. pg_regress Tests ──────────────────────────────────────────────────────
if [ "$RUN_REGRESS" = true ]; then
    echo -e "${YELLOW}[3/3] pg_regress Tests${NC}"
    echo "────────────────────────────────────────────────"

    # Configure pg_durable.database for contrib_regression and start server
    PG_CONF="$HOME/.pgrx/data-17/postgresql.conf"
    if [ -f "$PG_CONF" ]; then
        sed -i.bak '/^pg_durable.database/d' "$PG_CONF"
        echo "pg_durable.database = 'contrib_regression'" >> "$PG_CONF"
    fi

    echo "Starting PostgreSQL (pg_durable.database=contrib_regression)..."
    ./scripts/pg-start.sh

    # Drop stale test database if it exists (worker may have connected to it)
    PSQL=$(ls ~/.pgrx/17.*/pgrx-install/bin/psql 2>/dev/null | head -1)
    "$PSQL" -h localhost -p 28817 -d postgres \
        -c "DROP DATABASE IF EXISTS contrib_regression WITH (FORCE);" 2>/dev/null || true

    # Give the worker a moment to enter retry mode
    sleep 2

    if make installcheck; then
        REGRESS_RESULT="passed"
    else
        REGRESS_RESULT="FAILED"
        OVERALL=1
        # Show diffs on failure
        if [ -f test/regress/regression.diffs ]; then
            echo ""
            echo -e "${RED}pg_regress diffs:${NC}"
            cat test/regress/regression.diffs
        fi
    fi

    # Stop server and restore pg_durable.database for normal use
    echo "Stopping PostgreSQL..."
    ./scripts/pg-stop.sh
    if [ -f "$PG_CONF" ]; then
        sed -i.bak '/^pg_durable.database/d' "$PG_CONF"
        echo "pg_durable.database = 'postgres'" >> "$PG_CONF"
    fi
    echo ""
else
    echo -e "${YELLOW}[3/3] pg_regress Tests — skipped${NC}"
    echo ""
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}================================================${NC}"

print_result() {
    local name=$1 result=$2
    case $result in
        passed)  echo -e "  $name: ${GREEN}$result${NC}" ;;
        FAILED)  echo -e "  $name: ${RED}$result${NC}" ;;
        skipped) echo -e "  $name: ${YELLOW}$result${NC}" ;;
    esac
}

print_result "Unit tests   " "$UNIT_RESULT"
print_result "E2E tests    " "$E2E_RESULT"
print_result "pg_regress   " "$REGRESS_RESULT"
echo ""

if [ $OVERALL -eq 0 ]; then
    echo -e "  ${GREEN}All test suites passed!${NC}"
else
    echo -e "  ${RED}Some test suites failed.${NC}"
fi
echo ""

exit $OVERALL
