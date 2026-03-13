#!/bin/bash
# Measure server-side performance using pg_stat_statements
# This script runs stress tests and compares server execution time vs network RTT

set -e

DURATION=5
TRACK=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --track)
            TRACK=true
            shift
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        *)
            DURATION="$1"
            shift
            ;;
    esac
done

DATABASE_URL=${DATABASE_URL:-$(grep '^DATABASE_URL=' .env 2>/dev/null | cut -d= -f2-)}

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set"
    echo "Usage: $0 [DURATION_SECS] [--track]"
    echo "       $0 --duration 10 --track"
    echo "Set DATABASE_URL environment variable or in .env file"
    exit 1
fi

# Extract hostname for result tracking
HOSTNAME=$(echo "$DATABASE_URL" | sed -E 's/.*@([^:]+).*/\1/' | cut -d. -f1)

echo "=== PostgreSQL Server-Side Performance Measurement ==="
echo "Duration: ${DURATION}s"
echo "Database: $(echo $DATABASE_URL | sed 's/:.*@/:***@/')"
echo "Hostname: $HOSTNAME"
if [ "$TRACK" = true ]; then
    echo "Tracking: Enabled (will save to performance-results-${HOSTNAME}.md)"
fi
echo ""

# Start measurement
./scripts/start-measurement.sh

# Run stress test
echo "🚀 Running stress test..."
echo ""
cd pg-stress
RUST_LOG=info cargo run --release --bin pg-stress -- --duration $DURATION 2>&1 | grep -E "(Hostname|Config|Completed|Throughput|Latency|PostgreSQL.*:)"
STRESS_OUTPUT=$(RUST_LOG=info cargo run --release --bin pg-stress -- --duration $DURATION 2>&1)
cd ..
echo ""

# Stop measurement and show results
./scripts/stop-measurement.sh

# Track results if requested
if [ "$TRACK" = true ]; then
    RESULTS_FILE="pg-stress/performance-results-${HOSTNAME}.md"
    
    echo ""
    echo "📝 Tracking results to $RESULTS_FILE..."
    
    # Get git info
    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    
    # Capture server-side stats
    SERVER_STATS=$(./scripts/stop-measurement.sh 2>&1 | grep -A 20 "Server-Side Execution")
    
    # Append to results file
    {
        echo ""
        echo "## Run: $DATE"
        echo ""
        echo "- **Commit**: \`$COMMIT\` (branch: \`$BRANCH\`)"
        echo "- **Duration**: ${DURATION}s"
        echo "- **Hostname**: $HOSTNAME"
        echo ""
        echo "### Stress Test Results"
        echo ""
        echo "\`\`\`"
        echo "$STRESS_OUTPUT" | grep -A 10 "=== Comparison Table ==="
        echo "\`\`\`"
        echo ""
        echo "### Server-Side Execution Times"
        echo ""
        echo "\`\`\`"
        echo "$SERVER_STATS"
        echo "\`\`\`"
        echo ""
        echo "---"
    } >> "$RESULTS_FILE"
    
    echo "   ✓ Results saved to $RESULTS_FILE"
fi

echo ""
echo "✅ Measurement complete"
echo ""
