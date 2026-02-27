-- Migration 0003: Add capability filtering support
-- This migration adds:
-- 1. duroxide_version_major/minor/patch columns to executions table
-- 2. Updates fetch_orchestration_item to accept version filter parameters
-- 3. Updates ack_orchestration_item to store pinned_duroxide_version from metadata
-- 4. Updates cleanup_schema to drop new function signatures

-- Add version columns to executions table
ALTER TABLE executions ADD COLUMN IF NOT EXISTS duroxide_version_major INTEGER;
ALTER TABLE executions ADD COLUMN IF NOT EXISTS duroxide_version_minor INTEGER;
ALTER TABLE executions ADD COLUMN IF NOT EXISTS duroxide_version_patch INTEGER;

-- Get the current schema name (set by migration runner)
DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- ============================================================================
    -- Update fetch_orchestration_item to accept version filter parameters
    -- Drop old 2-param signature, create new 4-param signature
    -- ============================================================================
    EXECUTE format('DROP FUNCTION IF EXISTS %I.fetch_orchestration_item(BIGINT, BIGINT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.fetch_orchestration_item(
            p_now_ms BIGINT,
            p_lock_timeout_ms BIGINT,
            p_min_version_packed BIGINT DEFAULT NULL,
            p_max_version_packed BIGINT DEFAULT NULL
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
            IF p_min_version_packed IS NOT NULL THEN
                -- Version-filtered path: join to instances and executions to check pinned version
                SELECT q.instance_id INTO v_instance_id
                FROM %I.orchestrator_queue q
                LEFT JOIN %I.instances i ON q.instance_id = i.instance_id
                LEFT JOIN %I.executions e ON i.instance_id = e.instance_id
                  AND i.current_execution_id = e.execution_id
                WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND NOT EXISTS (
                    SELECT 1 FROM %I.instance_locks il
                    WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
                  )
                  AND (
                    e.duroxide_version_major IS NULL
                    OR (e.duroxide_version_major * 1000000 + e.duroxide_version_minor * 1000 + e.duroxide_version_patch)
                       BETWEEN p_min_version_packed AND p_max_version_packed
                  )
                ORDER BY q.visible_at, q.id
                LIMIT 1;
            ELSE
                -- No filter: original behavior
                SELECT q.instance_id INTO v_instance_id
                FROM %I.orchestrator_queue q
                WHERE q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND NOT EXISTS (
                    SELECT 1 FROM %I.instance_locks il
                    WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
                  )
                ORDER BY q.visible_at, q.id
                LIMIT 1;
            END IF;

            IF NOT FOUND THEN
                RETURN;
            END IF;

            -- Phase 2: Acquire instance-level advisory lock
            PERFORM pg_advisory_xact_lock(hashtext(v_instance_id));

            -- Phase 3: Re-verify with FOR UPDATE (include version filter if applicable)
            IF p_min_version_packed IS NOT NULL THEN
                SELECT q.instance_id INTO v_instance_id
                FROM %I.orchestrator_queue q
                LEFT JOIN %I.instances i ON q.instance_id = i.instance_id
                LEFT JOIN %I.executions e ON i.instance_id = e.instance_id
                  AND i.current_execution_id = e.execution_id
                WHERE q.instance_id = v_instance_id
                  AND q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND NOT EXISTS (
                    SELECT 1 FROM %I.instance_locks il
                    WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
                  )
                  AND (
                    e.duroxide_version_major IS NULL
                    OR (e.duroxide_version_major * 1000000 + e.duroxide_version_minor * 1000 + e.duroxide_version_patch)
                       BETWEEN p_min_version_packed AND p_max_version_packed
                  )
                FOR UPDATE OF q SKIP LOCKED;
            ELSE
                SELECT q.instance_id INTO v_instance_id
                FROM %I.orchestrator_queue q
                WHERE q.instance_id = v_instance_id
                  AND q.visible_at <= TO_TIMESTAMP(p_now_ms / 1000.0)
                  AND NOT EXISTS (
                    SELECT 1 FROM %I.instance_locks il
                    WHERE il.instance_id = q.instance_id AND il.locked_until > p_now_ms
                  )
                FOR UPDATE OF q SKIP LOCKED;
            END IF;

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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Update ack_orchestration_item to handle pinned_duroxide_version
    -- Drop old signature, create new one with version handling
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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Update cleanup_schema to drop new function signatures
    -- ============================================================================
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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name);

END $$;
