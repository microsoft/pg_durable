-- E2E Test: GitHub API Integration
-- Fetches commits from a real GitHub repository using durable function variables
-- Demonstrates: HTTP API, vars, loop with schedule pattern

-- ============================================================================
-- Setup: Create table to store commit data
-- ============================================================================

DROP TABLE IF EXISTS github_commits;
CREATE TABLE github_commits (
    id SERIAL PRIMARY KEY,
    sha TEXT UNIQUE,
    author TEXT,
    message TEXT,
    committed_at TIMESTAMPTZ,
    fetched_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================================
-- Configure API using durable function variables
-- ============================================================================

SELECT df.clearvars();
SELECT df.setvar('github_url', 'https://api.github.com/repos/microsoft/duroxide/commits?per_page=5');

-- ============================================================================
-- Test: Scheduled GitHub Commit Fetcher (Loop Pattern)
-- In production this would run forever, fetching commits every 30 minutes.
-- For testing, we cancel after one successful iteration.
-- ============================================================================

CREATE TEMP TABLE _test_github (instance_id TEXT);

-- Start a looping durable function that:
-- 1. Fetches commits from GitHub using configured URL var
-- 2. Upserts them into the database (sha, author, message only)
-- 3. Waits 30 minutes before next iteration
INSERT INTO _test_github SELECT df.start(
    @> (
        (df.http(
            '{github_url}',
            'GET',
            NULL,
            '{"Accept": "application/vnd.github.v3+json", "User-Agent": "pg_durable-test"}'::jsonb
        ) |=> 'response')
        ~> 'INSERT INTO github_commits (sha, author, message, committed_at)
            SELECT 
                c->>''sha'',
                c->''commit''->''author''->>''name'',
                c->''commit''->>''message'',
                (c->''commit''->''author''->>''date'')::timestamptz
            FROM jsonb_array_elements(($response::jsonb->>''body'')::jsonb) AS c
            ON CONFLICT (sha) DO UPDATE SET
                fetched_at = now()
            RETURNING sha'
        ~> df.wait_for_schedule('*/30 * * * *')  -- Every 30 minutes
    ),
    'github-commit-sync'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    commit_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_github;
    RAISE NOTICE 'Testing GitHub API with vars and loop: %', inst_id;
    
    -- Wait for first iteration to complete (status goes to 'running' during schedule wait)
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        -- Loop will be 'running' while waiting for schedule, check commit count instead
        SELECT COUNT(*) INTO commit_count FROM github_commits;
        EXIT WHEN commit_count > 0 OR lower(status) = 'failed' OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) = 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: GitHub API fetch status = %', status;
    END IF;
    
    -- Verify we got some commits
    SELECT COUNT(*) INTO commit_count FROM github_commits;
    RAISE NOTICE 'Fetched % commits from GitHub', commit_count;
    
    IF commit_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: No commits fetched from GitHub API';
    END IF;
    
    -- Cancel the loop since we've verified it works
    PERFORM df.cancel(inst_id, 'Test completed - cancelling scheduled loop');
    RAISE NOTICE 'Cancelled scheduled loop after successful first iteration';
    
    RAISE NOTICE 'TEST PASSED: github_api_with_vars_and_loop';
END $$;

-- Show the fetched commits
SELECT sha, author, committed_at, LEFT(message, 50) AS message FROM github_commits ORDER BY committed_at DESC;

-- Cleanup
DROP TABLE _test_github;
DROP TABLE github_commits;
SELECT df.clearvars();

SELECT 'TEST PASSED' AS result;
