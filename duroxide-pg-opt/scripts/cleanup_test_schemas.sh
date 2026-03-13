#!/usr/bin/env bash
# Clean up all test schemas from the PostgreSQL database
# Usage: ./scripts/cleanup_test_schemas.sh

set -e

# Load .env file if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Check if DATABASE_URL is set
if [ -z "$DATABASE_URL" ]; then
    echo "Error: DATABASE_URL is not set. Please set it in your environment or .env file."
    exit 1
fi

# Extract connection details from DATABASE_URL
# Format: postgresql://user:password@host:port/database
DB_URL="$DATABASE_URL"

echo "Connecting to database and cleaning up test schemas..."

# Use psql to drop all test schemas
psql "$DB_URL" <<EOF
-- Drop all test schemas matching patterns
DO \$\$
DECLARE
    schema_name TEXT;
BEGIN
    -- Drop e2e_test schemas
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname = 'e2e_test' OR nspname LIKE 'e2e_test_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
    
    -- Drop validation_test schemas
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname LIKE 'validation_test_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
    
    -- Drop test_ schemas (but not test schemas that might be legitimate)
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname LIKE 'test_%' AND nspname != 'test'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
    
    -- Drop stress_test schemas
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname LIKE 'stress_test_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
    
    -- Drop timing_test schemas (from performance analysis examples)
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname LIKE 'timing_test_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
    
    -- Drop regression_test schemas
    FOR schema_name IN 
        SELECT nspname FROM pg_namespace 
        WHERE nspname LIKE 'regression_test_%'
    LOOP
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', schema_name);
        RAISE NOTICE 'Dropped schema: %', schema_name;
    END LOOP;
END \$\$;

-- Show remaining test schemas (if any)
SELECT 
    COUNT(*) as remaining_test_schemas,
    string_agg(nspname, ', ' ORDER BY nspname) as schema_names
FROM pg_namespace 
WHERE nspname = 'e2e_test' 
   OR nspname LIKE 'e2e_test_%' 
   OR nspname LIKE 'validation_test_%'
   OR nspname LIKE 'stress_test_%'
   OR nspname LIKE 'timing_test_%'
   OR nspname LIKE 'regression_test_%'
   OR (nspname LIKE 'test_%' AND nspname != 'test');
EOF

echo ""
echo "Cleanup complete!"

