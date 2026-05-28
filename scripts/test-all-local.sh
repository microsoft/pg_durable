#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-all-local.sh - Run the full test suite locally (unit + E2E + pg_regress)
#
# Usage: ./scripts/test-all-local.sh [options]
#
# Options:
#   --skip-unit       Skip unit tests
#   --skip-e2e        Skip E2E tests
#   --skip-regress    Skip pg_regress tests
#   --pg-version VER  PostgreSQL major version (default: 17)
#
# Examples:
#   ./scripts/test-all-local.sh                    # Run all three suites
#   ./scripts/test-all-local.sh --skip-unit        # Skip unit tests
#   ./scripts/test-all-local.sh --pg-version 18    # Run against PG18

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# Defaults
RUN_UNIT=true
RUN_E2E=true
RUN_REGRESS=true
PG_VERSION="17"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-unit)    RUN_UNIT=false;    shift ;;
        --skip-e2e)     RUN_E2E=false;     shift ;;
        --skip-regress) RUN_REGRESS=false; shift ;;
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
            echo "Usage: ./scripts/test-all-local.sh [--skip-unit] [--skip-e2e] [--skip-regress] [--pg-version VER]"
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
echo -e "${CYAN}  pg_durable — Full Test Suite (PG${PG_VERSION})${NC}"
echo -e "${CYAN}================================================${NC}"
echo ""

# ── 1. Unit Tests ────────────────────────────────────────────────────────────
if [ "$RUN_UNIT" = true ]; then
    echo -e "${YELLOW}[1/3] Unit Tests (pgrx)${NC}"
    echo "────────────────────────────────────────────────"
    if ./scripts/test-unit.sh --pg-version "$PG_VERSION"; then
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
    if ./scripts/test-e2e-local.sh --clean --pg-version "$PG_VERSION"; then
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

    # Delegate to the Makefile target which handles reset, start, and installcheck
    if make test-regress PG_VERSION=pg"$PG_VERSION"; then
        REGRESS_RESULT="passed"
    else
        REGRESS_RESULT="FAILED"
        OVERALL=1
        # Show diffs on failure
        if [ -f regression.diffs ]; then
            echo ""
            echo -e "${RED}pg_regress diffs:${NC}"
            cat regression.diffs
        fi
    fi

    # Stop server after pg_regress
    echo "Stopping PostgreSQL..."
    ./scripts/pg-stop.sh --pg-version "$PG_VERSION"
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
