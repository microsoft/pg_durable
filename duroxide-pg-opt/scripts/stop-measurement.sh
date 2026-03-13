#!/bin/bash
# Stop performance measurement and display pg_stat_statements results

set -e

DATABASE_URL=${DATABASE_URL:-$(grep '^DATABASE_URL=' .env 2>/dev/null | cut -d= -f2-)}

if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL not set"
    echo "Set DATABASE_URL environment variable or in .env file"
    exit 1
fi

echo "=== Performance Measurement Results ==="
echo "Database: $(echo $DATABASE_URL | sed 's/:.*@/:***@/')"
echo ""

# Query pg_stat_statements for stored procedure statistics
echo "📈 Server-Side Execution Times (from pg_stat_statements):"
echo ""

psql "$DATABASE_URL" -c "
-- Aggregate stats across all schemas for each procedure type
SELECT 
    CASE 
        WHEN query LIKE '%fetch_orchestration_item(%' THEN 'fetch_orchestration_item'
        WHEN query LIKE '%ack_orchestration_item(%' THEN 'ack_orchestration_item'  
        WHEN query LIKE '%fetch_work_item(%' THEN 'fetch_work_item'
        WHEN query LIKE '%ack_worker(%' THEN 'ack_worker'
        WHEN query LIKE '%enqueue_orchestrator_work(%' THEN 'enqueue_orchestrator'
        WHEN query LIKE '%fetch_history(%' AND query NOT LIKE '%with_execution%' THEN 'fetch_history'
        WHEN query LIKE '%fetch_history_with_execution(%' THEN 'fetch_history_exec'
        WHEN query LIKE '%append_history(%' THEN 'append_history'
    END as procedure_name,
    SUM(calls)::BIGINT as \"Calls\",
    ROUND(AVG(mean_exec_time)::numeric, 2) as \"Avg (ms)\",
    ROUND(MIN(min_exec_time)::numeric, 2) as \"Min (ms)\",
    ROUND(MAX(max_exec_time)::numeric, 2) as \"Max (ms)\"
FROM pg_stat_statements
WHERE query LIKE 'SELECT%'
  AND (
       query LIKE '%fetch_orchestration_item(%'
    OR query LIKE '%ack_orchestration_item(%'
    OR query LIKE '%fetch_work_item(%'
    OR query LIKE '%ack_worker(%'
    OR query LIKE '%enqueue_orchestrator_work(%'
    OR query LIKE '%fetch_history(%'
    OR query LIKE '%append_history(%'
  )
GROUP BY procedure_name
ORDER BY \"Calls\" DESC;
"

echo ""
echo "=== Network Overhead Analysis ==="
echo ""
echo "Server-side times shown above are PURE execution time on PostgreSQL."
echo "Compare to client elapsed times from stress test logs:"
echo ""
echo "  • West US region: Client elapsed ~70ms"
echo "  • Other regions: Client elapsed ~150ms"
echo ""
echo "Network overhead = Client elapsed - Server execution"
echo ""
echo "Example: If server shows 5ms and client shows 70ms:"
echo "  → Network RTT overhead = 65ms (93% of total time)"
echo ""

