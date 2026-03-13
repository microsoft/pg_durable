-- Migration 0005: Add custom status support
-- Description: Adds custom status support for orchestration instances.
-- Adds custom_status and custom_status_version columns to instances table,
-- updates ack_orchestration_item to handle custom status updates,
-- and adds get_custom_status stored procedure for polling.

-- Schema changes using unqualified names (search_path set by migration runner)
ALTER TABLE instances ADD COLUMN IF NOT EXISTS custom_status TEXT;
ALTER TABLE instances ADD COLUMN IF NOT EXISTS custom_status_version INTEGER NOT NULL DEFAULT 0;

-- Stored procedure changes using schema-qualified names
DO $$
DECLARE
    v_schema_name TEXT := current_schema();
BEGIN
    -- ============================================================================
    -- Part 1: Update ack_orchestration_item to handle custom_status
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
            v_custom_status_action TEXT;
            v_custom_status_value TEXT;
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

            -- Handle custom_status update on instances table
            v_custom_status_action := p_metadata->>''custom_status_action'';
            IF v_custom_status_action = ''set'' THEN
                v_custom_status_value := p_metadata->>''custom_status_value'';
                UPDATE %I.instances
                SET custom_status = v_custom_status_value,
                    custom_status_version = custom_status_version + 1
                WHERE instance_id = v_instance_id;
            ELSIF v_custom_status_action = ''clear'' THEN
                UPDATE %I.instances
                SET custom_status = NULL,
                    custom_status_version = custom_status_version + 1
                WHERE instance_id = v_instance_id;
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
                    ELSIF v_elem ? ''QueueMessage'' THEN
                        v_item_instance_id := v_elem->''QueueMessage''->>''instance'';
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
       v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name,
       v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 2: Update ack_worker to validate lock expiry
    -- ============================================================================

    EXECUTE format('DROP FUNCTION IF EXISTS %I.ack_worker(TEXT, TEXT, TEXT, BIGINT)', v_schema_name);
    EXECUTE format('DROP FUNCTION IF EXISTS %I.ack_worker(TEXT)', v_schema_name);

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.ack_worker(
            p_lock_token TEXT,
            p_instance_id TEXT DEFAULT NULL,
            p_completion_json TEXT DEFAULT NULL,
            p_now_ms BIGINT DEFAULT NULL
        )
        RETURNS VOID AS $ack_worker$
        DECLARE
            v_rows_affected INTEGER;
            v_now_ts TIMESTAMPTZ;
            v_session_id TEXT;
        BEGIN
            -- Capture session_id before deleting
            SELECT session_id INTO v_session_id
            FROM %I.worker_queue WHERE lock_token = p_lock_token;

            -- Delete the worker queue item, only if lock is still valid
            IF p_now_ms IS NOT NULL THEN
                DELETE FROM %I.worker_queue WHERE lock_token = p_lock_token AND locked_until > p_now_ms;
            ELSE
                DELETE FROM %I.worker_queue WHERE lock_token = p_lock_token;
            END IF;
            GET DIAGNOSTICS v_rows_affected = ROW_COUNT;

            IF v_rows_affected = 0 THEN
                RAISE EXCEPTION ''Worker queue item not found or already processed'';
            END IF;

            -- Only enqueue completion if provided (NULL means cancelled activity)
            IF p_completion_json IS NOT NULL THEN
                -- Validate required parameters for completion
                IF p_instance_id IS NULL THEN
                    RAISE EXCEPTION ''p_instance_id is required when p_completion_json is provided'';
                END IF;
                IF p_now_ms IS NULL THEN
                    RAISE EXCEPTION ''p_now_ms is required when p_completion_json is provided'';
                END IF;
                
                v_now_ts := TO_TIMESTAMP(p_now_ms / 1000.0);
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
    ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 3: Create get_custom_status stored procedure
    -- ============================================================================

    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.get_custom_status(
            p_instance_id TEXT,
            p_last_seen_version BIGINT
        )
        RETURNS TABLE(
            out_custom_status TEXT,
            out_custom_status_version BIGINT
        ) AS $get_cs$
        BEGIN
            RETURN QUERY
            SELECT i.custom_status, i.custom_status_version::BIGINT
            FROM %I.instances i
            WHERE i.instance_id = p_instance_id
              AND i.custom_status_version > p_last_seen_version;
        END;
        $get_cs$ LANGUAGE plpgsql;
    ', v_schema_name, v_schema_name);

    -- ============================================================================
    -- Part 4: Update cleanup_schema to drop new function
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
            DROP FUNCTION IF EXISTS %I.get_custom_status(TEXT, BIGINT);
            
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
       v_schema_name, v_schema_name, v_schema_name);

    RAISE NOTICE 'Migration 0005: Added custom status support (custom_status/custom_status_version columns, get_custom_status function, updated ack_orchestration_item)';
END $$;
