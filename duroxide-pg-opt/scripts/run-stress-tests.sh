#!/bin/bash
# Run stress tests for duroxide-pg
#
# Usage:
#   ./scripts/run-stress-tests.sh                    # Run all stress tests (including pg-stress)
#   ./scripts/run-stress-tests.sh longpoll           # Run long-polling stress tests only
#   ./scripts/run-stress-tests.sh continue_as_new    # Run continue-as-new stress tests only
#   ./scripts/run-stress-tests.sh pg-stress          # Run pg-stress binary tests (parallel + large-payload)
#   ./scripts/run-stress-tests.sh pg-stress-parallel # Run pg-stress parallel test only
#   ./scripts/run-stress-tests.sh pg-stress-payload  # Run pg-stress large-payload test only
#   ./scripts/run-stress-tests.sh <test_name>        # Run specific test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# =============================================================================
# Argument Parsing
# =============================================================================

DURATION=10
TEST_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -h|--help|help)
            TEST_TYPE="help"
            shift
            ;;
        *)
            TEST_TYPE="$1"
            shift
            ;;
    esac
done

# Export duration for pg-stress tests
export PG_STRESS_DURATION="$DURATION"

echo "=============================================="
echo "  duroxide-pg Stress Tests"
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

# =============================================================================
# Resource Monitoring (ported from duroxide's run-stress-tests.sh)
# =============================================================================

# Monitor a background process and track peak memory (RSS) and average CPU usage
# Usage: monitor_process <pid>
# Outputs peak RSS in MB and average CPU % to stderr when process exits
monitor_process() {
    local pid=$1
    local interval=0.5
    local max_rss=0
    local total_cpu=0
    local samples=0

    # Loop while process is running
    while kill -0 $pid 2>/dev/null; do
        # Get CPU% and RSS from ps
        local ps_output=$(ps -o %cpu=,rss= -p $pid 2>/dev/null || echo "0 0")
        local cpu=$(echo "$ps_output" | awk '{print $1}')
        local rss=$(echo "$ps_output" | awk '{print $2}')

        # Update max RSS (in KB)
        if [ "$rss" -gt "$max_rss" ] 2>/dev/null; then
            max_rss=$rss
        fi

        # Accumulate CPU for average
        total_cpu=$(echo "$total_cpu + $cpu" | bc 2>/dev/null || echo "$total_cpu")
        samples=$((samples + 1))

        sleep $interval
    done

    # Calculate and print statistics
    if [ $samples -gt 0 ]; then
        local avg_cpu=$(echo "scale=1; $total_cpu / $samples" | bc 2>/dev/null || echo "0")
        local peak_rss_mb=$(echo "scale=1; $max_rss / 1024" | bc 2>/dev/null || echo "0")
        echo "" >&2
        echo "📊 Resource Usage Statistics:" >&2
        echo "   Peak RSS:    ${peak_rss_mb} MB" >&2
        echo "   Average CPU: ${avg_cpu}%" >&2
        echo "   Samples:     ${samples}" >&2
    fi
}

# Run a command with resource monitoring
# Usage: run_with_monitoring <command...>
run_with_monitoring() {
    echo "Starting with resource monitoring..."
    
    # Run the command in background
    "$@" &
    local pid=$!
    
    # Start monitoring in background
    monitor_process $pid &
    local monitor_pid=$!
    
    # Wait for main process
    wait $pid
    local exit_code=$?
    
    # Wait for monitor to finish (it will exit when main process exits)
    wait $monitor_pid 2>/dev/null || true
    
    return $exit_code
}

run_longpoll_stress() {
    echo "=== Long-Polling Stress Tests ==="
    echo ""
    run_with_monitoring cargo test --test stress_tests_longpoll -- --ignored --nocapture
}

run_continue_as_new_stress() {
    echo "=== Continue-as-New Stress Tests ==="
    echo ""
    run_with_monitoring cargo test --test continue_as_new_stress_tests -- --ignored --nocapture
}

run_general_stress() {
    echo "=== General Stress Tests (excluding longpoll comparison tests) ==="
    echo ""
    # Run all stress tests EXCEPT the longpoll comparison tests (they need single-thread for metrics)
    run_with_monitoring cargo test --test stress_tests -- --ignored --nocapture --skip stress_test_longpoll_comparison 2>/dev/null || true
}

