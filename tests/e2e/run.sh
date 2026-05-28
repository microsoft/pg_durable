#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# E2E tests for pg_durable
# Runs SQL test cases against a Docker container with full Duroxide runtime

# Don't exit on error - we handle errors ourselves
set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"

IMAGE_NAME="pg_durable:e2e-test"
CONTAINER_NAME="pg_durable_e2e_$$"
TIMEOUT=60

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cleanup() {
    echo "Cleaning up..."
    docker stop $CONTAINER_NAME 2>/dev/null || true
    docker rm $CONTAINER_NAME 2>/dev/null || true
}
trap cleanup EXIT

echo "================================================"
echo "pg_durable E2E Tests"
echo "================================================"
echo ""

# 1. Build fresh image
echo -e "${YELLOW}Building Docker image...${NC}"
docker build --platform linux/amd64 -t $IMAGE_NAME "$PROJECT_DIR" --quiet

# 2. Start container
echo -e "${YELLOW}Starting container...${NC}"
docker run -d --name $CONTAINER_NAME \
    --platform linux/amd64 \
    -e POSTGRES_PASSWORD=postgres \
    $IMAGE_NAME > /dev/null

# 3. Wait for ready (PostgreSQL restarts after init, so we need to be patient)
echo -n "Waiting for PostgreSQL + pg_durable"
READY=false
for i in $(seq 1 $TIMEOUT); do
    # Check if PostgreSQL is accepting connections
    if docker exec $CONTAINER_NAME psql -U postgres -c "SELECT 1;" &>/dev/null 2>&1; then
        # Check if durable extension is available
        if docker exec $CONTAINER_NAME psql -U postgres -c "SELECT durable.version();" &>/dev/null 2>&1; then
            # Check if background worker has fully started (after init restart)
            if docker logs $CONTAINER_NAME 2>&1 | grep -q "duroxide runtime started, processing"; then
                # Make sure we're past the init phase (look for the final startup)
                if docker logs $CONTAINER_NAME 2>&1 | grep -q "PostgreSQL init process complete"; then
                    echo -e " ${GREEN}Ready!${NC}"
                    READY=true
                    break
                fi
            fi
        fi
    fi
    echo -n "."
    sleep 1
done

if [ "$READY" != "true" ]; then
    echo -e " ${RED}TIMEOUT${NC}"
    echo "Container logs:"
    docker logs $CONTAINER_NAME 2>&1 | tail -40
    exit 1
fi

echo ""

# 4. Run test cases
PASSED=0
FAILED=0
SKIPPED=0

for test_file in "$SQL_DIR"/*.sql; do
    [ -f "$test_file" ] || continue
    
    test_name=$(basename "$test_file" .sql)
    echo -n "  $test_name ... "
    
    # Run the test
    output=$(docker exec -i $CONTAINER_NAME psql -U postgres -v ON_ERROR_STOP=1 < "$test_file" 2>&1)
    exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # Check for explicit PASS/FAIL in output
        if echo "$output" | grep -q "TEST PASSED"; then
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
        elif echo "$output" | grep -q "TEST FAILED"; then
            echo -e "${RED}FAIL${NC}"
            echo "$output" | grep -A5 "TEST FAILED" | head -10
            ((FAILED++))
        else
            # No explicit marker, assume pass
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        echo "$output" | tail -10
        ((FAILED++))
    fi
done

echo ""
echo "================================================"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "================================================"

[ $FAILED -eq 0 ]

