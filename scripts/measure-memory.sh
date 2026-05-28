#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

# measure-memory.sh - Measure duroxide runtime memory and CPU consumption
#
# Creates 10 long-running durable functions with staggered starts (5s apart).
# Each function: sleeps 30s -> runs a few queries -> repeats.
# Monitors memory (RSS) and CPU of the background worker for 2 minutes.
#
# Usage: ./scripts/measure-memory.sh
#
# Prerequisites: PostgreSQL with pg_durable must be running
# Start with: ./scripts/pg-start.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
NUM_FUNCTIONS=10
STAGGER_DELAY=5          # seconds between function starts
MONITOR_DURATION=120     # 2 minutes
SAMPLE_INTERVAL=1        # sample every 1 second

# pgrx settings
PGRX_HOME="$HOME/.pgrx"
PG_VERSION="17"
PG_PORT="28817"
PG_DB="postgres"

# Find pgrx binaries
PGRX_BIN=$(ls -d $PGRX_HOME/$PG_VERSION.*/pgrx-install/bin 2>/dev/null | head -1)
if [ -z "$PGRX_BIN" ]; then
    echo "Error: pgrx PostgreSQL $PG_VERSION not installed"
    exit 1
fi

PSQL="$PGRX_BIN/psql"
PG_ISREADY="$PGRX_BIN/pg_isready"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Check if PostgreSQL is running
if ! "$PG_ISREADY" -h localhost -p $PG_PORT -U postgres &>/dev/null; then
    echo -e "${RED}Error: PostgreSQL is not running on port $PG_PORT${NC}"
    echo "Start with: ./scripts/pg-start.sh"
    exit 1
fi

echo "========================================================"
echo -e "${BOLD}pg_durable Memory & CPU Measurement${NC}"
echo "========================================================"
echo ""
echo -e "Configuration:"
echo -e "  Functions:        ${CYAN}$NUM_FUNCTIONS${NC}"
echo -e "  Stagger delay:    ${CYAN}${STAGGER_DELAY}s${NC}"
echo -e "  Monitor duration: ${CYAN}${MONITOR_DURATION}s (2 min)${NC}"
echo -e "  Sample interval:  ${CYAN}${SAMPLE_INTERVAL}s${NC}"
echo ""

# Create measurement tables
echo -e "${YELLOW}Setting up measurement tables...${NC}"
"$PSQL" -h localhost -p $PG_PORT -U postgres -d $PG_DB -q <<'EOF'
-- Cleanup from previous runs
DROP TABLE IF EXISTS measure_instances CASCADE;
DROP TABLE IF EXISTS measure_work_log CASCADE;

-- Track instances
CREATE TABLE measure_instances (
    id SERIAL PRIMARY KEY,
    instance_id TEXT NOT NULL,
    started_at TIMESTAMP DEFAULT now()
);

-- Track work done by durable functions
CREATE TABLE measure_work_log (
    id SERIAL PRIMARY KEY,
    instance_num INT,
    iteration INT,
    ts TIMESTAMP DEFAULT now()
);
EOF

# Find the background worker PID
find_worker_pid() {
    # Look for the pg_durable background worker process
    pgrep -f "postgres.*pg_durable" | head -1
}

