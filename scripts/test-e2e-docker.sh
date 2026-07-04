#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# test-e2e-docker.sh - Run E2E tests in Docker (linux/amd64)
#
# Usage: ./scripts/test-e2e-docker.sh [options] [test_filter] [repeat_count]
#
# Options:
#   --keep       Leave container running after tests for investigation
#   --rebuild    Force rebuild of Docker image
#
# Examples:
#   ./scripts/test-e2e-docker.sh                    # Run all tests
#   ./scripts/test-e2e-docker.sh --keep             # Keep container running
#   ./scripts/test-e2e-docker.sh 04_parallel        # Run matching test
#   ./scripts/test-e2e-docker.sh 04_parallel 5      # Run 5 times
#   ./scripts/test-e2e-docker.sh --keep --rebuild   # Rebuild image, keep running

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SQL_DIR="$PROJECT_DIR/tests/e2e/sql"

CONTAINER_NAME="pg_durable_e2e"
IMAGE_NAME="pg_durable:latest"

# Tests that require a PostgreSQL mode Docker does not manage in this script
SKIP_TESTS=(
    "00_requires_shared_preload"
    "17_superuser_guc"
    "44_connection_limit_backpressure"
    "45_connection_limit_timeout"
    "46_connection_limit_startup_validation"
    "47_http_dsl_disabled"
    "48_http_allow_all"
    # Needs the "reconcile" phase GUCs (reconcile_interval=2, retention_days=0)
    # so a pass acts within the 30s test window. The single fixed-config Docker
    # container keeps the production defaults (reconcile_interval=3600,
    # retention_days=30), under which the orphan is never reclaimed in time.
    "54_reconcile_orphans"
)

# Defaults
KEEP_RUNNING=false
FORCE_REBUILD=false
TEST_FILTER=""
REPEAT_COUNT=1

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep)
            KEEP_RUNNING=true
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        *)
            if [ -z "$TEST_FILTER" ]; then
                TEST_FILTER="$1"
            else
                REPEAT_COUNT="$1"
            fi
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

echo "================================================"
echo "pg_durable E2E Tests (Docker linux/amd64)"
if [ -n "$TEST_FILTER" ]; then
    echo -e "Filter: ${CYAN}$TEST_FILTER${NC}"
fi
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo -e "Repeat: ${CYAN}$REPEAT_COUNT times${NC}"
fi
if [ "$KEEP_RUNNING" = true ]; then
    echo -e "Mode: ${YELLOW}Keep container running after tests${NC}"
fi
echo "================================================"
echo ""

# Directory for exporting logs on failure (CI picks these up as artifacts)
LOG_EXPORT_DIR="${PG_DURABLE_LOG_DIR:-/tmp/docker-logs}"

# Export container logs before removal so CI can upload them as artifacts
export_logs() {
    mkdir -p "$LOG_EXPORT_DIR"
    echo -e "${YELLOW}Exporting container logs to $LOG_EXPORT_DIR ...${NC}"
    docker logs "$CONTAINER_NAME" &> "$LOG_EXPORT_DIR/docker-stdout.log" || true
    docker cp "$CONTAINER_NAME:/var/lib/postgresql/data/log/." "$LOG_EXPORT_DIR/" 2>/dev/null || true
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ "$KEEP_RUNNING" = false ]; then
        # On failure, dump logs before destroying the container
        if [ $exit_code -ne 0 ]; then
            export_logs
        fi
        echo -e "${YELLOW}Stopping container...${NC}"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    else
        echo ""
        echo -e "${GREEN}Container left running: $CONTAINER_NAME${NC}"
        echo "Connect: docker exec -it $CONTAINER_NAME psql -U postgres"
        echo "Logs:    docker logs -f $CONTAINER_NAME"
        echo "Stop:    ./scripts/pg-stop.sh --docker"
    fi
}
trap cleanup EXIT

# Stop any existing container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Build image if needed
if [ "$FORCE_REBUILD" = true ] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo -e "${YELLOW}Building Docker image (linux/amd64)...${NC}"
    docker build --platform linux/amd64 -t "$IMAGE_NAME" -f "$PROJECT_DIR/Dockerfile" "$PROJECT_DIR"
