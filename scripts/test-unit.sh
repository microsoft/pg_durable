#!/bin/bash
# test-unit.sh - Run pgrx unit tests
#
# Usage: ./scripts/test-unit.sh [options] [test_filter]
#
# Options:
#   --pg-version VER  PostgreSQL major version (default: 17)
#
# Examples:
#   ./scripts/test-unit.sh              # Run all unit tests
#   ./scripts/test-unit.sh simple       # Run tests matching "simple"
#   ./scripts/test-unit.sh --pg-version 18

set -e

cd "$(dirname "$0")/.."

PG_VERSION="17"
TEST_FILTER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --pg-version)
            PG_VERSION="$2"
            shift 2
            ;;
        *)
            TEST_FILTER="$1"
            shift
            ;;
    esac
done

echo "================================================"
echo "pg_durable Unit Tests (pgrx) — PG${PG_VERSION}"
echo "================================================"
echo ""

if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    cargo pgrx test "pg${PG_VERSION}" -- "$TEST_FILTER"
else
    cargo pgrx test "pg${PG_VERSION}"
fi

