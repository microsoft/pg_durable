#!/bin/bash
# Run all extended tests (perf, stress, fault injection) for duroxide-pg
#
# Usage:
#   ./scripts/run-all-extended-tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=============================================="
echo "  duroxide-pg Extended Test Suite"
echo "=============================================="
echo ""
echo "This will run all performance, stress, and"
echo "fault injection tests. This may take a while."
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

# Track results
PERF_RESULT=0
STRESS_RESULT=0
FI_RESULT=0

# Run performance tests
echo ""
echo "############################################"
echo "#  PHASE 1: Performance Tests             #"
echo "############################################"
echo ""
"$SCRIPT_DIR/run-perf-tests.sh" || PERF_RESULT=$?

# Run stress tests
echo ""
echo "############################################"
echo "#  PHASE 2: Stress Tests                  #"
echo "############################################"
echo ""
"$SCRIPT_DIR/run-stress-tests.sh" || STRESS_RESULT=$?

# Run fault injection tests
echo ""
echo "############################################"
echo "#  PHASE 3: Fault Injection Tests         #"
echo "############################################"
echo ""
"$SCRIPT_DIR/run-fault-injection-tests.sh" || FI_RESULT=$?

# Summary
echo ""
echo "=============================================="
echo "  Extended Test Suite Summary"
echo "=============================================="
echo ""
[ $PERF_RESULT -eq 0 ] && echo "  ✓ Performance tests:      PASSED" || echo "  ✗ Performance tests:      FAILED"
[ $STRESS_RESULT -eq 0 ] && echo "  ✓ Stress tests:           PASSED" || echo "  ✗ Stress tests:           FAILED"
[ $FI_RESULT -eq 0 ] && echo "  ✓ Fault injection tests:  PASSED" || echo "  ✗ Fault injection tests:  FAILED"
echo ""

# Exit with failure if any test failed
if [ $PERF_RESULT -ne 0 ] || [ $STRESS_RESULT -ne 0 ] || [ $FI_RESULT -ne 0 ]; then
    echo "Some tests failed!"
    exit 1
fi

echo "All extended tests passed!"
