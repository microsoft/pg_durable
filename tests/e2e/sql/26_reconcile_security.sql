-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Security regression test for start reconciliation.
--
-- df.instances.start_input is caller-writable (df.start() runs as the caller and
-- writes it). The background worker replays it to start the durable engine, and
-- the orchestration selects which graph to load — and therefore which role runs
-- the SQL — from the instance id. If the worker/orchestration trusted the
-- instance id embedded in the payload, a low-privilege user could INSERT a
-- crafted pending row whose start_input points at ANOTHER user's instance and
-- have the superuser worker start it, running the victim's workflow as the
-- victim with attacker-chosen vars (cross-tenant execution / SQL injection).
--
-- This test constructs exactly that attack across two roles and asserts it is
-- blocked: the attacker's row runs the attacker's own graph, and the victim's
-- protected table is never written by the attacker-triggered start.
--
-- Base connection is the superuser (postgres); the crafted rows are inserted by
-- the two non-superuser roles themselves so RLS and column grants apply. All ids
-- are 8 lowercase-hex characters (enforced by the df.instances/df.nodes CHECKs).

-- --- Setup (superuser) ------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'df_sec_victim') THEN
        CREATE ROLE df_sec_victim LOGIN;
    END IF;
END $$;
SELECT df.grant_usage('df_sec_victim');

DROP TABLE IF EXISTS sec_victim_secret;
DROP TABLE IF EXISTS sec_attacker_probe;
CREATE TABLE sec_victim_secret (marker TEXT);
CREATE TABLE sec_attacker_probe (marker TEXT);
-- Only the victim can write its secret table; only the attacker can write its
-- own probe table. If the redirect worked, the victim's node (running as the
-- victim) would write sec_victim_secret.
GRANT INSERT ON sec_victim_secret TO df_sec_victim;
GRANT INSERT ON sec_attacker_probe TO df_e2e_user;

-- --- Victim creates an (unstarted) instance whose graph writes its secret -----
-- Inserted directly and left pending: it is neither notified nor old enough for
-- the reconcile grace window, so it will not start on its own during the test.
SET SESSION AUTHORIZATION df_sec_victim;
BEGIN;
INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, database)
VALUES ('c0ffee0d', 'c0ffee00', 'SQL',
        'INSERT INTO sec_victim_secret VALUES (''victim-secret'')',
        'df_sec_victim'::regrole, 'postgres');
INSERT INTO df.instances (id, label, root_node, submitted_by, database, start_input)
VALUES ('c0ffee00', 'sec-victim', 'c0ffee0d',
        'df_sec_victim'::regrole, 'postgres',
        '{"instance_id": "c0ffee00", "vars": {}}'::jsonb);
COMMIT;
RESET SESSION AUTHORIZATION;

-- --- Attacker crafts a row whose start_input points at the victim instance ----
SET SESSION AUTHORIZATION df_e2e_user;
BEGIN;
INSERT INTO df.nodes (id, instance_id, node_type, query, submitted_by, database)
VALUES ('facade0d', 'facade00', 'SQL',
        'INSERT INTO sec_attacker_probe VALUES (''attacker-ran'')',
        'df_e2e_user'::regrole, 'postgres');
INSERT INTO df.instances (id, label, root_node, submitted_by, database, start_input)
VALUES ('facade00', 'sec-attacker', 'facade0d',
        'df_e2e_user'::regrole, 'postgres',
        '{"instance_id": "c0ffee00", "vars": {"x": "; DROP TABLE sec_victim_secret; --"}}'::jsonb);
COMMIT;
-- Trigger the crafted row immediately via the public NOTIFY channel.
SELECT pg_notify('pg_durable_start', 'facade00');
RESET SESSION AUTHORIZATION;

-- --- Wait for the attacker instance to finish, then assert isolation held -----
DO $$
DECLARE status TEXT; attempts INT := 0;
BEGIN
    LOOP
        SELECT s INTO status FROM df.status('facade00') s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'cancelled') OR attempts > 600;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    -- The attacker instance must run ITS OWN graph (writing its own probe), not
    -- the victim's — proving start_input.instance_id did not redirect loading.
    IF lower(COALESCE(status, 'pending')) <> 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED [start_input_redirect]: attacker instance did not run its own graph (status=%)', status;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sec_attacker_probe WHERE marker = 'attacker-ran') THEN
        RAISE EXCEPTION 'TEST FAILED [start_input_redirect]: attacker instance completed but its own node never ran';
    END IF;

    -- The victim's graph must NOT have executed as a side effect of starting the
    -- attacker's instance. A non-empty secret table means the redirect worked.
    IF EXISTS (SELECT 1 FROM sec_victim_secret) THEN
        RAISE EXCEPTION 'TEST FAILED [start_input_redirect]: victim graph executed via attacker-controlled start_input (privilege escalation)';
    END IF;

    RAISE NOTICE 'PASSED [start_input_redirect]: crafted start_input could not redirect graph loading to the victim instance';
END $$;

-- --- Cleanup ----------------------------------------------------------------
-- Mark the still-pending victim row terminal so the reconcile sweep never starts
-- it after this test (superuser UPDATE bypasses RLS/grants); terminal rows are
-- pruned by the worker. The attacker row is already terminal (completed).
UPDATE df.instances SET status = 'cancelled', updated_at = now()
WHERE id IN ('c0ffee00', 'facade00') AND status NOT IN ('completed', 'failed', 'cancelled');
DROP TABLE sec_victim_secret;
DROP TABLE sec_attacker_probe;
-- DROP OWNED BY removes df_sec_victim's remaining grants so DROP ROLE succeeds;
-- the cancelled instance row (submitted_by = df_sec_victim) survives with a
-- dangling regrole, which the extension tolerates, and is pruned as terminal.
DROP OWNED BY df_sec_victim;
DROP ROLE IF EXISTS df_sec_victim;

SELECT 'TEST PASSED: reconcile security' AS result;
