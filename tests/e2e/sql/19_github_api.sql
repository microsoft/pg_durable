-- E2E Test: GitHub API Integration
-- Fetches pull requests from a real GitHub repository using durable function variables
-- Demonstrates: HTTP API, vars, loop with schedule pattern

-- ============================================================================
-- Setup: Create table to store PR data
-- ============================================================================

DROP TABLE IF EXISTS github_prs;
CREATE TABLE github_prs (
    id SERIAL PRIMARY KEY,
    pr_number INT UNIQUE,
    title TEXT,
    state TEXT,
    author TEXT,
    created_at TIMESTAMPTZ,
    url TEXT,
    fetched_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- Configure API using durable function variables
-- ============================================================================

SELECT df.clearvars();
SELECT df.setvar('github_url', 'https://api.github.com/repos/affandar/duroxide/pulls?state=all&per_page=5');

-- ============================================================================
-- Test: Scheduled GitHub PR Fetcher (Loop Pattern)
-- In production this would run forever, fetching PRs every 30 minutes.
-- For testing, we cancel after one successful iteration.
-- ============================================================================

CREATE TEMP TABLE _test_github (instance_id TEXT);

-- Start a looping durable function that:
-- 1. Fetches PRs from GitHub using configured URL var
-- 2. Upserts them into the database
-- 3. Waits 30 minutes before next iteration
INSERT INTO _test_github SELECT df.start(
    @> (
        (df.http(
            '{github_url}',
            'GET',
            NULL,
            '{"Accept": "application/vnd.github.v3+json", "User-Agent": "pg_durable-test"}'::jsonb
        ) |=> 'response')
        ~> 'INSERT INTO github_prs (pr_number, title, state, author, created_at, url)
            SELECT 
                (pr->>''number'')::int,
                pr->>''title'',
                pr->>''state'',
                pr->''user''->>''login'',
                (pr->>''created_at'')::timestamptz,
                pr->>''html_url''
            FROM jsonb_array_elements(($response::jsonb->>''body'')::jsonb) AS pr
            ON CONFLICT (pr_number) DO UPDATE SET
                title = EXCLUDED.title,
                state = EXCLUDED.state,
                fetched_at = now()
            RETURNING pr_number'
        ~> df.wait_for_schedule('*/30 * * * *')  -- Every 30 minutes
    ),
    'github-pr-sync'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    pr_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_github;
    RAISE NOTICE 'Testing GitHub API with vars and loop: %', inst_id;
    
    -- Wait for first iteration to complete (status goes to 'running' during schedule wait)
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        -- Loop will be 'running' while waiting for schedule, check PR count instead
        SELECT COUNT(*) INTO pr_count FROM github_prs;
        EXIT WHEN pr_count > 0 OR lower(status) = 'failed' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: GitHub API fetch status = %', status;
    END IF;
    
    -- Verify we got some PRs
    SELECT COUNT(*) INTO pr_count FROM github_prs;
    RAISE NOTICE 'Fetched % pull requests from GitHub', pr_count;
    
    IF pr_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: No PRs fetched from GitHub API';
    END IF;
    
    -- Cancel the loop since we've verified it works
    PERFORM df.cancel(inst_id, 'Test completed - cancelling scheduled loop');
    RAISE NOTICE 'Cancelled scheduled loop after successful first iteration';
    
    RAISE NOTICE 'TEST PASSED: github_api_with_vars_and_loop';
END $$;

-- Show the fetched PRs
SELECT pr_number, title, state, author, created_at FROM github_prs ORDER BY pr_number DESC;

-- Cleanup
DROP TABLE _test_github;
SELECT df.clearvars();

SELECT 'TEST PASSED' AS result;

