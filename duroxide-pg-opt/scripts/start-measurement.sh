#!/bin/bash
# Start performance measurement by resetting pg_stat_statements

set -e

DATABASE_URL=${DATABASE_URL:-$(grep '^DATABASE_URL=' .env 2>/dev/null | cut -d= -f2-)}

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set"
    echo "Set DATABASE_URL environment variable or in .env file"
    exit 1
fi

echo "=== Starting Performance Measurement ==="
echo "Database: $(echo $DATABASE_URL | sed 's/:.*@/:***@/')"
echo ""

# Enable pg_stat_statements extension (idempotent)
echo "📊 Enabling pg_stat_statements extension..."
psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" 2>&1 | grep -v "already exists" || true
echo "   ✓ Extension enabled"
echo ""

# Reset statistics for clean baseline
echo "🧹 Resetting pg_stat_statements..."
RESET_RESULT=$(psql "$DATABASE_URL" -t -c "SELECT pg_stat_statements_reset();" 2>&1)
if [ $? -eq 0 ]; then
    echo "   ✓ Statistics reset"
else
    echo "   ✗ Failed to reset statistics"
    echo "   Error: $RESET_RESULT"
    exit 1
fi

echo ""
echo "✅ Measurement started. Statistics are now being tracked."
echo ""
echo "Now run your tests, queries, or workloads."
echo "When done, run: ./scripts/stop-measurement.sh"
echo ""

