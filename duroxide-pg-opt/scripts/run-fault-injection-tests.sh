#!/bin/bash
# Run fault injection tests for duroxide-pg
#
# Usage:
#   ./scripts/run-fault-injection-tests.sh           # Run all FI tests
#   ./scripts/run-fault-injection-tests.sh <test>    # Run specific test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=============================================="
echo "  duroxide-pg Fault Injection Tests"
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
echo "Feature: test-fault-injection"
echo ""

if [ -n "$1" ]; then
    # Run specific test
    echo "Running test: fault_$1"
    echo ""
    cargo test --test fault_injection_tests "fault_$1" --features test-fault-injection -- --ignored --nocapture
else
    # Run all fault injection tests
    echo "Running all fault injection tests..."
    echo ""
    cargo test --test fault_injection_tests --features test-fault-injection -- --ignored --nocapture
fi

echo ""
echo "=============================================="
echo "  Fault injection tests completed"
echo "=============================================="
