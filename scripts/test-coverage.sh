#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-coverage.sh - Measure code coverage for pg_durable
#
# Builds the extension with coverage instrumentation, runs tests,
# then collects and reports coverage data using LLVM source-based coverage.
#
# Usage: ./scripts/test-coverage.sh [options] [test_filter]
#
# Options:
#   --with-unit         Also run pgrx unit tests (combined coverage)
#   --unit-only         Run only pgrx unit tests (skip E2E)
#   --html              Generate HTML report (default: summary only)
#   --pg-version VER    PostgreSQL major version (default: 17)
#   --keep              Keep server running after tests
#   --verbose           Show E2E test output
#   -v                  Same as --verbose
#
# Examples:
#   ./scripts/test-coverage.sh                     # E2E coverage only
#   ./scripts/test-coverage.sh --with-unit         # Combined unit + E2E coverage
#   ./scripts/test-coverage.sh --unit-only         # Unit test coverage only
#   ./scripts/test-coverage.sh --html              # Generate HTML coverage report
#   ./scripts/test-coverage.sh --html --with-unit  # Combined with HTML report
#   ./scripts/test-coverage.sh 04_parallel         # Coverage for a specific E2E test
#
# Output:
#   Coverage data:  target/coverage/profdata/pg_durable.profdata
#   HTML report:    target/coverage/html/index.html  (with --html)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
HTML=false
WITH_UNIT=false
UNIT_ONLY=false
PG_VERSION="17"
E2E_ARGS=()

# Parse arguments — pass unrecognized ones through to test-e2e-local.sh
while [[ $# -gt 0 ]]; do
    case $1 in
        --html)
            HTML=true
            shift
            ;;
        --with-unit)
            WITH_UNIT=true
            shift
            ;;
        --unit-only)
            UNIT_ONLY=true
            WITH_UNIT=true
            shift
            ;;
        --pg-version)
            PG_VERSION="$2"
            E2E_ARGS+=("--pg-version" "$2")
            shift 2
            ;;
        *)
            E2E_ARGS+=("$1")
            shift
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Resolve paths
PGRX_CONFIG="$HOME/.pgrx/config.toml"
PG_CONFIG=$(grep -E "^pg${PG_VERSION}\s*=\s*\"" "$PGRX_CONFIG" | head -1 | cut -d'"' -f2)
if [ -z "$PG_CONFIG" ]; then
    echo -e "${RED}Error: pg${PG_VERSION} not configured in $PGRX_CONFIG${NC}"
    exit 1
fi

PGRX_BIN_DIR="$(dirname "$PG_CONFIG")"
DATA_DIR="$HOME/.pgrx/data-$PG_VERSION"
PG_PORT="$((28800 + PG_VERSION))"
PG_CTL="$PGRX_BIN_DIR/pg_ctl"
PG_ISREADY="$PGRX_BIN_DIR/pg_isready"

SYSROOT=$(rustc --print sysroot)
LLVM_PROFDATA="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata"
LLVM_COV="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"

# Verify llvm tools exist
for tool in "$LLVM_PROFDATA" "$LLVM_COV"; do
    if [ ! -x "$tool" ]; then
        echo -e "${RED}Error: $(basename "$tool") not found at $tool${NC}"
        echo "Install with: rustup component add llvm-tools-preview"
        exit 1
    fi
done

# Coverage output directories
COV_DIR="$PROJECT_DIR/target/coverage"
PROFRAW_DIR="$COV_DIR/profraw"
PROFRAW_UNIT_DIR="$COV_DIR/profraw-unit"
PROFRAW_E2E_DIR="$COV_DIR/profraw-e2e"
PROFDATA_DIR="$COV_DIR/profdata"
HTML_DIR="$COV_DIR/html"

# Determine step count based on mode
if [ "$UNIT_ONLY" = true ]; then
    STEPS=4
    MODE="Unit tests only"
elif [ "$WITH_UNIT" = true ]; then
    STEPS=6
    MODE="Unit + E2E tests"
else
    STEPS=5
    MODE="E2E tests only"
fi

echo "================================================"
echo "pg_durable Coverage"
echo -e "PostgreSQL: ${CYAN}PG${PG_VERSION}${NC}  |  Mode: ${CYAN}${MODE}${NC}"
echo "================================================"
echo ""

# ── Step 1: Clean previous coverage data ──────────────────────────────
STEP=1
echo -e "${YELLOW}[$STEP/$STEPS] Cleaning previous coverage data...${NC}"
rm -rf "$PROFRAW_DIR" "$PROFRAW_UNIT_DIR" "$PROFRAW_E2E_DIR" "$PROFDATA_DIR"
mkdir -p "$PROFRAW_UNIT_DIR" "$PROFRAW_E2E_DIR" "$PROFDATA_DIR" "$HTML_DIR"

# ── Step 2: Build extension with coverage instrumentation ─────────────
STEP=2
echo -e "${YELLOW}[$STEP/$STEPS] Building extension with coverage instrumentation...${NC}"