# Calculate percentile from sorted array (pass values, not array name)
# Usage: P50_RSS=$(percentile 50 "${RSS_SORTED[@]}")
percentile() {
    local p=$1
    shift
    local values=("$@")
    local n=${#values[@]}
    if [ $n -eq 0 ]; then
        echo "0"
        return
    fi
    local idx=$(( (n * p + 99) / 100 - 1 ))
    [ $idx -lt 0 ] && idx=0
    [ $idx -ge $n ] && idx=$((n - 1))
    echo "${values[$idx]}"
}

# Start durable functions with staggered timing
echo -e "${YELLOW}Starting $NUM_FUNCTIONS durable functions (staggered by ${STAGGER_DELAY}s)...${NC}"

INSTANCE_IDS=()

for i in $(seq 1 $NUM_FUNCTIONS); do
    echo -ne "  Starting function $i/$NUM_FUNCTIONS..."
    
    # Each function: loop { sleep 30s -> insert log -> run a few queries }
    INSTANCE_ID=$("$PSQL" -h localhost -p $PG_PORT -d $PG_DB -t -A <<EOF
SELECT df.start(
    df.loop(
        df.sleep(30)
        ~> 'INSERT INTO measure_work_log (instance_num, iteration) 
            VALUES ($i, (SELECT COALESCE(MAX(iteration), 0) + 1 FROM measure_work_log WHERE instance_num = $i))'
        ~> 'SELECT pg_sleep(0.1), count(*) FROM measure_work_log'
        ~> 'SELECT pg_sleep(0.1), now(), pg_backend_pid()'
        ~> 'SELECT pg_sleep(0.1), version()'
    ),
    'measure-memory-$i'
);
EOF
)
    
    INSTANCE_IDS+=("$INSTANCE_ID")
    
    # Store instance ID
    "$PSQL" -h localhost -p $PG_PORT -d $PG_DB -q -c \
        "INSERT INTO measure_instances (instance_id) VALUES ('$INSTANCE_ID');"
    
    echo -e " ${GREEN}✓${NC} $INSTANCE_ID"
    
    # Stagger delay (except for last one)
    if [ $i -lt $NUM_FUNCTIONS ]; then
        sleep $STAGGER_DELAY
    fi
done

echo ""

# Find worker PID
WORKER_PID=$(find_worker_pid)
if [ -z "$WORKER_PID" ]; then
    echo -e "${RED}Error: Could not find pg_durable background worker process${NC}"
    echo "Try: pgrep -af postgres"
    exit 1
fi

echo -e "Found background worker PID: ${CYAN}$WORKER_PID${NC}"
echo ""

# Arrays to store measurements
declare -a RSS_SAMPLES
declare -a CPU_SAMPLES
declare -a VSZ_SAMPLES

RESULTS_FILE=$(mktemp)
echo "timestamp,rss_kb,vsz_kb,cpu_percent" > "$RESULTS_FILE"

echo -e "${YELLOW}Monitoring for $MONITOR_DURATION seconds...${NC}"
echo ""
echo -e "${BOLD}Time     RSS (MB)    VSZ (MB)    CPU%${NC}"
echo "----------------------------------------"

START_TIME=$(date +%s)
SAMPLE_COUNT=0

# Previous CPU values for calculating usage
PREV_UTIME=0
PREV_STIME=0
PREV_TIME=$(python3 -c "import time; print(time.time())")

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED -ge $MONITOR_DURATION ]; then
        break
    fi
    
    # Check if worker still exists
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
        echo -e "\n${RED}Worker process $WORKER_PID no longer exists${NC}"
        break
    fi
    
    # Get memory stats from ps (works on macOS and Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: ps output in KB
        STATS=$(ps -o rss=,vsz=,%cpu= -p $WORKER_PID 2>/dev/null | head -1)
        RSS_KB=$(echo "$STATS" | awk '{print $1}')
        VSZ_KB=$(echo "$STATS" | awk '{print $2}')
        CPU_PERCENT=$(echo "$STATS" | awk '{print $3}')
    else
        # Linux: use /proc for more accurate data
        if [ -f "/proc/$WORKER_PID/stat" ]; then
            STATS=$(ps -o rss=,vsz=,%cpu= -p $WORKER_PID 2>/dev/null | head -1)
            RSS_KB=$(echo "$STATS" | awk '{print $1}')
            VSZ_KB=$(echo "$STATS" | awk '{print $2}')
            CPU_PERCENT=$(echo "$STATS" | awk '{print $3}')
        else
            continue
        fi
    fi
    
    # Validate we got numbers
    if [ -z "$RSS_KB" ] || [ -z "$VSZ_KB" ]; then
        sleep $SAMPLE_INTERVAL
        continue
    fi
    
    # Convert to integers for array storage (removing any decimals)
    RSS_INT=${RSS_KB%.*}
    VSZ_INT=${VSZ_KB%.*}
    CPU_INT=${CPU_PERCENT%.*}
    
    RSS_SAMPLES+=($RSS_INT)
    VSZ_SAMPLES+=($VSZ_INT)
    CPU_SAMPLES+=($CPU_INT)
    
    # Calculate MB for display
    RSS_MB=$(echo "scale=1; $RSS_KB / 1024" | bc)
    VSZ_MB=$(echo "scale=1; $VSZ_KB / 1024" | bc)
    
    # Log to CSV
    echo "$(date +%H:%M:%S),$RSS_KB,$VSZ_KB,$CPU_PERCENT" >> "$RESULTS_FILE"
    
    # Display progress every 10 seconds
    if [ $((ELAPSED % 10)) -eq 0 ]; then
        printf "%3ds      %-8s    %-8s    %s%%\n" "$ELAPSED" "$RSS_MB" "$VSZ_MB" "$CPU_PERCENT"
    fi
    
    SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
    sleep $SAMPLE_INTERVAL
done

echo "----------------------------------------"
echo ""

