-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- df.grant_usage() adds df to the target role's search_path by default (so the
-- unqualified DSL operators resolve), set_search_path => false opts out, and
-- df.revoke_usage() removes the df entry again.  These are verified through the
-- pg_db_role_setting catalog rather than effective resolution, because a
-- role-level search_path only takes effect on the role's next connection.

-- Helpers: read the role's per-role search_path setting and test for tokens.
CREATE OR REPLACE FUNCTION pg_temp._gsp_path(p_role text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT substring(opt FROM 13)  -- strip leading 'search_path='
    FROM pg_db_role_setting s
    JOIN pg_roles r ON r.oid = s.setrole
    CROSS JOIN LATERAL unnest(s.setconfig) AS o(opt)
    WHERE r.rolname = p_role
      AND s.setdatabase = 0
      AND opt LIKE 'search_path=%'
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._gsp_df_count(p_role text) RETURNS int
LANGUAGE sql STABLE AS $$
    SELECT count(*)::int
    FROM unnest(string_to_array(coalesce(pg_temp._gsp_path(p_role), ''), ',')) AS t(tok)
    WHERE lower(btrim(tok, ' "')) = 'df';
$$;

CREATE OR REPLACE FUNCTION pg_temp._gsp_has(p_role text, p_tok text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM unnest(string_to_array(coalesce(pg_temp._gsp_path(p_role), ''), ',')) AS t(tok)
        WHERE lower(btrim(tok, ' "')) = lower(p_tok)
    );
$$;

-- Setup: four fresh roles exercising the distinct code paths.
DO $setup$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['gsp_default', 'gsp_optout', 'gsp_existing', 'gsp_idem']
    LOOP
        BEGIN
            EXECUTE format('DROP OWNED BY %I', role_name);
        EXCEPTION
            WHEN undefined_object THEN NULL;
        END;
        EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
        EXECUTE format('CREATE ROLE %I', role_name);
    END LOOP;

    -- gsp_existing already has a custom per-role search_path (no df).
    ALTER ROLE gsp_existing SET search_path = "$user", myschema;
END $setup$;

-- Grant: default adds df; opt-out does not; existing path is appended to;
-- repeated grants stay idempotent.
SELECT df.grant_usage('gsp_default');
SELECT df.grant_usage('gsp_optout', set_search_path => false);
SELECT df.grant_usage('gsp_existing');
SELECT df.grant_usage('gsp_idem');
SELECT df.grant_usage('gsp_idem');  -- second call must not duplicate df

DO $assert_grant$
BEGIN
    -- gsp_default: no prior path -> "$user", public, df
    IF pg_temp._gsp_path('gsp_default') IS NULL THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_default): expected a search_path setting, found none';
    END IF;
    IF pg_temp._gsp_df_count('gsp_default') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_default): expected exactly one df entry, path = %', pg_temp._gsp_path('gsp_default');
    END IF;
    IF NOT pg_temp._gsp_has('gsp_default', '$user') OR NOT pg_temp._gsp_has('gsp_default', 'public') THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_default): expected "$user" and public preserved, path = %', pg_temp._gsp_path('gsp_default');
    END IF;

    -- gsp_optout: set_search_path => false leaves no per-role setting
    IF pg_temp._gsp_path('gsp_optout') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_optout): expected no search_path setting, found %', pg_temp._gsp_path('gsp_optout');
    END IF;

    -- gsp_existing: df appended, original entries preserved
    IF pg_temp._gsp_df_count('gsp_existing') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_existing): expected exactly one df entry, path = %', pg_temp._gsp_path('gsp_existing');
    END IF;
    IF NOT pg_temp._gsp_has('gsp_existing', 'myschema') OR NOT pg_temp._gsp_has('gsp_existing', '$user') THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_existing): expected original entries preserved, path = %', pg_temp._gsp_path('gsp_existing');
    END IF;

    -- gsp_idem: granting twice must not add df twice
    IF pg_temp._gsp_df_count('gsp_idem') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_idem): expected exactly one df entry after two grants, path = %', pg_temp._gsp_path('gsp_idem');
    END IF;
END $assert_grant$;

-- Revoke: removes df, preserves the rest; opt-out role is an idempotent no-op.
SELECT df.revoke_usage('gsp_default');
SELECT df.revoke_usage('gsp_existing');
SELECT df.revoke_usage('gsp_optout');  -- never had df: must not error

DO $assert_revoke$
BEGIN
    -- gsp_default: df removed, "$user"/public remain
    IF pg_temp._gsp_df_count('gsp_default') <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_default revoke): expected df removed, path = %', pg_temp._gsp_path('gsp_default');
    END IF;
    IF NOT pg_temp._gsp_has('gsp_default', 'public') OR NOT pg_temp._gsp_has('gsp_default', '$user') THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_default revoke): expected "$user"/public preserved, path = %', pg_temp._gsp_path('gsp_default');
    END IF;

    -- gsp_existing: df removed, original entries preserved
    IF pg_temp._gsp_df_count('gsp_existing') <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_existing revoke): expected df removed, path = %', pg_temp._gsp_path('gsp_existing');
    END IF;
    IF NOT pg_temp._gsp_has('gsp_existing', 'myschema') OR NOT pg_temp._gsp_has('gsp_existing', '$user') THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_existing revoke): expected original entries preserved, path = %', pg_temp._gsp_path('gsp_existing');
    END IF;

    -- gsp_optout: still no per-role setting after a no-op revoke
    IF pg_temp._gsp_path('gsp_optout') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILED (gsp_optout revoke): expected no search_path setting, found %', pg_temp._gsp_path('gsp_optout');
    END IF;
END $assert_revoke$;

-- Cleanup
DO $cleanup$
DECLARE
    role_name TEXT;
BEGIN
    FOREACH role_name IN ARRAY ARRAY['gsp_default', 'gsp_optout', 'gsp_existing', 'gsp_idem']
    LOOP
        BEGIN
            EXECUTE format('DROP OWNED BY %I', role_name);
        EXCEPTION
            WHEN undefined_object THEN NULL;
        END;
        EXECUTE format('DROP ROLE IF EXISTS %I', role_name);
    END LOOP;
END $cleanup$;

DROP FUNCTION pg_temp._gsp_has(text, text);
DROP FUNCTION pg_temp._gsp_df_count(text);
DROP FUNCTION pg_temp._gsp_path(text);

SELECT 'TEST PASSED' AS result;