run_longpoll_comparison_stress() {
    echo "=== Long-Poll Comparison Stress Tests (single-threaded for metrics) ==="
    echo ""
    # These tests use the global metrics recorder and must run single-threaded
    run_with_monitoring cargo test --test stress_tests stress_test_longpoll_comparison --features db-metrics -- --ignored --nocapture --test-threads=1
}

# =============================================================================
# pg-stress Binary Tests
# =============================================================================

# PG_STRESS_DURATION is set by argument parsing above

run_pg_stress_parallel() {
    echo "=== pg-stress: Parallel Orchestrations Test ==="
    echo "Duration: ${PG_STRESS_DURATION} seconds"
    echo ""
    # Build in release mode first (separate step for cleaner output)
    cargo build --release --package duroxide-pg-stress --bin pg-stress 2>/dev/null
    run_with_monitoring ./target/release/pg-stress --duration "$PG_STRESS_DURATION" --test-type parallel
}

run_pg_stress_large_payload() {
    echo "=== pg-stress: Large Payload Test ==="
    echo "Duration: ${PG_STRESS_DURATION} seconds"
    echo ""
    # Build in release mode first (separate step for cleaner output)
    cargo build --release --package duroxide-pg-stress --bin pg-stress 2>/dev/null
    run_with_monitoring ./target/release/pg-stress --duration "$PG_STRESS_DURATION" --test-type large-payload
}

run_pg_stress_all() {
    echo "=== pg-stress: All Stress Tests ==="
    echo "Duration: ${PG_STRESS_DURATION} seconds per test"
    echo ""
    # Build in release mode first (separate step for cleaner output)
    cargo build --release --package duroxide-pg-stress --bin pg-stress 2>/dev/null
    run_with_monitoring ./target/release/pg-stress --duration "$PG_STRESS_DURATION" --test-type all
}

case "$TEST_TYPE" in
    "help")
        echo "Usage: ./scripts/run-stress-tests.sh [OPTIONS] [TEST_TYPE]"
        echo ""
        echo "Options:"
        echo "  -d, --duration SEC  Duration in seconds for pg-stress tests (default: 10)"
        echo "  -h, --help          Show this help message"
        echo ""
        echo "Test Types:"
        echo "  (none)              Run all stress tests (including pg-stress)"
        echo "  longpoll            Run long-polling stress tests only"
        echo "  continue_as_new     Run continue-as-new stress tests only"
        echo "  general             Run general stress tests (excluding longpoll comparison)"
        echo "  comparison          Run longpoll comparison tests (single-threaded for metrics)"
        echo "  pg-stress           Run pg-stress binary tests (parallel + large-payload)"
        echo "  pg-stress-parallel  Run pg-stress parallel test only"
        echo "  pg-stress-payload   Run pg-stress large-payload test only"
        echo "  <test_name>         Run a specific test by name"
        echo ""
        echo "Environment Variables:"
        echo "  DATABASE_URL        PostgreSQL connection string (required)"
        echo ""
        echo "Examples:"
        echo "  ./scripts/run-stress-tests.sh --duration 60 pg-stress"
        echo "  ./scripts/run-stress-tests.sh -d 30 pg-stress-parallel"
        exit 0
        ;;
    "longpoll")
        run_longpoll_stress
        ;;
    "continue_as_new"|"can")
        run_continue_as_new_stress
        ;;
    "general")
        run_general_stress
        ;;
    "comparison"|"longpoll_comparison")
        run_longpoll_comparison_stress
        ;;
    "pg-stress")
        run_pg_stress_all
        ;;
    "pg-stress-parallel")
        run_pg_stress_parallel
        ;;
    "pg-stress-payload"|"pg-stress-large-payload")
        run_pg_stress_large_payload
        ;;
    "")
        # Run all stress tests (including pg-stress)
        echo "Running ALL stress tests..."
        echo ""
        run_longpoll_stress
        echo ""
        run_continue_as_new_stress
        echo ""
        run_general_stress
        echo ""
        run_longpoll_comparison_stress
        echo ""
        run_pg_stress_all
        ;;
    *)
        # Run specific test by name
        echo "Running specific test: $1"
        echo ""
        cargo test --test stress_tests_longpoll "$1" -- --ignored --nocapture 2>/dev/null || \
        cargo test --test continue_as_new_stress_tests "$1" -- --ignored --nocapture 2>/dev/null || \
        cargo test --test stress_tests "$1" -- --ignored --nocapture 2>/dev/null || \
        echo "Test '$1' not found in any stress test file"
        ;;
esac

echo ""
echo "=============================================="
echo "  Stress tests completed"
echo "=============================================="
