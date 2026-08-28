-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Regression: df.start() works for roles whose names require quoting.

DO $setup$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['labUser', 'role with space', 'role"with"quote']
    LOOP
        PERFORM pg_terminate_backend(pid)
          FROM pg_stat_activity
         WHERE usename = role_name
           AND pid <> pg_backend_pid();

        BEGIN
            EXECUTE format('DROP OWNED BY %I', role_name);
        EXCEPTION
            WHEN undefined_object THEN NULL;
        END;
        EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
        EXECUTE format('CREATE ROLE %I LOGIN', role_name);

        PERFORM df.grant_usage(role_name);
        EXECUTE format(
            'GRANT TEMPORARY ON DATABASE %I TO %I',
            current_database(),
            role_name
        );
    END LOOP;
END $setup$;

DO $boundary_setup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE usename IN ('quoteedge', '"quoteedge"')
       AND pid <> pg_backend_pid();
    BEGIN
        EXECUTE format('DROP OWNED BY %I', '"quoteedge"');
    EXCEPTION
        WHEN undefined_object THEN NULL;
    END;
    EXECUTE format('DROP ROLE IF EXISTS %I', '"quoteedge"');
    EXECUTE 'DROP ROLE IF EXISTS quoteedge';
    EXECUTE 'CREATE ROLE quoteedge LOGIN';
    EXECUTE format('CREATE ROLE %I LOGIN', '"quoteedge"');
    PERFORM df.grant_usage('"quoteedge"');
    EXECUTE format(
        'GRANT TEMPORARY ON DATABASE %I TO %I',
        current_database(),
        '"quoteedge"'
    );
END $boundary_setup$;

SET SESSION AUTHORIZATION "labUser";
CREATE TEMP TABLE _test_state_quoted_1 (instance_id TEXT);
INSERT INTO _test_state_quoted_1
SELECT df.start('SELECT 1 AS ok', 'quoted-role-labuser');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "role with space";
CREATE TEMP TABLE _test_state_quoted_2 (instance_id TEXT);
INSERT INTO _test_state_quoted_2
SELECT df.start('SELECT 1 AS ok', 'quoted-role-space');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION "role""with""quote";
CREATE TEMP TABLE _test_state_quoted_3 (instance_id TEXT);
INSERT INTO _test_state_quoted_3
SELECT df.start('SELECT 1 AS ok', 'quoted-role-embedded-quote');
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION """quoteedge""";
CREATE TEMP TABLE _test_state_quoted_4 (instance_id TEXT);
INSERT INTO _test_state_quoted_4
SELECT df.start('SELECT current_user AS who', 'quoted-role-boundary');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    node_role TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_quoted_1;
    SELECT df.await_instance(inst_id, 30) INTO final_status;
    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (labUser): expected completed, got %', final_status;
    END IF;
    SELECT r.rolname INTO node_role
      FROM df.nodes n
      JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
     WHERE n.instance_id = inst_id
     LIMIT 1;
    IF node_role != 'labUser' THEN
        RAISE EXCEPTION 'TEST FAILED (labUser): expected submitted_by rolname labUser, got %', node_role;
    END IF;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    node_role TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_quoted_2;
    SELECT df.await_instance(inst_id, 30) INTO final_status;
    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (role with space): expected completed, got %', final_status;
    END IF;
    SELECT r.rolname INTO node_role
      FROM df.nodes n
      JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
     WHERE n.instance_id = inst_id
     LIMIT 1;
    IF node_role != 'role with space' THEN
        RAISE EXCEPTION 'TEST FAILED (role with space): expected submitted_by rolname role with space, got %', node_role;
    END IF;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    node_role TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_quoted_3;
    SELECT df.await_instance(inst_id, 30) INTO final_status;
    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (role"with"quote): expected completed, got %', final_status;
    END IF;
    SELECT r.rolname INTO node_role
      FROM df.nodes n
      JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
     WHERE n.instance_id = inst_id
     LIMIT 1;
    IF node_role != 'role"with"quote' THEN
        RAISE EXCEPTION 'TEST FAILED (role"with"quote): expected submitted_by rolname role"with"quote, got %', node_role;
    END IF;
END $$;

DO $$
DECLARE
    inst_id TEXT;
    final_status TEXT;
    node_role TEXT;
    ran_as TEXT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state_quoted_4;
    SELECT df.await_instance(inst_id, 30) INTO final_status;
    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED (boundary "quoteedge"): expected completed, got %', final_status;
    END IF;
    SELECT r.rolname INTO node_role
      FROM df.nodes n
      JOIN pg_catalog.pg_roles r ON r.oid = n.submitted_by::oid
     WHERE n.instance_id = inst_id
     LIMIT 1;
    IF node_role != '"quoteedge"' THEN
        RAISE EXCEPTION 'TEST FAILED (boundary): expected submitted_by rolname "quoteedge" (quotes included), got %', node_role;
    END IF;
    SELECT (result->'rows'->0->>'who') INTO ran_as
      FROM df.nodes
     WHERE instance_id = inst_id
       AND result IS NOT NULL
     LIMIT 1;
    IF ran_as != '"quoteedge"' THEN
        RAISE EXCEPTION 'TEST FAILED (boundary): workflow executed as %, expected literal "quoteedge"', ran_as;
    END IF;
END $$;

DROP TABLE _test_state_quoted_1;
DROP TABLE _test_state_quoted_2;
DROP TABLE _test_state_quoted_3;
DROP TABLE _test_state_quoted_4;

DO $cleanup$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['labUser', 'role with space', 'role"with"quote']
    LOOP
        PERFORM pg_terminate_backend(pid)
          FROM pg_stat_activity
         WHERE usename = role_name
           AND pid <> pg_backend_pid();
        BEGIN
            EXECUTE format('DROP OWNED BY %I', role_name);
        EXCEPTION
            WHEN undefined_object THEN NULL;
        END;
        EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
    END LOOP;
END $cleanup$;

DO $boundary_cleanup$
BEGIN
    PERFORM pg_terminate_backend(pid)
      FROM pg_stat_activity
     WHERE usename IN ('quoteedge', '"quoteedge"')
       AND pid <> pg_backend_pid();
    BEGIN
        EXECUTE format('DROP OWNED BY %I', '"quoteedge"');
    EXCEPTION
        WHEN undefined_object THEN NULL;
    END;
    EXECUTE format('DROP ROLE IF EXISTS %I', '"quoteedge"');
    EXECUTE 'DROP ROLE IF EXISTS quoteedge';
END $boundary_cleanup$;

SELECT 'TEST PASSED' AS result;
