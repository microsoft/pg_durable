-- Migration 0004: Add session affinity support
-- This migration adds:
-- 1. session_id column to worker_queue
-- 2. sessions table for tracking session ownership
-- 3. Session-aware fetch_work_item with routing logic
-- 4. Session piggybacking in ack_worker and renew_work_item_lock
-- 5. renew_session_lock and cleanup_orphaned_sessions stored procedures
-- 6. Updated enqueue_worker_work and ack_orchestration_item for session_id

-- Schema changes using unqualified names (search_path set by migration runner)
ALTER TABLE worker_queue ADD COLUMN IF NOT EXISTS session_id TEXT;
CREATE INDEX IF NOT EXISTS idx_worker_queue_session_id ON worker_queue(session_id);

CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    worker_id TEXT NOT NULL,
    locked_until BIGINT NOT NULL,
    last_activity_at BIGINT NOT NULL
);

-- Stored procedure changes using schema-qualified names
DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- ============================================================================
    -- Part 1: Update enqueue_worker_work to accept session_id
    -- ============================================================================

    EXECUTE format('DROP FUNCTION IF EXISTS %I.enqueue_worker_work(TEXT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.enqueue_worker_work(
            p_work_item TEXT,
            p_now_ms BIGINT,
            p_session_id TEXT DEFAULT NULL
        )
        RETURNS VOID AS $enq_worker$
        DECLARE
            v_now_ts TIMESTAMPTZ;
        BEGIN
            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);
            INSERT INTO %I.worker_queue (work_item, visible_at, created_at, session_id)
            VALUES (p_work_item, v_now_ts, v_now_ts, p_session_id);
        END;
        $enq_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 2: Update fetch_work_item with session routing
    -- Drop old 2-param version, create new 4-param version returning 3 columns
    -- (out_execution_status removed - cancellation now via lock-stealing)
    -- ============================================================================

    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_work_item(BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_work_item(
            p_now_ms BIGINT,
            p_lock_timeout_ms BIGINT,
            p_owner_id TEXT DEFAULT NULL,
            p_session_lock_timeout_ms BIGINT DEFAULT NULL
        )
        RETURNS TABLE(
            out_work_item TEXT,
            out_lock_token TEXT,
            out_attempt_count INTEGER
        ) AS $fetch_worker$
        DECLARE
            v_id BIGINT;
            v_session_id TEXT;
            v_session_locked_until BIGINT;
        BEGIN
            IF p_owner_id IS NOT NULL THEN
                -- Session-aware fetch: find eligible items considering session routing
                -- Eligible items are:
                -- 1. Non-session items (q.session_id IS NULL)
                -- 2. Items for sessions owned by this worker (s.worker_id = p_owner_id AND s.locked_until > p_now_ms)
                -- 3. Items for claimable sessions (no active session row, or expired lock)
                SELECT q.id, q.session_id INTO v_id, v_session_id
                FROM %I.worker_queue q
                LEFT JOIN %I.sessions s ON s.session_id = q.session_id AND s.locked_until > p_now_ms
                WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms)
                  AND (
                    q.session_id IS NULL
                    OR s.worker_id = p_owner_id
                    OR s.session_id IS NULL
                  )
                ORDER BY q.id
                LIMIT 1
                FOR UPDATE OF q SKIP LOCKED;
            ELSE
                -- Non-session fetch: only non-session items
                SELECT q.id, q.session_id INTO v_id, v_session_id
                FROM %I.worker_queue q
                WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND (q.lock_token IS NULL OR q.locked_until <= p_now_ms)
                  AND q.session_id IS NULL
                ORDER BY q.id
                LIMIT 1
                FOR UPDATE OF q SKIP LOCKED;
            END IF;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            out_lock_token := ''lock_'' || gen_random_uuid()::TEXT;

            -- Increment attempt_count and lock the item
            UPDATE %I.worker_queue
            SET lock_token = out_lock_token,
                locked_until = p_now_ms + p_lock_timeout_ms,
                attempt_count = attempt_count + 1
            WHERE id = v_id;

            SELECT work_item, attempt_count
            INTO out_work_item, out_attempt_count
            FROM %I.worker_queue
            WHERE id = v_id;

            -- If session-bound, upsert the sessions row
            IF v_session_id IS NOT NULL AND p_owner_id IS NOT NULL THEN
                v_session_locked_until := p_now_ms + COALESCE(p_session_lock_timeout_ms, p_lock_timeout_ms);

                INSERT INTO %I.sessions (session_id, worker_id, locked_until, last_activity_at)
                VALUES (v_session_id, p_owner_id, v_session_locked_until, p_now_ms)
                ON CONFLICT (session_id) DO UPDATE
                SET worker_id = p_owner_id,
                    locked_until = v_session_locked_until,
                    last_activity_at = p_now_ms
                WHERE %I.sessions.locked_until <= p_now_ms OR %I.sessions.worker_id = p_owner_id;

                -- If upsert affected 0 rows, another worker owns this session.
                -- Roll back: clear lock so item can be retried.
                IF NOT FOUND THEN
                    UPDATE %I.worker_queue
                    SET lock_token = NULL,
                        locked_until = NULL,
                        attempt_count = attempt_count - 1
                    WHERE id = v_id;
                    RETURN;
                END IF;
            END IF;

            RETURN NEXT;
        END;
        $fetch_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 3: Update ack_worker to piggyback session last_activity_at
    -- ============================================================================

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
            v_session_id TEXT;
        BEGIN
            v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);

            -- Capture session_id before deleting
            SELECT session_id INTO v_session_id
            FROM %I.worker_queue WHERE lock_token = p_lock_token;

            -- Delete the worker queue item
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

            -- Piggyback: update session last_activity_at
            IF v_session_id IS NOT NULL AND p_now_ms IS NOT NULL THEN
                UPDATE %I.sessions SET last_activity_at = p_now_ms
                WHERE session_id = v_session_id AND locked_until > p_now_ms;
            END IF;
        END;
        $ack_worker$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 4: Update renew_work_item_lock to piggyback session last_activity_at
    -- Also change return type from TEXT to VOID (execution_status removed in 0.1.8)
    -- ============================================================================

    EXECUTE format('DROP FUNCTION IF EXISTS %I.renew_work_item_lock(TEXT, BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.renew_work_item_lock(
            p_lock_token TEXT,
            p_now_ms BIGINT,
            p_extend_ms BIGINT
        )
        RETURNS VOID AS $renew_lock$
        DECLARE
            v_rows_affected INTEGER;
            v_session_id TEXT;
        BEGIN
            -- Read session_id before updating
            SELECT session_id INTO v_session_id
            FROM %I.worker_queue
            WHERE lock_token = p_lock_token;

            -- Update lock timeout only if lock is still valid
            UPDATE %I.worker_queue
            SET locked_until = GREATEST(locked_until, p_now_ms) + p_extend_ms
            WHERE lock_token = p_lock_token
              AND locked_until > p_now_ms;

            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Lock token invalid, expired, or already acked'';
            END IF;

            -- Piggyback: update session last_activity_at
            IF v_session_id IS NOT NULL THEN
                UPDATE %I.sessions SET last_activity_at = p_now_ms
                WHERE session_id = v_session_id AND locked_until > p_now_ms;
            END IF;
        END;
        $renew_lock$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 5: Create renew_session_lock stored procedure
    -- ============================================================================

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.renew_session_lock(
            p_owner_ids TEXT[],
            p_now_ms BIGINT,
            p_extend_ms BIGINT,
            p_idle_timeout_ms BIGINT
        )
        RETURNS BIGINT AS $renew_session$
        DECLARE
            v_count BIGINT;
        BEGIN
            UPDATE %I.sessions SET locked_until = p_now_ms + p_extend_ms
            WHERE worker_id = ANY(p_owner_ids)
              AND locked_until > p_now_ms
              AND last_activity_at > (p_now_ms - p_idle_timeout_ms);

            GET DIAGNOSTICS v_count = ROW_COUNT;
            RETURN v_count;
        END;
        $renew_session$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 6: Create cleanup_orphaned_sessions stored procedure
    -- ============================================================================

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.cleanup_orphaned_sessions(
            p_now_ms BIGINT
        )
        RETURNS BIGINT AS $cleanup_sessions$
        DECLARE
            v_count BIGINT;
        BEGIN
            DELETE FROM %I.sessions
            WHERE locked_until < p_now_ms
              AND NOT EXISTS (SELECT 1 FROM %I.worker_queue WHERE worker_queue.session_id = sessions.session_id);

            GET DIAGNOSTICS v_count = ROW_COUNT;
            RETURN v_count;
        END;
        $cleanup_sessions$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 7: Update ack_orchestration_item to extract session_id from worker items
    -- ============================================================================

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
            v_parent_instance_id TEXT;
            v_status TEXT;
            v_output TEXT;
            v_completed_at TIMESTAMPTZ;
            v_elem JSONB;
            v_visible_at TIMESTAMPTZ;
            v_fire_at_ms BIGINT;
            v_item_instance_id TEXT;
            v_item_session_id TEXT;
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
            v_parent_instance_id := p_metadata->>''parent_instance_id'';
            v_status := p_metadata->>''status'';
            v_output := p_metadata->>''output'';

            IF v_orchestration_name IS NOT NULL AND v_orchestration_version IS NOT NULL THEN
                INSERT INTO %I.instances (instance_id, orchestration_name, orchestration_version, current_execution_id, parent_instance_id, created_at, updated_at)
                VALUES (v_instance_id, v_orchestration_name, v_orchestration_version, p_execution_id, v_parent_instance_id, v_now_ts, v_now_ts)
                ON CONFLICT (instance_id) DO NOTHING;

                UPDATE %I.instances i
                SET orchestration_name = v_orchestration_name,
                    orchestration_version = v_orchestration_version,
                    parent_instance_id = COALESCE(i.parent_instance_id, v_parent_instance_id),
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

            -- Store pinned duroxide version on execution if provided
            IF p_metadata ? ''pinned_duroxide_version'' AND p_metadata->''pinned_duroxide_version'' IS NOT NULL
               AND p_metadata->>''pinned_duroxide_version'' != ''null'' THEN
                UPDATE %I.executions
                SET duroxide_version_major = (p_metadata->''pinned_duroxide_version''->>''major'')::INTEGER,
                    duroxide_version_minor = (p_metadata->''pinned_duroxide_version''->>''minor'')::INTEGER,
                    duroxide_version_patch = (p_metadata->''pinned_duroxide_version''->>''patch'')::INTEGER
                WHERE instance_id = v_instance_id AND execution_id = p_execution_id;
            END IF;

            -- Enqueue worker items with session_id support
            IF p_worker_items IS NOT NULL AND JSONB_ARRAY_LENGTH(p_worker_items) > 0 THEN
                FOR v_elem IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_worker_items) LOOP
                    IF v_elem ? ''ActivityExecute'' THEN
                        v_item_session_id := v_elem->''ActivityExecute''->>''session_id'';
                    ELSE
                        v_item_session_id := NULL;
                    END IF;

                    INSERT INTO %I.worker_queue (work_item, visible_at, created_at, session_id)
                    VALUES (v_elem::TEXT, v_now_ts, v_now_ts, v_item_session_id);
                END LOOP;
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

            -- Lock-Stealing: Delete worker queue entries for cancelled activities
            IF p_cancelled_activities IS NOT NULL AND JSONB_ARRAY_LENGTH(p_cancelled_activities) > 0 THEN
                FOR v_cancelled IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_cancelled_activities) LOOP
                    v_cancelled_execution_id := (v_cancelled->>''execution_id'')::BIGINT;
                    v_cancelled_activity_id := (v_cancelled->>''activity_id'')::BIGINT;
                    
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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 8: Update cleanup_schema to drop new functions and sessions table
    -- ============================================================================

    EXECUTE format('DROP FUNCTION IF EXISTS %I.cleanup_schema()', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.cleanup_schema()
        RETURNS VOID AS $cleanup$
        BEGIN
            -- Drop tables first
            DROP TABLE IF EXISTS %I.sessions CASCADE;
            DROP TABLE IF EXISTS %I.instances CASCADE;
            DROP TABLE IF EXISTS %I.executions CASCADE;
            DROP TABLE IF EXISTS %I.history CASCADE;
            DROP TABLE IF EXISTS %I.orchestrator_queue CASCADE;
            DROP TABLE IF EXISTS %I.worker_queue CASCADE;
            DROP TABLE IF EXISTS %I.instance_locks CASCADE;
            DROP TABLE IF EXISTS %I._duroxide_migrations CASCADE;
            
            -- Drop all stored procedures
            DROP FUNCTION IF EXISTS %I.cleanup_schema();
            DROP FUNCTION IF EXISTS %I.list_instances();
            DROP FUNCTION IF EXISTS %I.list_executions(TEXT);
            DROP FUNCTION IF EXISTS %I.latest_execution_id(TEXT);
            DROP FUNCTION IF EXISTS %I.list_instances_by_status(TEXT);
            DROP FUNCTION IF EXISTS %I.get_instance_info(TEXT);
            DROP FUNCTION IF EXISTS %I.get_execution_info(TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.get_system_metrics();
            DROP FUNCTION IF EXISTS %I.get_queue_depths(BIGINT);
            DROP FUNCTION IF EXISTS %I.enqueue_worker_work(TEXT, BIGINT, TEXT);
            DROP FUNCTION IF EXISTS %I.ack_worker(TEXT, TEXT, TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.renew_work_item_lock(TEXT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_work_item(BIGINT, BIGINT, TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.abandon_work_item(TEXT, BIGINT, BIGINT, BOOLEAN);
            DROP FUNCTION IF EXISTS %I.enqueue_orchestrator_work(TEXT, TEXT, TIMESTAMPTZ, BIGINT, TEXT, TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_orchestration_item(BIGINT, BIGINT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.ack_orchestration_item(TEXT, BIGINT, BIGINT, JSONB, JSONB, JSONB, JSONB, JSONB);
            DROP FUNCTION IF EXISTS %I.abandon_orchestration_item(TEXT, BIGINT, BIGINT, BOOLEAN);
            DROP FUNCTION IF EXISTS %I.renew_orchestration_item_lock(TEXT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.fetch_history(TEXT);
            DROP FUNCTION IF EXISTS %I.fetch_history_with_execution(TEXT, BIGINT);
            DROP FUNCTION IF EXISTS %I.append_history(TEXT, BIGINT, JSONB, BIGINT);
            DROP FUNCTION IF EXISTS %I.list_children(TEXT);
            DROP FUNCTION IF EXISTS %I.get_parent_id(TEXT);
            DROP FUNCTION IF EXISTS %I.delete_instances_atomic(TEXT[], BOOLEAN);
            DROP FUNCTION IF EXISTS %I.prune_executions(TEXT, INTEGER, BIGINT);
            DROP FUNCTION IF EXISTS %I.renew_session_lock(TEXT[], BIGINT, BIGINT, BIGINT);
            DROP FUNCTION IF EXISTS %I.cleanup_orphaned_sessions(BIGINT);
            
            -- Drop trigger functions (not schema-qualified, they use search_path)
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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name);

    RAISE NOTICE 'Migration 0004: Added session support (sessions table, session routing in fetch, session piggybacking in ack/renew)';
END $$;