# Calculate statistics
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}          MEASUREMENT RESULTS           ${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# Sort arrays for percentile calculation
RSS_SORTED=($(printf '%s\n' "${RSS_SAMPLES[@]}" | sort -n))
VSZ_SORTED=($(printf '%s\n' "${VSZ_SAMPLES[@]}" | sort -n))
CPU_SORTED=($(printf '%s\n' "${CPU_SAMPLES[@]}" | sort -n))

# Get array lengths
RSS_LEN=${#RSS_SORTED[@]}
VSZ_LEN=${#VSZ_SORTED[@]}
CPU_LEN=${#CPU_SORTED[@]}

# Get max values (last element)
if [ $RSS_LEN -gt 0 ]; then
    RSS_MAX=${RSS_SORTED[$((RSS_LEN-1))]}
    RSS_MIN=${RSS_SORTED[0]}
else
    RSS_MAX=0
    RSS_MIN=0
fi

if [ $VSZ_LEN -gt 0 ]; then
    VSZ_MAX=${VSZ_SORTED[$((VSZ_LEN-1))]}
    VSZ_MIN=${VSZ_SORTED[0]}
else
    VSZ_MAX=0
    VSZ_MIN=0
fi

if [ $CPU_LEN -gt 0 ]; then
    CPU_MAX=${CPU_SORTED[$((CPU_LEN-1))]}
    CPU_MIN=${CPU_SORTED[0]}
else
    CPU_MAX=0
    CPU_MIN=0
fi

# Get P50 values
RSS_P50=$(percentile 50 "${RSS_SORTED[@]}")
VSZ_P50=$(percentile 50 "${VSZ_SORTED[@]}")
CPU_P50=$(percentile 50 "${CPU_SORTED[@]}")

# Convert to MB for display
RSS_MAX_MB=$(echo "scale=2; $RSS_MAX / 1024" | bc)
RSS_P50_MB=$(echo "scale=2; $RSS_P50 / 1024" | bc)
RSS_MIN_MB=$(echo "scale=2; $RSS_MIN / 1024" | bc)
VSZ_MAX_MB=$(echo "scale=2; $VSZ_MAX / 1024" | bc)
VSZ_P50_MB=$(echo "scale=2; $VSZ_P50 / 1024" | bc)

echo -e "${CYAN}Memory (RSS - Resident Set Size):${NC}"
echo -e "  Max:    ${BOLD}${RSS_MAX_MB} MB${NC}  ($RSS_MAX KB)"
echo -e "  P50:    ${BOLD}${RSS_P50_MB} MB${NC}  ($RSS_P50 KB)"
echo -e "  Min:    ${RSS_MIN_MB} MB  ($RSS_MIN KB)"
echo ""

echo -e "${CYAN}Memory (VSZ - Virtual Size):${NC}"
echo -e "  Max:    ${BOLD}${VSZ_MAX_MB} MB${NC}  ($VSZ_MAX KB)"
echo -e "  P50:    ${BOLD}${VSZ_P50_MB} MB${NC}  ($VSZ_P50 KB)"
echo ""

echo -e "${CYAN}CPU Usage:${NC}"
echo -e "  Max:    ${BOLD}${CPU_MAX}%${NC}"
echo -e "  P50:    ${BOLD}${CPU_P50}%${NC}"
echo -e "  Min:    ${CPU_MIN}%"
echo ""

echo -e "${CYAN}Sampling:${NC}"
echo -e "  Duration:    $MONITOR_DURATION seconds"
echo -e "  Samples:     $SAMPLE_COUNT"
echo -e "  Worker PID:  $WORKER_PID"
echo ""

# Check work log
WORK_COUNT=$("$PSQL" -h localhost -p $PG_PORT -d $PG_DB -t -A -c \
    "SELECT COUNT(*) FROM measure_work_log;")
echo -e "${CYAN}Durable Function Activity:${NC}"
echo -e "  Iterations completed: $WORK_COUNT"
echo ""

# Show running instances
echo -e "${CYAN}Instance Status:${NC}"
"$PSQL" -h localhost -p $PG_PORT -d $PG_DB -c \
    "SELECT m.id, LEFT(m.instance_id, 20) as instance, df.status(m.instance_id) as status
     FROM measure_instances m ORDER BY m.id;"
echo ""

# Save detailed results
FINAL_RESULTS="$PROJECT_DIR/memory-measurement-$(date +%Y%m%d-%H%M%S).csv"
cp "$RESULTS_FILE" "$FINAL_RESULTS"
echo -e "Detailed results saved to: ${GREEN}$FINAL_RESULTS${NC}"
echo ""

# Cleanup prompt
echo -e "${YELLOW}Cleanup options:${NC}"
echo "  Cancel all functions:  Run the SQL below"
echo ""
echo "  -- Cancel all measurement functions"
echo "  SELECT df.cancel(instance_id, 'measurement complete')"
echo "  FROM measure_instances;"
echo ""
echo "  -- Or keep them running to continue observing memory"

rm -f "$RESULTS_FILE"

echo ""
echo -e "${GREEN}Done!${NC}"
