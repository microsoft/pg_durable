-- Test: Worker Restart After Drop
-- Tests that:
-- 1. After DROP EXTENSION CASCADE, worker waits for extension recreation
-- 2. Worker detects recreated extension and reinitializes
-- 3. System becomes operational again without PostgreSQL restart
-- 4. Multiple drop-recreate cycles work correctly

-- This test verifies the worker's ability to handle multiple create-drop-create cycles

-- Phase 1: Initial state - extension should exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_durable') THEN
        RAISE EXCEPTION 'TEST FAILED: Extension should exist at test start';
    END IF;
    RAISE NOTICE 'PASS: Initial extension exists';
END $$;

-- Phase 2: First extension drop-create cycle
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
-- Wait for worker to initialize duroxide-pg tables
DO $$
DECLARE
    table_count INT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Drop-create cycle 1';
    LOOP
        SELECT COUNT(*) INTO table_count
        FROM pg_tables 
        WHERE schemaname = 'duroxide' 
        AND tablename IN ('executions', 'instances', 'history', 'orchestrator_queue', 'worker_queue');
        
        EXIT WHEN table_count = 5 OR attempts > 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF table_count != 5 THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 1): Worker did not initialize duroxide-pg, found % of 5 expected tables', table_count;
    END IF;
    
    RAISE NOTICE 'PASS: Worker initialized duroxide-pg after cycle 1';
END $$;

-- Verify operational with a simple durable function
CREATE TEMP TABLE _cycle1_state (instance_id TEXT);
INSERT INTO _cycle1_state 
SELECT df.start('SELECT 1 as cycle1_test', 'test-worker-restart-cycle1');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cycle1_state;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 1): Worker not operational, status = %', status;
    END IF;
    RAISE NOTICE 'PASS: Worker operational after cycle 1';
END $$;

DROP TABLE _cycle1_state;

-- Phase 3: Second extension drop-create cycle
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
-- Wait for worker to initialize duroxide-pg tables
DO $$
DECLARE
    table_count INT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Drop-create cycle 2';
    LOOP
        SELECT COUNT(*) INTO table_count
        FROM pg_tables 
        WHERE schemaname = 'duroxide' 
        AND tablename IN ('executions', 'instances', 'history', 'orchestrator_queue', 'worker_queue');
        
        EXIT WHEN table_count = 5 OR attempts > 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF table_count != 5 THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 2): Worker did not initialize duroxide-pg, found % of 5 expected tables', table_count;
    END IF;
    
    RAISE NOTICE 'PASS: Worker initialized duroxide-pg after cycle 2';
END $$;

-- Verify operational again
CREATE TEMP TABLE _cycle2_state (instance_id TEXT);
INSERT INTO _cycle2_state 
SELECT df.start('SELECT 2 as cycle2_test', 'test-worker-restart-cycle2');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cycle2_state;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 2): Worker not operational, status = %', status;
    END IF;
    RAISE NOTICE 'PASS: Worker operational after cycle 2';
END $$;

DROP TABLE _cycle2_state;

-- Phase 4: Third extension drop-create cycle (to really prove it can handle multiple cycles)
DROP EXTENSION IF EXISTS pg_durable CASCADE;
CREATE EXTENSION pg_durable;
-- Wait for worker to initialize duroxide-pg tables
DO $$
DECLARE
    table_count INT;
    attempts INT := 0;
BEGIN
    RAISE NOTICE 'Drop-create cycle 3';
    LOOP
        SELECT COUNT(*) INTO table_count
        FROM pg_tables 
        WHERE schemaname = 'duroxide' 
        AND tablename IN ('executions', 'instances', 'history', 'orchestrator_queue', 'worker_queue');
        
        EXIT WHEN table_count = 5 OR attempts > 150;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF table_count != 5 THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 3): Worker did not initialize duroxide-pg, found % of 5 expected tables', table_count;
    END IF;
    
    RAISE NOTICE 'PASS: Worker initialized duroxide-pg after cycle 3';
END $$;

-- Verify operational one more time
CREATE TEMP TABLE _cycle3_state (instance_id TEXT);
INSERT INTO _cycle3_state 
SELECT df.start('SELECT 3 as cycle3_test', 'test-worker-restart-cycle3');

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _cycle3_state;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (cycle 3): Worker not operational, status = %', status;
    END IF;
    RAISE NOTICE 'PASS: Worker operational after cycle 3';
END $$;

DROP TABLE _cycle3_state;

SELECT 'TEST PASSED: Worker restart after multiple drop-create cycles verified' AS result;
