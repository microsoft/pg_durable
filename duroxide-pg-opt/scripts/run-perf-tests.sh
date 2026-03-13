#!/bin/bash
# Run performance tests for duroxide-pg
#
# Usage:
#   ./scripts/run-perf-tests.sh           # Run all perf tests
#   ./scripts/run-perf-tests.sh latency   # Run specific test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=============================================="
echo "  duroxide-pg Performance Tests"
echo "=============================================="
echo ""

# Check if DATABASE_URL is set
if [ -z "$DATABASE_URL" ]; then
    if [ -f .env ]; then
        echo "Loading DATABASE_URL from .env file..."
        export $(grep -v '^#' .env | xargs)
    else
        echo "ERROR: DATABASE_URL not set and no .env file found"
        exit 1
    fi
fi

echo "Database: ${DATABASE_URL%%@*}@..."
echo ""

if [ -n "$1" ]; then
    # Run specific test
    echo "Running test: perf_$1"
    echo ""
    cargo test --test perf_tests "perf_$1" -- --ignored --nocapture
else
    # Run all perf tests
    echo "Running all performance tests..."
    echo ""
    cargo test --test perf_tests -- --ignored --nocapture
fi

echo ""
echo "=============================================="
echo "  Performance tests completed"
echo "=============================================="
