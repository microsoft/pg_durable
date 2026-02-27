-- Migration: 0001_initial_schema.sql
-- Description: Complete Duroxide PostgreSQL provider schema
-- All tables, indexes, and stored procedures in a single migration.
-- All timestamps are NOT NULL without defaults - provider must supply values.

-- ============================================================================
-- Tables
-- ============================================================================

-- Instance metadata
CREATE TABLE IF NOT EXISTS instances (
    instance_id TEXT PRIMARY KEY,
    orchestration_name TEXT NOT NULL,
    orchestration_version TEXT, -- NULLable, set by runtime via ack_orchestration_item metadata
    current_execution_id BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

-- Multi-execution support
CREATE TABLE IF NOT EXISTS executions (
    instance_id TEXT NOT NULL,
    execution_id BIGINT NOT NULL,
    status TEXT NOT NULL DEFAULT 'Running',
    output TEXT,
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ, -- NULL until completed/failed
    PRIMARY KEY (instance_id, execution_id)
);

-- Event history (append-only)
CREATE TABLE IF NOT EXISTS history (
    instance_id TEXT NOT NULL,
    execution_id BIGINT NOT NULL,
    event_id BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    event_data TEXT NOT NULL, -- JSON serialized Event
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (instance_id, execution_id, event_id)
);

-- Orchestrator queue
CREATE TABLE IF NOT EXISTS orchestrator_queue (
    id BIGSERIAL PRIMARY KEY,
    instance_id TEXT NOT NULL,
    work_item TEXT NOT NULL, -- JSON serialized WorkItem
    visible_at TIMESTAMPTZ NOT NULL,
    lock_token TEXT,
    locked_until BIGINT, -- Unix timestamp in milliseconds
    created_at TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0
);

-- Worker queue
CREATE TABLE IF NOT EXISTS worker_queue (
    id BIGSERIAL PRIMARY KEY,
    work_item TEXT NOT NULL, -- JSON serialized WorkItem
    visible_at TIMESTAMPTZ NOT NULL, -- When the item becomes available for processing
    lock_token TEXT,
    locked_until BIGINT, -- Unix timestamp in milliseconds
    created_at TIMESTAMPTZ NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0
);

-- Instance-level locks for concurrent dispatcher coordination
CREATE TABLE IF NOT EXISTS instance_locks (
    instance_id TEXT PRIMARY KEY,
    lock_token TEXT NOT NULL,
    locked_until BIGINT NOT NULL, -- Unix timestamp in milliseconds
    locked_at BIGINT NOT NULL -- Unix timestamp in milliseconds
);

-- ============================================================================
-- Indexes
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_orch_visible ON orchestrator_queue(visible_at, lock_token);
CREATE INDEX IF NOT EXISTS idx_orch_instance ON orchestrator_queue(instance_id);
CREATE INDEX IF NOT EXISTS idx_orch_lock ON orchestrator_queue(lock_token);
CREATE INDEX IF NOT EXISTS idx_worker_visible ON worker_queue(visible_at, lock_token);
CREATE INDEX IF NOT EXISTS idx_worker_available ON worker_queue(lock_token, id);
CREATE INDEX IF NOT EXISTS idx_instance_locks_locked_until ON instance_locks(locked_until);
CREATE INDEX IF NOT EXISTS idx_history_lookup ON history(instance_id, execution_id, event_id);

-- Migration tracking table (create in each schema)
CREATE TABLE IF NOT EXISTS _duroxide_migrations (
    version BIGINT PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- NOTIFY Triggers for Long-Polling
-- Triggers fire on INSERT to notify waiting dispatchers of new work.
-- Payload contains visible_at as epoch milliseconds for timer scheduling.
-- NOTE: We use TG_TABLE_SCHEMA (the schema of the table being modified) 
-- instead of current_schema() because current_schema() returns the first 
-- schema in the session's search_path, which may not be our schema.
-- ============================================================================

-- Trigger function for orchestrator queue
DROP FUNCTION IF EXISTS notify_orch_work() CASCADE;
CREATE OR REPLACE FUNCTION notify_orch_work()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '_orch_work',
        (EXTRACT(EPOCH FROM NEW.visible_at) * 1000)::BIGINT::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger function for worker queue
-- Worker queue items now have visible_at for delayed visibility
-- Send visible_at timestamp for timer scheduling
DROP FUNCTION IF EXISTS notify_worker_work() CASCADE;
CREATE OR REPLACE FUNCTION notify_worker_work()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '_worker_work',
        (EXTRACT(EPOCH FROM NEW.visible_at) * 1000)::BIGINT::TEXT
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach triggers to queues
DROP TRIGGER IF EXISTS trg_notify_orch_work ON orchestrator_queue;
CREATE TRIGGER trg_notify_orch_work
    AFTER INSERT ON orchestrator_queue
    FOR EACH ROW
    EXECUTE FUNCTION notify_orch_work();

DROP TRIGGER IF EXISTS trg_notify_worker_work ON worker_queue;
CREATE TRIGGER trg_notify_worker_work
    AFTER INSERT ON worker_queue
    FOR EACH ROW
    EXECUTE FUNCTION notify_worker_work();

-- ============================================================================
-- Stored Procedures
-- ============================================================================

DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- ============================================================================
    -- Schema Management Procedures
    -- ============================================================================

    -- Procedure: cleanup_schema
    -- Drops all tables AND functions in the schema (for testing only)
    -- Functions must be dropped because PostgreSQL cannot change return types with CREATE OR REPLACE
    EXECUTE format('DROP FUNCTION IF EXISTS %I.cleanup_schema()', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.cleanup_schema()
        RETURNS VOID AS $cleanup$
        BEGIN
            -- Drop tables first
            DROP TABLE IF EXISTS %I.instances CASCADE;
            DROP TABLE IF EXISTS %I.executions CASCADE;
            DROP TABLE IF EXISTS %I.history CASCADE;
            DROP TABLE IF EXISTS %I.orchestrator_queue CASCADE;
            DROP TABLE IF EXISTS %I.worker_queue CASCADE;
            DROP TABLE IF EXISTS %I.instance_locks CASCADE;
            DROP TABLE IF EXISTS %I._duroxide_migrations CASCADE;
            
            -- Drop all stored procedures (required because return type changes cannot use CREATE OR REPLACE)
            DROP FUNCTION IF EXISTS %I.cleanup_schema();
            DROP FUNCTION IF EXISTS %I.list_instances();
            DROP FUNCTION IF EXISTS %I.list_executions(TEXT);
            DROP FUNCTION IF EXISTS %I.latest_execution_id(TEXT);
            DROP FUNCTION IF EXISTS %I.list_instances_by_status(TEXT);
            DROP FUNCTION IF EXISTS %I.get_instance_info(TEXT);
            DROP FUNCTION IF EXISTS %I.get_execution_info(TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.get_system_metrics();
            DROP FUNCTION IF EXISTS %I.get_queue_depths(BIGINT);
            DROP FUNCTION IF EXISTS %I.enqueue_worker_work(TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.ack_worker(TEXT, TEXT, TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.renew_work_item_lock(TEXT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_work_item(BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.abandon_work_item(TEXT, BIGINT, BIGINT, BOOLEAN);
            DROP FUNCTION IF EXISTS %I.enqueue_orchestrator_work(TEXT, TEXT, TIMESTAMPTZ, BIGINT, TEXT, TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_orchestration_item(BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.ack_orchestration_item(TEXT, BIGINT, BIGINT, JSONB, JSONB, JSONB, JSONB, JSONB);
            DROP FUNCTION IF EXISTS %I.abandon_orchestration_item(TEXT, BIGINT, BIGINT, BOOLEAN);
            DROP FUNCTION IF EXISTS %I.renew_orchestration_item_lock(TEXT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_history(TEXT);
            DROP FUNCTION IF EXISTS %I.fetch_history_with_execution(TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.append_history(TEXT, BIGINT, JSONB, BIGINT);
            
            -- Drop trigger functions (not schema-qualified, they use search_path)
            -- CASCADE is required because triggers depend on these functions
            DROP FUNCTION IF EXISTS notify_orch_work() CASCADE;
            DROP FUNCTION IF EXISTS notify_worker_work() CASCADE;
        END;
        $cleanup$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name);

    -- ============================================================================
    -- Simple Query Procedures
    -- ============================================================================

    -- Procedure: list_instances
    EXECUTE format('DROP FUNCTION IF EXISTS %I.list_instances()', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.list_instances()
        RETURNS TABLE(instance_id TEXT) AS $list_inst$
        BEGIN
            RETURN QUERY
            SELECT i.instance_id
            FROM %I.instances i
            ORDER BY i.created_at DESC;
        END;
        $list_inst$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: list_executions
    EXECUTE format('DROP FUNCTION IF EXISTS %I.list_executions(TEXT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.list_executions(p_instance_id TEXT)
        RETURNS TABLE(execution_id BIGINT) AS $list_exec$
        BEGIN
            RETURN QUERY
            SELECT e.execution_id
            FROM %I.executions e
            WHERE e.instance_id = p_instance_id
            ORDER BY e.execution_id;
        END;
        $list_exec$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: latest_execution_id
    EXECUTE format('DROP FUNCTION IF EXISTS %I.latest_execution_id(TEXT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.latest_execution_id(p_instance_id TEXT)
        RETURNS BIGINT AS $latest_exec$
        DECLARE
            v_execution_id BIGINT;
        BEGIN
            SELECT i.current_execution_id INTO v_execution_id
            FROM %I.instances i
            WHERE i.instance_id = p_instance_id;
            RETURN v_execution_id;
        END;
        $latest_exec$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: list_instances_by_status
    EXECUTE format('DROP FUNCTION IF EXISTS %I.list_instances_by_status(TEXT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.list_instances_by_status(p_status TEXT)
        RETURNS TABLE(instance_id TEXT) AS $list_by_status$
        BEGIN
            RETURN QUERY
            SELECT i.instance_id
            FROM %I.instances i
            JOIN %I.executions e ON i.instance_id = e.instance_id 
              AND i.current_execution_id = e.execution_id
            WHERE e.status = p_status
            ORDER BY i.created_at DESC;
        END;
        $list_by_status$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Join and Aggregate Query Procedures
    -- ============================================================================

    -- Procedure: get_instance_info
    EXECUTE format('DROP FUNCTION IF EXISTS %I.get_instance_info(TEXT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.get_instance_info(p_instance_id TEXT)
        RETURNS TABLE(
            instance_id TEXT,
            orchestration_name TEXT,
            orchestration_version TEXT,
            current_execution_id BIGINT,
            created_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ,
            status TEXT,
            output TEXT
        ) AS $get_inst_info$
        BEGIN
            RETURN QUERY
            SELECT i.instance_id, i.orchestration_name, 
                   COALESCE(i.orchestration_version, ''unknown'') as orchestration_version,
                   i.current_execution_id, i.created_at, i.updated_at,
                   e.status, e.output
            FROM %I.instances i
            LEFT JOIN %I.executions e ON i.instance_id = e.instance_id 
              AND i.current_execution_id = e.execution_id
            WHERE i.instance_id = p_instance_id;
        END;
        $get_inst_info$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: get_execution_info
    EXECUTE format('DROP FUNCTION IF EXISTS %I.get_execution_info(TEXT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.get_execution_info(
            p_instance_id TEXT,
            p_execution_id BIGINT
        )
        RETURNS TABLE(
            execution_id BIGINT,
            status TEXT,
            output TEXT,
            started_at TIMESTAMPTZ,
            completed_at TIMESTAMPTZ,
            event_count BIGINT
        ) AS $get_exec_info$
        BEGIN
            RETURN QUERY
            SELECT e.execution_id, e.status, e.output, 
                   e.started_at, e.completed_at,
                   COALESCE(COUNT(h.event_id), 0)::BIGINT as event_count
            FROM %I.executions e
            LEFT JOIN %I.history h ON e.instance_id = h.instance_id 
              AND e.execution_id = h.execution_id
            WHERE e.instance_id = p_instance_id AND e.execution_id = p_execution_id
            GROUP BY e.execution_id, e.status, e.output, e.started_at, e.completed_at;
        END;
        $get_exec_info$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: get_system_metrics
    EXECUTE format('DROP FUNCTION IF EXISTS %I.get_system_metrics()', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.get_system_metrics()
        RETURNS TABLE(
            total_instances BIGINT,
            total_executions BIGINT,
            running_instances BIGINT,
            completed_instances BIGINT,
            failed_instances BIGINT,
            total_events BIGINT
        ) AS $get_metrics$
        BEGIN
            RETURN QUERY
            SELECT 
                (SELECT COUNT(*)::BIGINT FROM %I.instances) as total_instances,
                (SELECT COUNT(*)::BIGINT FROM %I.executions) as total_executions,
                (SELECT COUNT(DISTINCT i.instance_id)::BIGINT
                 FROM %I.instances i
                 JOIN %I.executions e ON i.instance_id = e.instance_id 
                   AND i.current_execution_id = e.execution_id
                 WHERE e.status = ''Running'') as running_instances,
                (SELECT COUNT(DISTINCT i.instance_id)::BIGINT
                 FROM %I.instances i
                 JOIN %I.executions e ON i.instance_id = e.instance_id 
                   AND i.current_execution_id = e.execution_id
                 WHERE e.status = ''Completed'') as completed_instances,
                (SELECT COUNT(DISTINCT i.instance_id)::BIGINT
                 FROM %I.instances i
                 JOIN %I.executions e ON i.instance_id = e.instance_id 
                   AND i.current_execution_id = e.execution_id
                 WHERE e.status = ''Failed'') as failed_instances,
                (SELECT COUNT(*)::BIGINT FROM %I.history) as total_events;
        END;
        $get_metrics$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: get_queue_depths
    -- Returns count of items available for processing (visible and unlocked/lock expired)
    EXECUTE format('DROP FUNCTION IF EXISTS %I.get_queue_depths(BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.get_queue_depths(p_now_ms BIGINT)
        RETURNS TABLE(
            orchestrator_queue BIGINT,
            worker_queue BIGINT
        ) AS $get_queue_depths$
        BEGIN
            RETURN QUERY
            SELECT 
                (SELECT COUNT(*)::BIGINT FROM %I.orchestrator_queue 
                 WHERE visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                   AND (lock_token IS NULL OR locked_until <= p_now_ms)) as orchestrator_queue,
                (SELECT COUNT(*)::BIGINT FROM %I.worker_queue 
                 WHERE visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                   AND (lock_token IS NULL OR locked_until <= p_now_ms)) as worker_queue;
        END;
        $get_queue_depths$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Queue Operation Procedures
    -- All procedures accept p_now_ms for timestamp generation (Rust clock only)
    -- ============================================================================

    -- Procedure: enqueue_worker_work
    EXECUTE format('DROP FUNCTION IF EXISTS %I.enqueue_worker_work(TEXT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.enqueue_worker_work(
            p_work_item TEXT,
            p_now_ms BIGINT
        )
        RETURNS VOID AS $enq_worker$
        DECLARE
            v_now_ts TIMESTAMPTZ;
        BEGIN
            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);
            INSERT INTO %I.worker_queue (work_item, visible_at, created_at)
            VALUES (p_work_item, v_now_ts, v_now_ts);
        END;
        $enq_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: ack_worker
    -- When p_completion_json is NULL, only delete from worker_queue (no enqueue)
    -- This is used when the orchestration is terminal or missing
    EXECUTE format('DROP FUNCTION IF EXISTS %I.ack_worker(TEXT, TEXT, TEXT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.ack_worker(
            p_lock_token TEXT,
            p_instance_id TEXT,
            p_completion_json TEXT,
            p_now_ms BIGINT
        )
        RETURNS VOID AS $ack_worker$
        DECLARE
            v_rows_affected INTEGER;
            v_now_ts TIMESTAMPTZ;
        BEGIN
            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);
            
            DELETE FROM %I.worker_queue WHERE lock_token = p_lock_token;
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Worker queue item not found or already processed'';
            END IF;

            -- Validate: if completion provided, instance_id must also be provided
            IF p_completion_json IS NOT NULL AND p_instance_id IS NULL THEN
                RAISE EXCEPTION ''instance_id required when completion_json is provided'';
            END IF;

            -- Only enqueue completion if provided (not NULL)
            IF p_completion_json IS NOT NULL THEN
                INSERT INTO %I.orchestrator_queue (instance_id, work_item, visible_at, created_at)
                VALUES (p_instance_id, p_completion_json, v_now_ts, v_now_ts);
            END IF;
        END;
        $ack_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: renew_work_item_lock
    -- Returns execution_status for cancellation support
    -- Note: DROP first because return type changed from VOID to TEXT
    EXECUTE format('DROP FUNCTION IF EXISTS %I.renew_work_item_lock(TEXT, BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.renew_work_item_lock(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_extend_ms BIGINT
        )
        RETURNS TEXT AS $renew_lock$
        DECLARE
            v_rows_affected INTEGER;
            v_work_item_json JSONB;
            v_instance_id TEXT;
            v_execution_id BIGINT;
            v_execution_status TEXT;
        BEGIN
            -- Get the work item before updating
            SELECT work_item::JSONB INTO v_work_item_json
            FROM %I.worker_queue
            WHERE lock_token = p_lock_token
              AND locked_until > p_now_ms;

            IF NOT FOUND THEN
                RAISE EXCEPTION ''Lock token invalid, expired, or already acked'';
            END IF;

            -- Check execution status BEFORE extending the lock
            -- Per provider contract: lock can only be renewed if execution is Running
            IF v_work_item_json ? ''ActivityExecute'' THEN
                v_instance_id := v_work_item_json->''ActivityExecute''->>''instance'';
                v_execution_id := (v_work_item_json->''ActivityExecute''->>''execution_id'')::BIGINT;
                
                -- Get execution status directly from executions table
                -- Note: We check executions table, not instances table, because:
                -- 1. Instance record may not exist if ack_orchestration_item was called with NULL version
                -- 2. Execution record is the authoritative source for execution state
                SELECT e.status INTO v_execution_status
                FROM %I.executions e
                WHERE e.instance_id = v_instance_id AND e.execution_id = v_execution_id;
                
                IF v_execution_status IS NULL THEN
                    -- Execution record missing - return NULL to signal Missing state
                    -- Do NOT extend lock per contract
                    RETURN NULL;
                END IF;
                
                IF v_execution_status <> ''Running'' THEN
                    -- Execution is terminal - return status but do NOT extend lock per contract
                    RETURN v_execution_status;
                END IF;
            END IF;
            
            -- Only extend lock if execution is Running (or non-ActivityExecute item)
            UPDATE %I.worker_queue
            SET locked_until = GREATEST(locked_until, p_now_ms) + p_extend_ms
            WHERE lock_token = p_lock_token
              AND locked_until > p_now_ms;
            
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
            
            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Lock token invalid, expired, or already acked'';
            END IF;
            
            RETURN v_execution_status;
        END;
        $renew_lock$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: fetch_work_item
    -- Item is available if:
    -- 1. visible_at <= now (not delayed)
    -- 2. AND (lock_token IS NULL OR locked_until <= now) (not locked or lock expired)
    -- Returns execution_status from the execution table for cancellation support
    -- Note: DROP first because return type changed to include out_execution_status
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_work_item(BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_work_item(
            p_now_ms BIGINT,
            p_lock_timeout_ms BIGINT
        )
        RETURNS TABLE(
            out_work_item TEXT,
            out_lock_token TEXT,
            out_attempt_count INTEGER,
            out_execution_status TEXT
        ) AS $fetch_worker$
        DECLARE
            v_id BIGINT;
            v_work_item_json JSONB;
            v_instance_id TEXT;
            v_execution_id BIGINT;
        BEGIN
            SELECT q.id INTO v_id
            FROM %I.worker_queue q
            WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
              AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms)
            ORDER BY q.id
            LIMIT 1
            FOR UPDATE OF q SKIP LOCKED;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            out_lock_token := ''lock_'' || gen_random_uuid()::TEXT;

            UPDATE %I.worker_queue
            SET lock_token = out_lock_token,
                locked_until = p_now_ms + p_lock_timeout_ms,
                attempt_count = attempt_count + 1
            WHERE id = v_id;

            SELECT work_item, attempt_count
            INTO out_work_item, out_attempt_count
            FROM %I.worker_queue
            WHERE id = v_id;

            -- Parse work item to get instance and execution_id for status lookup
            v_work_item_json := out_work_item::JSONB;
            IF v_work_item_json ? ''ActivityExecute'' THEN
                v_instance_id := v_work_item_json->''ActivityExecute''->>''instance'';
                v_execution_id := (v_work_item_json->''ActivityExecute''->>''execution_id'')::BIGINT;
                
                SELECT e.status INTO out_execution_status
                FROM %I.executions e
                WHERE e.instance_id = v_instance_id AND e.execution_id = v_execution_id;
            ELSE
                out_execution_status := NULL;
            END IF;

            RETURN NEXT;
        END;
        $fetch_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: abandon_work_item
    -- Always clear lock_token and locked_until when abandoning.
    -- Use visible_at to control when item becomes available again.
    EXECUTE format('DROP FUNCTION IF EXISTS %I.abandon_work_item(TEXT, BIGINT, BIGINT, BOOLEAN)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.abandon_work_item(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_delay_ms BIGINT DEFAULT NULL,
            p_ignore_attempt BOOLEAN DEFAULT FALSE
        )
        RETURNS VOID AS $abandon_worker$
        DECLARE
            v_rows_affected INTEGER;
            v_visible_at TIMESTAMPTZ;
        BEGIN
            -- Calculate visible_at based on delay using Rust-provided time
            IF p_delay_ms IS NOT NULL AND p_delay_ms > 0 THEN
                v_visible_at := TO_TIMESTAMP((p_now_ms + p_delay_ms) / 1000.0);
            ELSE
                v_visible_at := TO_TIMESTAMP(p_now_ms / 1000.0);
            END IF;

            -- Always clear lock_token and locked_until when abandoning
            -- Use visible_at to control when item becomes available again
            IF p_ignore_attempt THEN
                UPDATE %I.worker_queue
                SET lock_token = NULL,
                    locked_until = NULL,
                    visible_at = v_visible_at,
                    attempt_count = GREATEST(0, attempt_count - 1)
                WHERE lock_token = p_lock_token;
            ELSE
                UPDATE %I.worker_queue
                SET lock_token = NULL,
                    locked_until = NULL,
                    visible_at = v_visible_at
                WHERE lock_token = p_lock_token;
            END IF;

            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Invalid lock token or already acked'';
            END IF;
        END;
        $abandon_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: enqueue_orchestrator_work
    EXECUTE format('DROP FUNCTION IF EXISTS %I.enqueue_orchestrator_work(TEXT, TEXT, TIMESTAMPTZ, BIGINT, TEXT, TEXT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.enqueue_orchestrator_work(
            p_instance_id TEXT,
            p_work_item TEXT,
            p_visible_at TIMESTAMPTZ,
            p_now_ms BIGINT,
            p_orchestration_name TEXT DEFAULT NULL,
            p_orchestration_version TEXT DEFAULT NULL,
            p_execution_id BIGINT DEFAULT NULL
        )
        RETURNS VOID AS $enq_orch$
        BEGIN
            -- Parameters p_orchestration_name, p_orchestration_version, p_execution_id are ignored
            -- Instance creation happens ONLY via ack_orchestration_item metadata
            INSERT INTO %I.orchestrator_queue (instance_id, work_item, visible_at, created_at)
            VALUES (p_instance_id, p_work_item, p_visible_at, TO_TIMESTAMP(p_now_ms / 1000.0));
        END;
        $enq_orch$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: fetch_orchestration_item
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_orchestration_item(BIGINT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_orchestration_item(
            p_now_ms BIGINT,
            p_lock_timeout_ms BIGINT
        )
        RETURNS TABLE(
            out_instance_id TEXT,
            out_orchestration_name TEXT,
            out_orchestration_version TEXT,
            out_execution_id BIGINT,
            out_history JSONB,
            out_messages JSONB,
            out_lock_token TEXT,
            out_attempt_count INTEGER
        ) AS $fetch_orch$
        DECLARE
            v_instance_id TEXT;
            v_lock_token TEXT;
            v_locked_until BIGINT;
            v_orchestration_name TEXT;
            v_orchestration_version TEXT;
            v_current_execution_id BIGINT;
            v_history JSONB;
            v_messages JSONB;
            v_lock_acquired INTEGER;
            v_max_attempt_count INTEGER;
        BEGIN
            -- Phase 1: Find a candidate instance (no FOR UPDATE yet)
            SELECT q.instance_id INTO v_instance_id
            FROM %I.orchestrator_queue q
            WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
              AND NOT EXISTS (
                SELECT 1 FROM %I.instance_locks il
                WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
              )
            ORDER BY q.visible_at, q.id
            LIMIT 1;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            -- Phase 2: Acquire instance-level advisory lock
            PERFORM pg_advisory_xact_lock(hashtext(v_instance_id));

            -- Phase 3: Re-verify with FOR UPDATE
            SELECT q.instance_id INTO v_instance_id
            FROM %I.orchestrator_queue q
            WHERE q.instance_id = v_instance_id
              AND q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
              AND NOT EXISTS (
                SELECT 1 FROM %I.instance_locks il
                WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
              )
            FOR UPDATE OF q SKIP LOCKED;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            v_lock_token := ''lock_'' || gen_random_uuid()::TEXT;
            v_locked_until := p_now_ms + p_lock_timeout_ms;

            INSERT INTO %I.instance_locks (instance_id, lock_token, locked_until, locked_at)
            VALUES (v_instance_id, v_lock_token, v_locked_until, p_now_ms)
            ON CONFLICT(instance_id) DO UPDATE
            SET lock_token = EXCLUDED.lock_token,
                locked_until = EXCLUDED.locked_until,
                locked_at = EXCLUDED.locked_at
            WHERE %I.instance_locks.locked_until <= p_now_ms;

            GET DIAGNOSTICS v_lock_acquired = ROW_COUNT;

            IF v_lock_acquired = 0 THEN
                RETURN;
            END IF;

            UPDATE %I.orchestrator_queue q
            SET lock_token = v_lock_token,
                locked_until = v_locked_until,
                attempt_count = q.attempt_count + 1
            WHERE q.instance_id = v_instance_id
              AND q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
              AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms);

            SELECT COALESCE(JSONB_AGG(q.work_item::JSONB ORDER BY q.id), ''[]''::JSONB),
                   COALESCE(MAX(q.attempt_count), 1)
            INTO v_messages, v_max_attempt_count
            FROM %I.orchestrator_queue q
            WHERE q.lock_token = v_lock_token;

            SELECT i.orchestration_name, i.orchestration_version, i.current_execution_id
            INTO v_orchestration_name, v_orchestration_version, v_current_execution_id
            FROM %I.instances i
            WHERE i.instance_id = v_instance_id;

            IF FOUND THEN
                SELECT COALESCE(JSONB_AGG(h.event_data::JSONB ORDER BY h.event_id), ''[]''::JSONB)
                INTO v_history
                FROM %I.history h
                WHERE h.instance_id = v_instance_id AND h.execution_id = v_current_execution_id;
                
                v_orchestration_version := COALESCE(v_orchestration_version, ''unknown'');
            ELSE
                SELECT COALESCE(JSONB_AGG(h.event_data::JSONB ORDER BY h.execution_id, h.event_id), ''[]''::JSONB)
                INTO v_history
                FROM %I.history h
                WHERE h.instance_id = v_instance_id;

                IF JSONB_ARRAY_LENGTH(v_history) > 0 AND v_history->0 ? ''OrchestrationStarted'' THEN
                    v_orchestration_name := v_history->0->''OrchestrationStarted''->>''name'';
                    v_orchestration_version := v_history->0->''OrchestrationStarted''->>''version'';
                    v_current_execution_id := 1;
                ELSIF JSONB_ARRAY_LENGTH(v_messages) > 0 AND v_messages->0 ? ''StartOrchestration'' THEN
                    v_orchestration_name := v_messages->0->''StartOrchestration''->>''orchestration'';
                    v_orchestration_version := COALESCE(v_messages->0->''StartOrchestration''->>''version'', ''unknown'');
                    v_current_execution_id := COALESCE((v_messages->0->''StartOrchestration''->>''execution_id'')::BIGINT, 1);
                ELSIF JSONB_ARRAY_LENGTH(v_messages) > 0 AND v_messages->0 ? ''ContinueAsNew'' THEN
                    v_orchestration_name := v_messages->0->''ContinueAsNew''->>''orchestration'';
                    v_orchestration_version := COALESCE(v_messages->0->''ContinueAsNew''->>''version'', ''unknown'');
                    v_current_execution_id := 1;
                ELSE
                    v_orchestration_name := ''Unknown'';
                    v_orchestration_version := ''unknown'';
                    v_current_execution_id := 1;
                END IF;
            END IF;

            RETURN QUERY SELECT
                v_instance_id,
                v_orchestration_name,
                v_orchestration_version,
                v_current_execution_id,
                v_history,
                v_messages,
                v_lock_token,
                v_max_attempt_count;
        END;
        $fetch_orch$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, 
       v_schema_name, v_schema_name);

    -- Procedure: ack_orchestration_item
    EXECUTE format('DROP FUNCTION IF EXISTS %I.ack_orchestration_item(TEXT, BIGINT, BIGINT, JSONB, JSONB, JSONB, JSONB, JSONB)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.ack_orchestration_item(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_execution_id BIGINT,
            p_history_delta JSONB,
            p_worker_items JSONB,
            p_orchestrator_items JSONB,
            p_metadata JSONB,
            p_cancelled_activities JSONB DEFAULT ''[]''::JSONB
        )
        RETURNS VOID AS $ack_orch$
        DECLARE
            v_instance_id TEXT;
            v_now_ts TIMESTAMPTZ;
            v_orchestration_name TEXT;
            v_orchestration_version TEXT;
            v_status TEXT;
            v_output TEXT;
            v_completed_at TIMESTAMPTZ;
            v_elem JSONB;
            v_visible_at TIMESTAMPTZ;
            v_fire_at_ms BIGINT;
            v_item_instance_id TEXT;
            v_cancelled JSONB;
            v_cancelled_execution_id BIGINT;
            v_cancelled_activity_id BIGINT;
        BEGIN
            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);

            SELECT il.instance_id INTO v_instance_id
            FROM %I.instance_locks il
            WHERE il.lock_token = p_lock_token AND il.locked_until > p_now_ms;

            IF NOT FOUND THEN
                RAISE EXCEPTION ''Invalid lock token'';
            END IF;

            v_orchestration_name := p_metadata->>''orchestration_name'';
            v_orchestration_version := p_metadata->>''orchestration_version'';
            v_status := p_metadata->>''status'';
            v_output := p_metadata->>''output'';

            IF v_orchestration_name IS NOT NULL AND v_orchestration_version IS NOT NULL THEN
                INSERT INTO %I.instances (instance_id, orchestration_name, orchestration_version, current_execution_id, created_at, updated_at)
                VALUES (v_instance_id, v_orchestration_name, v_orchestration_version, p_execution_id, v_now_ts, v_now_ts)
                ON CONFLICT (instance_id) DO NOTHING;

                UPDATE %I.instances i
                SET orchestration_name = v_orchestration_name,
                    orchestration_version = v_orchestration_version,
                    updated_at = v_now_ts
                WHERE i.instance_id = v_instance_id;
            END IF;

            INSERT INTO %I.executions (instance_id, execution_id, status, started_at)
            VALUES (v_instance_id, p_execution_id, ''Running'', v_now_ts)
            ON CONFLICT (instance_id, execution_id) DO NOTHING;

            UPDATE %I.instances i
            SET current_execution_id = GREATEST(i.current_execution_id, p_execution_id),
                updated_at = v_now_ts
            WHERE i.instance_id = v_instance_id;

            IF p_history_delta IS NOT NULL AND JSONB_ARRAY_LENGTH(p_history_delta) > 0 THEN
                INSERT INTO %I.history (instance_id, execution_id, event_id, event_type, event_data, created_at)
                SELECT
                    v_instance_id,
                    p_execution_id,
                    (elem->>''event_id'')::BIGINT,
                    elem->>''event_type'',
                    elem->>''event_data'',
                    v_now_ts
                FROM JSONB_ARRAY_ELEMENTS(p_history_delta) AS elem;
            END IF;

            IF v_status IS NOT NULL THEN
                v_completed_at := CASE 
                    WHEN v_status IN (''Completed'', ''Failed'') THEN v_now_ts 
                    ELSE NULL 
                END;
                
                UPDATE %I.executions e
                SET status = v_status, output = v_output, completed_at = v_completed_at
                WHERE e.instance_id = v_instance_id AND e.execution_id = p_execution_id;
            END IF;

            IF p_worker_items IS NOT NULL AND JSONB_ARRAY_LENGTH(p_worker_items) > 0 THEN
                INSERT INTO %I.worker_queue (work_item, visible_at, created_at)
                SELECT elem::TEXT, v_now_ts, v_now_ts
                FROM JSONB_ARRAY_ELEMENTS(p_worker_items) AS elem;
            END IF;

            IF p_orchestrator_items IS NOT NULL AND JSONB_ARRAY_LENGTH(p_orchestrator_items) > 0 THEN
                FOR v_elem IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_orchestrator_items) LOOP
                    IF v_elem ? ''StartOrchestration'' THEN
                        v_item_instance_id := v_elem->''StartOrchestration''->>''instance'';
                    ELSIF v_elem ? ''ContinueAsNew'' THEN
                        v_item_instance_id := v_elem->''ContinueAsNew''->>''instance'';
                    ELSIF v_elem ? ''TimerFired'' THEN
                        v_item_instance_id := v_elem->''TimerFired''->>''instance'';
                        v_fire_at_ms := (v_elem->''TimerFired''->>''fire_at_ms'')::BIGINT;
                    ELSIF v_elem ? ''ActivityCompleted'' THEN
                        v_item_instance_id := v_elem->''ActivityCompleted''->>''instance'';
                    ELSIF v_elem ? ''ActivityFailed'' THEN
                        v_item_instance_id := v_elem->''ActivityFailed''->>''instance'';
                    ELSIF v_elem ? ''ExternalRaised'' THEN
                        v_item_instance_id := v_elem->''ExternalRaised''->>''instance'';
                    ELSIF v_elem ? ''CancelInstance'' THEN
                        v_item_instance_id := v_elem->''CancelInstance''->>''instance'';
                    ELSIF v_elem ? ''SubOrchCompleted'' THEN
                        v_item_instance_id := v_elem->''SubOrchCompleted''->>''parent_instance'';
                    ELSIF v_elem ? ''SubOrchFailed'' THEN
                        v_item_instance_id := v_elem->''SubOrchFailed''->>''parent_instance'';
                    ELSE
                        v_item_instance_id := v_instance_id;
                    END IF;

                    IF v_elem ? ''TimerFired'' AND v_fire_at_ms IS NOT NULL AND v_fire_at_ms > 0 THEN
                        v_visible_at := TO_TIMESTAMP(v_fire_at_ms / 1000.0);
                    ELSE
                        v_visible_at := v_now_ts;
                    END IF;

                    INSERT INTO %I.orchestrator_queue (instance_id, work_item, visible_at, created_at)
                    VALUES (v_item_instance_id, v_elem::TEXT, v_visible_at, v_now_ts);
                    
                    v_fire_at_ms := NULL;
                END LOOP;
            END IF;

            -- ================================================================
            -- Lock-Stealing: Delete worker queue entries for cancelled activities
            -- Uses v_instance_id (from lock_token) for instance constraint
            -- Uses execution_id and activity_id from JSON to identify activities
            -- ================================================================
            IF p_cancelled_activities IS NOT NULL AND JSONB_ARRAY_LENGTH(p_cancelled_activities) > 0 THEN
                FOR v_cancelled IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_cancelled_activities) LOOP
                    v_cancelled_execution_id := (v_cancelled->>''execution_id'')::BIGINT;
                    v_cancelled_activity_id := (v_cancelled->>''activity_id'')::BIGINT;
                    
                    -- Delete matching ActivityExecute items from worker_queue
                    -- The work_item JSON contains ActivityExecute with instance, execution_id, and id (activity_id)
                    DELETE FROM %I.worker_queue wq
                    WHERE wq.work_item::JSONB ? ''ActivityExecute''
                      AND (wq.work_item::JSONB->''ActivityExecute''->>''instance'') = v_instance_id
                      AND (wq.work_item::JSONB->''ActivityExecute''->>''execution_id'')::BIGINT = v_cancelled_execution_id
                      AND (wq.work_item::JSONB->''ActivityExecute''->>''id'')::BIGINT = v_cancelled_activity_id;
                END LOOP;
            END IF;

            DELETE FROM %I.orchestrator_queue q WHERE q.lock_token = p_lock_token;

            DELETE FROM %I.instance_locks il
            WHERE il.instance_id = v_instance_id AND il.lock_token = p_lock_token;
        END;
        $ack_orch$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: abandon_orchestration_item
    EXECUTE format('DROP FUNCTION IF EXISTS %I.abandon_orchestration_item(TEXT, BIGINT, BIGINT, BOOLEAN)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.abandon_orchestration_item(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_delay_ms BIGINT DEFAULT NULL,
            p_ignore_attempt BOOLEAN DEFAULT FALSE
        )
        RETURNS TEXT AS $abandon_orch$
        DECLARE
            v_instance_id TEXT;
            v_visible_at TIMESTAMPTZ;
        BEGIN
            SELECT il.instance_id INTO v_instance_id
            FROM %I.instance_locks il
            WHERE il.lock_token = p_lock_token;

            IF NOT FOUND THEN
                RAISE EXCEPTION ''Invalid lock token'';
            END IF;

            IF p_delay_ms IS NOT NULL AND p_delay_ms > 0 THEN
                v_visible_at := TO_TIMESTAMP((p_now_ms + p_delay_ms) / 1000.0);
                
                IF p_ignore_attempt THEN
                    UPDATE %I.orchestrator_queue
                    SET lock_token = NULL,
                        locked_until = NULL,
                        visible_at = v_visible_at,
                        attempt_count = GREATEST(0, attempt_count - 1)
                    WHERE lock_token = p_lock_token;
                ELSE
                    UPDATE %I.orchestrator_queue
                    SET lock_token = NULL,
                        locked_until = NULL,
                        visible_at = v_visible_at
                    WHERE lock_token = p_lock_token;
                END IF;
            ELSE
                IF p_ignore_attempt THEN
                    UPDATE %I.orchestrator_queue
                    SET lock_token = NULL,
                        locked_until = NULL,
                        attempt_count = GREATEST(0, attempt_count - 1)
                    WHERE lock_token = p_lock_token;
                ELSE
                    UPDATE %I.orchestrator_queue
                    SET lock_token = NULL,
                        locked_until = NULL
                    WHERE lock_token = p_lock_token;
                END IF;
            END IF;

            DELETE FROM %I.instance_locks
            WHERE lock_token = p_lock_token;

            RETURN v_instance_id;
        END;
        $abandon_orch$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: renew_orchestration_item_lock
    EXECUTE format('DROP FUNCTION IF EXISTS %I.renew_orchestration_item_lock(TEXT, BIGINT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.renew_orchestration_item_lock(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_extend_ms BIGINT
        )
        RETURNS VOID AS $renew_orch_lock$
        DECLARE
            v_rows_affected INTEGER;
        BEGIN
            UPDATE %I.instance_locks
            SET locked_until = GREATEST(locked_until, p_now_ms) + p_extend_ms
            WHERE lock_token = p_lock_token
              AND locked_until > p_now_ms;
            
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
            
            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Lock token invalid, expired, or already released'';
            END IF;

            UPDATE %I.orchestrator_queue
            SET locked_until = GREATEST(locked_until, p_now_ms) + p_extend_ms
            WHERE lock_token = p_lock_token;
        END;
        $renew_orch_lock$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- History Procedures
    -- ============================================================================

    -- Procedure: fetch_history
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_history(TEXT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_history(
            p_instance_id TEXT
        )
        RETURNS TABLE(out_event_data TEXT) AS $fetch_history$
        DECLARE
            v_execution_id BIGINT;
        BEGIN
            SELECT COALESCE(MAX(execution_id), 1)
            INTO v_execution_id
            FROM %I.executions
            WHERE instance_id = p_instance_id;

            RETURN QUERY
            SELECT h.event_data
            FROM %I.history h
            WHERE h.instance_id = p_instance_id
              AND h.execution_id = v_execution_id
            ORDER BY h.event_id;
        END;
        $fetch_history$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- Procedure: fetch_history_with_execution
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_history_with_execution(TEXT, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_history_with_execution(
            p_instance_id TEXT,
            p_execution_id BIGINT
        )
        RETURNS TABLE(out_event_data TEXT) AS $fetch_history_exec$
        BEGIN
            RETURN QUERY
            SELECT h.event_data
            FROM %I.history h
            WHERE h.instance_id = p_instance_id
              AND h.execution_id = p_execution_id
            ORDER BY h.event_id;
        END;
        $fetch_history_exec$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- Procedure: append_history
    EXECUTE format('DROP FUNCTION IF EXISTS %I.append_history(TEXT, BIGINT, JSONB, BIGINT)', v_schema_name);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.append_history(
            p_instance_id TEXT,
            p_execution_id BIGINT,
            p_events JSONB,
            p_now_ms BIGINT
        )
        RETURNS VOID AS $append_hist$
        DECLARE
            v_now_ts TIMESTAMPTZ;
        BEGIN
            IF p_events IS NULL OR JSONB_ARRAY_LENGTH(p_events) = 0 THEN
                RETURN;
            END IF;

            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);

            IF EXISTS (
                SELECT 1
                FROM JSONB_ARRAY_ELEMENTS(p_events) elem
                WHERE COALESCE((elem->>''event_id'')::BIGINT, 0) <= 0
            ) THEN
                RAISE EXCEPTION ''Invalid event_id in append_history'';
            END IF;

            INSERT INTO %I.history (instance_id, execution_id, event_id, event_type, event_data, created_at)
            SELECT
                p_instance_id,
                p_execution_id,
                (elem->>''event_id'')::BIGINT,
                elem->>''event_type'',
                elem->>''event_data'',
                v_now_ts
            FROM JSONB_ARRAY_ELEMENTS(p_events) AS elem
            ON CONFLICT (instance_id, execution_id, event_id) DO NOTHING;
        END;
        $append_hist$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

END $$;
