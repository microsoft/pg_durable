-- E2E Test: GitHub API Integration
-- Fetches pull requests from a real GitHub repository
-- Demonstrates real-world HTTP API usage

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
-- Test: Fetch GitHub Pull Requests
-- ============================================================================

CREATE TEMP TABLE _test_github (instance_id TEXT);

INSERT INTO _test_github SELECT df.start(
    (df.http(
        'https://api.github.com/repos/affandar/duroxide/pulls?state=all&per_page=5',
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
        RETURNING pr_number',
    'test-fetch-github-prs'
);

DO $$
DECLARE
    inst_id TEXT;
    status TEXT;
    pr_count INT;
    attempts INT := 0;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_github;
    RAISE NOTICE 'Testing GitHub API fetch: %', inst_id;
    
    LOOP
        SELECT s INTO status FROM df.status(inst_id) s;
        EXIT WHEN lower(status) IN ('completed', 'failed', 'canceled') OR attempts > 300;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;
    
    IF lower(status) != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: GitHub API fetch status = %', status;
    END IF;
    
    -- Verify we got some PRs
    SELECT COUNT(*) INTO pr_count FROM github_prs;
    RAISE NOTICE 'Fetched % pull requests from GitHub', pr_count;
    
    IF pr_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: No PRs fetched from GitHub API';
    END IF;
    
    RAISE NOTICE 'TEST PASSED: github_api';
END $$;

-- Show the fetched PRs
SELECT pr_number, title, state, author, created_at FROM github_prs ORDER BY pr_number DESC;

DROP TABLE _test_github;

SELECT 'TEST PASSED' AS result;

