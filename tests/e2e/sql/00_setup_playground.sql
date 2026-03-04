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

-- Grant access to df API surface used by tests
-- ---------------------------------------------------------------------------
-- Reusable helper: restore df_e2e_user grants after DROP/CREATE EXTENSION.
-- Called here and by any test that drops & recreates the extension (25, 28).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._e2e_grant_df_to_e2e_user() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_e2e_user') THEN
        RETURN;
    END IF;

    GRANT USAGE ON SCHEMA df TO df_e2e_user;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA df TO df_e2e_user;

    -- df.start() links nodes/instances and reads vars via direct table access.
    -- Until table hardening lands, E2E needs DML on these.
    GRANT SELECT, INSERT, UPDATE, DELETE ON df.instances TO df_e2e_user;
    GRANT SELECT, INSERT, UPDATE, DELETE ON df.nodes TO df_e2e_user;
    GRANT SELECT, INSERT, UPDATE, DELETE ON df.vars TO df_e2e_user;
END $$;

SELECT public._e2e_grant_df_to_e2e_user();

-- ---------------------------------------------------------------------------
-- Reusable helper: wait for the background worker to fully reinitialize
-- after DROP/CREATE EXTENSION. Called by tests 25, 28, 29.
--
-- After CREATE EXTENSION, the new df._worker_epoch table is empty. The OLD
-- runtime (from before the drop) may still be running; its epoch sentinel
-- check (every 5s) will eventually detect the sentinel is gone, shut down,
-- and reinitialize. We wait for this cycle by:
--   1. Polling df._worker_epoch until non-empty (sentinel written).
--   2. Submitting a trivial df.sql('SELECT 1') and waiting for completion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._e2e_wait_for_worker_ready(
    p_timeout_secs INT DEFAULT 30
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    attempts     INT := 0;
    max_attempts INT := p_timeout_secs * 10;  -- poll every 100ms
    sentinel_exists BOOLEAN;
BEGIN
    LOOP
        SELECT EXISTS(SELECT 1 FROM df._worker_epoch) INTO sentinel_exists;
        EXIT WHEN sentinel_exists OR attempts >= max_attempts;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT sentinel_exists THEN
        RAISE EXCEPTION 'worker did not reinitialize after extension recreate (no sentinel after %s s)', p_timeout_secs;
    END IF;

    RAISE NOTICE 'Worker epoch sentinel detected — full restart cycle complete';
END $$;

-- Install extensions needed by tests (requires superuser)
CREATE EXTENSION IF NOT EXISTS dblink;

-- E2E tests create/drop temporary state tables in the public schema.
-- PG15+ revokes CREATE on public from PUBLIC by default.
GRANT USAGE, CREATE ON SCHEMA public TO df_e2e_user;

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
SELECT 'TEST PASSED' AS result;