# Stop server if running (it's loaded with the non-instrumented .so)
if "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres -q 2>/dev/null; then
    echo "  Stopping running PostgreSQL (will restart with instrumented build)..."
    "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
    sleep 1
fi

cd "$PROJECT_DIR"

# Export RUSTFLAGS so that all subsequent cargo commands (including
# test-e2e-local.sh's internal `cargo pgrx install`) build with
# instrumentation.
export RUSTFLAGS="-C instrument-coverage"

cargo pgrx install --pg-config="$PG_CONFIG" 2>&1 | grep -v "^warning:" || true

# Find the installed .so
SO_FILE=$(ls "$HOME"/.pgrx/"$PG_VERSION".*/pgrx-install/lib/postgresql/pg_durable.so 2>/dev/null | head -1)
if [ -z "$SO_FILE" ]; then
    echo -e "${RED}Error: pg_durable.so not found after install${NC}"
    exit 1
fi
echo "  Instrumented binary: $SO_FILE"

# Track test exit codes
UNIT_EXIT=0
E2E_EXIT=0
# Binary used by unit tests (set after cargo pgrx test runs)
UNIT_TEST_BIN=""

# ── Step 2b (optional): Run pgrx unit tests ──────────────────────────
if [ "$WITH_UNIT" = true ]; then
    STEP=$((STEP + 1))
    echo ""
    echo -e "${YELLOW}[$STEP/$STEPS] Running pgrx unit tests with coverage collection...${NC}"

    # Unit tests use a separate profraw dir because they produce a different
    # binary (test binary with pg_test feature) than the installed .so.
    export LLVM_PROFILE_FILE="$PROFRAW_UNIT_DIR/pg_durable-%p-%m.profraw"

    cargo pgrx test "pg${PG_VERSION}" 2>&1 || UNIT_EXIT=$?

    if [ "$UNIT_EXIT" -ne 0 ]; then
        echo -e "${RED}  Unit tests failed (exit $UNIT_EXIT) — continuing for coverage${NC}"
    else
        echo -e "${GREEN}  Unit tests passed${NC}"
    fi

    # Find the test binary that cargo pgrx test just built (for llvm-cov)
    UNIT_TEST_BIN=$(find "$PROJECT_DIR/target/debug/deps/" -name "pg_durable-*" \
        -executable -type f ! -name "*.d" ! -name "*.so" 2>/dev/null | head -1)
    UNIT_PROFRAW=$(ls "$PROFRAW_UNIT_DIR"/*.profraw 2>/dev/null | wc -l)
    echo "  Profraw files after unit tests: $UNIT_PROFRAW"
    if [ -n "$UNIT_TEST_BIN" ]; then
        echo "  Test binary: $UNIT_TEST_BIN"
    fi
fi

# ── Step N: Run E2E tests ─────────────────────────────────────────────
if [ "$UNIT_ONLY" = false ]; then
    STEP=$((STEP + 1))
    echo ""
    echo -e "${YELLOW}[$STEP/$STEPS] Running E2E tests with coverage collection...${NC}"

    # E2E profraw goes to a separate dir, mapped to the installed .so
    export LLVM_PROFILE_FILE="$PROFRAW_E2E_DIR/pg_durable-%p-%m.profraw"

    # Run the E2E test suite. We pass --keep so the script doesn't stop
    # the server (we need to stop it ourselves to flush profraw).
    "$SCRIPT_DIR/test-e2e-local.sh" --keep "${E2E_ARGS[@]}" || E2E_EXIT=$?

    # Stop PostgreSQL to flush coverage data
    echo ""
    STEP=$((STEP + 1))
    echo -e "${YELLOW}[$STEP/$STEPS] Stopping PostgreSQL to flush coverage data...${NC}"
    if "$PG_ISREADY" -h localhost -p "$PG_PORT" -U postgres -q 2>/dev/null; then
        "$PG_CTL" -D "$DATA_DIR" stop -m fast 2>/dev/null || true
        sleep 1
    fi
fi

# Clear RUSTFLAGS so the restore build at the end is not instrumented
unset RUSTFLAGS
unset LLVM_PROFILE_FILE

# Check that profraw files were generated
UNIT_COUNT=$(ls "$PROFRAW_UNIT_DIR"/*.profraw 2>/dev/null | wc -l)
E2E_COUNT=$(ls "$PROFRAW_E2E_DIR"/*.profraw 2>/dev/null | wc -l)
TOTAL_COUNT=$((UNIT_COUNT + E2E_COUNT))
if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No .profraw files generated${NC}"
    echo "  This usually means the instrumented binary was not loaded by PostgreSQL."
    exit 1
fi
echo "  Collected $TOTAL_COUNT profraw file(s) (unit: $UNIT_COUNT, e2e: $E2E_COUNT)"

# ── Final step: Merge and report ──────────────────────────────────────
STEP=$((STEP + 1))
echo -e "${YELLOW}[$STEP/$STEPS] Generating coverage report...${NC}"

# Restrict coverage report to pg_durable source files only.
SRC_DIR="$PROJECT_DIR/src"

# When we have both unit and E2E coverage, the profraw files come from
# different binaries (test binary for unit tests, installed .so for E2E).
# llvm-cov can only report against one binary at a time, so we:
# 1. Export LCOV from each binary separately
# 2. Merge the LCOV files with lcov --add-tracefile
LCOV_FILES=()

# Process E2E profraw (against the installed .so)
if [ "$E2E_COUNT" -gt 0 ]; then
    E2E_PROFDATA="$PROFDATA_DIR/e2e.profdata"
    "$LLVM_PROFDATA" merge -sparse "$PROFRAW_E2E_DIR"/*.profraw -o "$E2E_PROFDATA"

    # Save a copy of the instrumented .so — the restore build below will
    # overwrite it, but llvm-cov needs the exact binary that produced the data.
    INSTRUMENTED_SO="$COV_DIR/pg_durable-instrumented.so"
    cp -p "$SO_FILE" "$INSTRUMENTED_SO"

    E2E_LCOV="$COV_DIR/e2e.lcov"
    "$LLVM_COV" export "$INSTRUMENTED_SO" \
        --instr-profile="$E2E_PROFDATA" \
        --format=lcov \
        "$SRC_DIR" > "$E2E_LCOV" 2>/dev/null
    LCOV_FILES+=("$E2E_LCOV")
fi

# Process unit test profraw (against the test binary)
if [ "$UNIT_COUNT" -gt 0 ] && [ -n "$UNIT_TEST_BIN" ]; then
    UNIT_PROFDATA="$PROFDATA_DIR/unit.profdata"
    "$LLVM_PROFDATA" merge -sparse "$PROFRAW_UNIT_DIR"/*.profraw -o "$UNIT_PROFDATA"

    UNIT_LCOV="$COV_DIR/unit.lcov"
    "$LLVM_COV" export "$UNIT_TEST_BIN" \
        --instr-profile="$UNIT_PROFDATA" \
        --format=lcov \
        "$SRC_DIR" > "$UNIT_LCOV" 2>/dev/null
    LCOV_FILES+=("$UNIT_LCOV")
fi

# Merge LCOV files (or use the single one available)
MERGED_LCOV="$COV_DIR/merged.lcov"
if [ "${#LCOV_FILES[@]}" -eq 0 ]; then
    echo -e "${RED}Error: No coverage data could be extracted${NC}"
    exit 1
elif [ "${#LCOV_FILES[@]}" -eq 1 ]; then
    cp "${LCOV_FILES[0]}" "$MERGED_LCOV"
else
    # lcov --add-tracefile merges coverage from multiple runs
    lcov -q \
        $(printf -- '-a %s ' "${LCOV_FILES[@]}") \
        -o "$MERGED_LCOV" 2>/dev/null
fi

echo ""
echo "================================================"
echo "Coverage Summary"
echo "================================================"

# Use lcov --summary for the combined report
lcov --summary "$MERGED_LCOV" 2>&1 | grep -E "lines|functions"

# Also show per-file breakdown via llvm-cov if we have a single binary,
# or fall back to lcov --list for multi-binary merged data
if [ "${#LCOV_FILES[@]}" -eq 1 ] && [ "$E2E_COUNT" -gt 0 ]; then
    echo ""
    "$LLVM_COV" report "$INSTRUMENTED_SO" \
        --instr-profile="$E2E_PROFDATA" \
        --summary-only \
        "$SRC_DIR"
elif [ "${#LCOV_FILES[@]}" -eq 1 ] && [ "$UNIT_COUNT" -gt 0 ] && [ -n "$UNIT_TEST_BIN" ]; then
    echo ""
    "$LLVM_COV" report "$UNIT_TEST_BIN" \
        --instr-profile="$UNIT_PROFDATA" \
        --summary-only \
        "$SRC_DIR"
else
    echo ""
    lcov --list "$MERGED_LCOV" 2>/dev/null | grep -E "^/workspaces|TOTAL" | \
        sed 's|/workspaces/pg_durable/src/||'
fi

if [ "$HTML" = true ]; then
    genhtml -q "$MERGED_LCOV" \
        --output-directory "$HTML_DIR" \
        --title "pg_durable coverage" \
        --prefix "$PROJECT_DIR" 2>/dev/null
    echo ""
    echo -e "${GREEN}HTML report: $HTML_DIR/index.html${NC}"
fi

echo ""
echo -e "LCOV data:  ${CYAN}$MERGED_LCOV${NC}"
echo ""

# Rebuild without instrumentation so normal development isn't affected
echo -e "${YELLOW}Rebuilding extension without instrumentation...${NC}"
cargo pgrx install --pg-config="$PG_CONFIG" >/dev/null 2>&1
echo -e "${GREEN}Done. Extension restored to normal build.${NC}"

# Exit with failure if any test suite failed
if [ "$UNIT_EXIT" -ne 0 ]; then
    exit "$UNIT_EXIT"
fi
exit "$E2E_EXIT"