fi

# Start container
echo -e "${YELLOW}Starting container...${NC}"
docker run -d \
    --platform linux/amd64 \
    --name "$CONTAINER_NAME" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    "$IMAGE_NAME" >/dev/null

# Wait for PostgreSQL to be fully ready (including post-init restart)
echo -n "Waiting for PostgreSQL"
READY_COUNT=0
for i in {1..90}; do
    if docker exec "$CONTAINER_NAME" pg_isready -U postgres &>/dev/null; then
        READY_COUNT=$((READY_COUNT + 1))
        # Need 3 consecutive ready checks to ensure post-init restart is complete
        if [ $READY_COUNT -ge 3 ]; then
            echo " ready!"
            break
        fi
    else
        READY_COUNT=0
    fi
    echo -n "."
    sleep 1
done

# Extra wait for background worker to initialize
sleep 2

# Create extension and verify
echo -e "${YELLOW}Creating extension...${NC}"
if ! docker exec "$CONTAINER_NAME" psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS pg_durable;" 2>&1; then
    echo -e "${RED}Failed to create extension. Container logs:${NC}"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -50
    exit 1
fi

# Show version
echo -n "pg_durable version: "
VERSION=$(docker exec "$CONTAINER_NAME" psql -U postgres -t -c "SELECT df.version();" 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to get version:${NC}"
    echo "$VERSION"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -50
    exit 1
fi
echo "$VERSION" | tr -d ' \n'
echo ""
echo ""

# Copy test files to container
docker exec "$CONTAINER_NAME" mkdir -p /tests
for f in "$SQL_DIR"/*.sql; do
    docker cp "$f" "$CONTAINER_NAME:/tests/" 2>/dev/null || true
done

# Run tests
TOTAL_PASSED=0
TOTAL_FAILED=0

for run in $(seq 1 $REPEAT_COUNT); do
    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo -e "${CYAN}=== Run $run of $REPEAT_COUNT ===${NC}"
    fi
    
    PASSED=0
    FAILED=0

    for test_file in "$SQL_DIR"/*.sql; do
        [ -f "$test_file" ] || continue
        
        test_name=$(basename "$test_file" .sql)
        
        # Apply filter
        if [ -n "$TEST_FILTER" ] && [[ ! "$test_name" == *"$TEST_FILTER"* ]]; then
            continue
        fi

        # Skip tests that require a different PostgreSQL startup mode or
        # restart-sensitive connection-limit GUC changes.
        skip=false
        for skip_test in "${SKIP_TESTS[@]}"; do
            if [[ "$test_name" == "$skip_test" ]]; then
                skip=true
                break
            fi
        done
        [[ "$skip" == true ]] && continue

        echo -n "  $test_name ... "
        
        output=$(docker exec "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -f "/tests/$test_name.sql" 2>&1)
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            if echo "$output" | grep -q "TEST PASSED"; then
                echo -e "${GREEN}PASS${NC}"
                PASSED=$((PASSED + 1))
            elif echo "$output" | grep -q "TEST FAILED"; then
                echo -e "${RED}FAIL${NC}"
                echo "$output" | grep -E "(NOTICE|ERROR|TEST FAILED)" | tail -15
                FAILED=$((FAILED + 1))
            else
                echo -e "${GREEN}PASS${NC}"
                PASSED=$((PASSED + 1))
            fi
        else
            echo -e "${RED}FAIL${NC}"
            echo "$output" | grep -E "(NOTICE|ERROR)" | tail -15
            FAILED=$((FAILED + 1))
        fi
    done
    
    TOTAL_PASSED=$((TOTAL_PASSED + PASSED))
    TOTAL_FAILED=$((TOTAL_FAILED + FAILED))
    
    if [ "$REPEAT_COUNT" -gt 1 ]; then
        echo -e "  Run $run: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
        echo ""
    fi
done

echo ""
echo "================================================"
if [ "$REPEAT_COUNT" -gt 1 ]; then
    echo "Total Results ($REPEAT_COUNT runs):"
fi
echo -e "Results: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
echo "================================================"

[ $TOTAL_FAILED -eq 0 ]

