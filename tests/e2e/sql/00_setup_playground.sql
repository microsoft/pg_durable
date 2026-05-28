-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Setup: Create playground schema and test data for scenario tests
-- This file runs first (00_) to set up shared test infrastructure

-- ---------------------------------------------------------------------------
-- E2E test roles
--
-- We want the default E2E posture to be: run tests as a non-privileged role.
-- This setup file is expected to run as a superuser (postgres in Docker,
-- or the pgrx superuser in local runs) and will create/grant the test role.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user') THEN
        CREATE ROLE df_e2e_user LOGIN;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Reusable helper: wait for the background worker to fully reinitialize
-- after DROP/CREATE EXTENSION. Called by tests 25, 28, 29 and at the end
-- of this setup file so all tests start with the BGW fully ready.
--
-- After CREATE EXTENSION, the BGW detects the new extension, applies all
-- duroxide migrations via ApplyAll, then writes a readiness record to
-- duroxide._worker_ready. We poll that table directly because
-- is_worker_ready() is an internal Rust function, not a SQL-callable API.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._e2e_wait_for_worker_ready(
    p_timeout_secs INT DEFAULT 30
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    attempts     INT := 0;
    max_attempts INT := p_timeout_secs * 10;  -- poll every 100ms
    table_exists BOOLEAN;
    is_ready     BOOLEAN;
BEGIN
    LOOP
        SELECT EXISTS(
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'duroxide' AND table_name = '_worker_ready'
        ) INTO table_exists;

        IF table_exists THEN
            SELECT EXISTS(SELECT 1 FROM duroxide._worker_ready WHERE schema_version >= 1) INTO is_ready;
        ELSE
            is_ready := FALSE;
        END IF;

        EXIT WHEN is_ready OR attempts >= max_attempts;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT is_ready THEN
        RAISE EXCEPTION 'Background worker did not become ready after % seconds. Check server logs.', p_timeout_secs;
    END IF;

    RAISE NOTICE 'Background worker ready (all migrations applied)';
END $$;

-- ---------------------------------------------------------------------------
-- Reusable helper: DROP EXTENSION pg_durable with deadlock retry.
--
-- After a durable function completes, the duroxide runtime may still be
-- acknowledging the orchestration item (ack_orchestration_item). If DROP
-- EXTENSION tries to take AccessExclusiveLock on those tables at the same
-- time, PostgreSQL detects a deadlock. This helper retries on deadlock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._e2e_drop_extension_safe()
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    attempts INT := 0;
BEGIN
    LOOP
        BEGIN
            EXECUTE 'DROP EXTENSION IF EXISTS pg_durable CASCADE';
            RETURN;
        EXCEPTION WHEN deadlock_detected THEN
            attempts := attempts + 1;
            IF attempts >= 5 THEN
                RAISE;
            END IF;
            PERFORM pg_sleep(1);
        END;
    END LOOP;
END $$;

-- Install extensions needed by tests (requires superuser)
CREATE EXTENSION IF NOT EXISTS dblink;

-- E2E tests create/drop temporary state tables in the public schema.
-- PG15+ revokes CREATE on public from PUBLIC by default.
GRANT USAGE, CREATE ON SCHEMA public TO df_e2e_user;

-- Grant df privileges to the default E2E user. CREATE EXTENSION no longer
-- grants to PUBLIC, so every non-privileged role needs explicit privileges.
-- include_http => true is needed because tests in 04 and 06 use df.http().
SELECT df.grant_usage('df_e2e_user', include_http => true);

-- Create playground schema
CREATE SCHEMA IF NOT EXISTS playground;

-- Ensure playground objects are owned by the non-privileged E2E role
ALTER SCHEMA playground OWNER TO df_e2e_user;

-- Users table
CREATE TABLE IF NOT EXISTS playground.users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT now()
);

ALTER TABLE playground.users OWNER TO df_e2e_user;

-- Orders table
CREATE TABLE IF NOT EXISTS playground.orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES playground.users(id),
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT now(),
    processed_at TIMESTAMP
);

ALTER TABLE playground.orders OWNER TO df_e2e_user;

-- Task queue for job processing examples
CREATE TABLE IF NOT EXISTS playground.task_queue (
    id SERIAL PRIMARY KEY,
    payload JSONB NOT NULL,
    status VARCHAR(50) DEFAULT 'pending',
    priority INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT now(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);

ALTER TABLE playground.task_queue OWNER TO df_e2e_user;

-- Logs table for function output
CREATE TABLE IF NOT EXISTS playground.logs (
    id SERIAL PRIMARY KEY,
    msg TEXT NOT NULL,
    level VARCHAR(20) DEFAULT 'info',
    created_at TIMESTAMP DEFAULT now()
);

ALTER TABLE playground.logs OWNER TO df_e2e_user;

-- Staging table for ETL examples
CREATE TABLE IF NOT EXISTS playground.staging (
    id SERIAL PRIMARY KEY,
    data JSONB,
    source_id INTEGER,
    processed_at TIMESTAMP
);

ALTER TABLE playground.staging OWNER TO df_e2e_user;

-- Target table for ETL examples
CREATE TABLE IF NOT EXISTS playground.target (
    id SERIAL PRIMARY KEY,
    data JSONB,
    source_id INTEGER,
    processed_at TIMESTAMP,
    loaded_at TIMESTAMP DEFAULT now()
);

ALTER TABLE playground.target OWNER TO df_e2e_user;

-- Insert sample users
INSERT INTO playground.users (name, email, active) VALUES
    ('Alice Johnson', 'alice@example.com', true),
    ('Bob Smith', 'bob@example.com', true),
    ('Carol White', 'carol@example.com', true),
    ('David Brown', 'david@example.com', false),
    ('Eve Davis', 'eve@example.com', true)
ON CONFLICT (email) DO NOTHING;

-- Insert sample orders
INSERT INTO playground.orders (user_id, amount, status) VALUES
    (1, 99.99, 'pending'),
    (1, 149.50, 'completed'),
    (2, 75.00, 'pending'),
    (3, 200.00, 'processing'),
    (3, 50.00, 'pending'),
    (5, 125.00, 'completed');

-- Insert sample tasks
INSERT INTO playground.task_queue (payload, status, priority) VALUES
    ('{"type": "email", "to": "alice@example.com"}', 'pending', 1),
    ('{"type": "email", "to": "bob@example.com"}', 'pending', 2),
    ('{"type": "report", "name": "daily_sales"}', 'pending', 0),
    ('{"type": "cleanup", "target": "temp_files"}', 'completed', 0),
    ('{"type": "sync", "source": "external_api"}', 'pending', 3);

-- Insert staging data for ETL
INSERT INTO playground.staging (data, source_id) VALUES
    ('{"product": "Widget A", "qty": 10}', 1001),
    ('{"product": "Widget B", "qty": 25}', 1002),
    ('{"product": "Gadget X", "qty": 5}', 1003);

SELECT 'Playground schema setup complete' AS status;

-- Wait for the background worker to finish applying migrations before any
-- test can call df.start(). This prevents races where df.start() is rejected
-- because the duroxide schema is not yet initialised.
SELECT public._e2e_wait_for_worker_ready(60);

SELECT 'TEST PASSED' AS result;

