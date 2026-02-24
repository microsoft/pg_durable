---
description: Fix CI failures on pull requests by analyzing logs, identifying root causes, and applying targeted fixes
on:
  pull_request:
    types: [labeled]
if: github.event.label.name == 'fix-ci'
permissions:
  contents: read
  actions: read
  issues: read
  pull-requests: read
tools:
  github:
    toolsets: [default, actions]
network:
  allowed: [defaults, rust]
safe-outputs:
  add-comment:
    max: 5
  noop:
---

# Fix PR CI Failures

You are an AI coding agent that fixes CI failures on pull requests for **pg_durable**, a PostgreSQL extension built with pgrx (Rust).

Your goal is to get all CI checks passing on this pull request. Work directly on the PR branch -- do not create new branches or pull requests.

## Project Context

pg_durable is a PostgreSQL extension that provides durable SQL function execution. It uses **pgrx 0.16.1** (Rust) and runs entirely inside PostgreSQL.

Key commands:
- `cargo fmt --all` -- auto-fix formatting
- `cargo clippy --no-default-features --features pg17 -- -D warnings` -- lint (PG17)
- `cargo clippy --no-default-features --features pg18 -- -D warnings` -- lint (PG18)
- `cargo pgrx test pg17` -- unit tests
- `./scripts/test-e2e-local.sh` -- E2E tests
- `./scripts/test-e2e-local.sh --pg-version 18` -- E2E tests against PG18

Refer to `.github/copilot-instructions.md` for full project conventions.

## CI Structure

The CI pipeline (`.github/workflows/ci.yml`) runs these jobs:

1. **Format Check** -- `cargo fmt --all -- --check`
2. **Clippy & Tests (PG17)** -- clippy, unit tests, E2E tests against PostgreSQL 17
3. **Clippy & Tests (PG18)** -- same steps against PostgreSQL 18 (**non-blocking**: uses `continue-on-error: true`)

Because PG18 uses `continue-on-error`, the overall CI status can appear **green even when PG18 failed**. You must inspect individual job conclusions to detect PG18 failures.

## Steps

### Phase 1: Identify Failures

1. Get the PR number from the event context: `${{ github.event.pull_request.number }}`

2. Look up the PR's head branch and find the latest CI workflow run:
   ```
   BRANCH=$(gh pr view ${{ github.event.pull_request.number }} --json headRefName --jq .headRefName)
   gh run list --branch "$BRANCH" --workflow ci.yml --limit 5 --json databaseId,status,conclusion
   ```

3. **If the latest CI run is still `in_progress`**, wait for it to finish before proceeding. Poll every 30 seconds:
   ```
   gh run watch <run-id> --exit-status || true
   ```
   This blocks until the run completes. The `|| true` ensures you continue even if the run fails (which is expected).

4. Check **individual job conclusions** (not just the overall run conclusion):
   ```
   gh run view <run-id> --json jobs --jq '.jobs[] | {name, conclusion, status}'
   ```

5. Classify each job as `success`, `failure`, or `skipped`.

6. If ALL jobs succeeded (including PG18), call the `noop` safe output with a message that CI is already passing and stop.

### Phase 2: Fix PG17 Failures First

PG17 failures block the PR. Fix these before looking at PG18.

1. Retrieve logs for the failing job:
   ```
   gh run view <run-id> --log-failed
   ```

2. Identify the failing step and root cause. Common patterns:

   | Failing Step | Likely Cause | Fix Strategy |
   |---|---|---|
   | Format Check | Unformatted code | Run `cargo fmt --all`, commit |
   | Run clippy | Compiler warnings/errors | Read the diagnostic, fix the code |
   | Run unit tests | Test assertion failure | Fix the code or update the test |
   | Run E2E tests | SQL test failure | Check the test SQL, fix code or test |

3. **If E2E tests failed**, download the PostgreSQL log artifact for additional context:
   ```
   gh run download <run-id> --name postgresql-logs-pg17 --dir /tmp/pg-logs
   cat /tmp/pg-logs/*.log
   ```
   These logs contain the background worker output (duroxide orchestrations, activity errors, panics) which is often not visible in the CI step output. Look for `PANIC`, `ERROR`, `FATAL`, or Rust backtraces.

4. Apply a minimal, targeted fix using the edit tool. After editing, run `cargo fmt --all` to ensure formatting is correct. The Copilot engine will commit and push your changes automatically.

5. Wait for CI to re-run. Re-check job conclusions.

6. Repeat up to **3 attempts** for PG17. If still failing, post a comment on the PR explaining what was tried and why it could not be resolved.

### Phase 3: Fix PG18 Failures (only after PG17 is green)

PG18 uses `continue-on-error: true`, so its failures don't block the PR but should still be fixed when possible.

1. Re-check job conclusions after PG17 is green. Look for PG18 job with `conclusion: failure`.

2. If PG18 passed, call the `noop` safe output with a success message and stop.

3. If PG18 failed, retrieve its logs:
   ```
   gh run view <run-id> --log --job <pg18-job-id> | tail -200
   ```

4. If the failure is in E2E tests, also download the PostgreSQL log artifact:
   ```
   gh run download <run-id> --name postgresql-logs-pg18 --dir /tmp/pg-logs-18
   cat /tmp/pg-logs-18/*.log
   ```

5. Attempt a fix. Be careful:
   - PG18 failures are often caused by pgrx/PostgreSQL API differences between versions.
   - Fixes must not break PG17. Use `#[cfg(feature = "pg18")]` for version-specific code if needed.
   - If the failure is in an upstream dependency (pgrx, PostgreSQL 18 beta), it may not be fixable -- note this in a comment.

6. Commit, push, and re-check. Allow up to **2 attempts** for PG18.

7. If PG18 cannot be fixed, post a comment on the PR noting the PG18 failure and why it is unresolved. This is acceptable since PG18 is non-blocking.

## Constraints

- Do not create new branches or open new pull requests.
- Only modify files directly related to the CI failure.
- Keep commits small, focused, and easy to review.
- Do not refactor or optimize unrelated code.
- **Do not** add `#[allow(unused)]` or `#[allow(dead_code)]` to silence warnings -- investigate and fix properly.
- **Do not** prefix variables with `_` just to silence unused warnings -- delete genuinely unused code instead.
- After any code change, run `cargo fmt --all` before committing.

## Safe Outputs

- When CI is already passing or all fixes are applied successfully, call the `noop` safe output with a summary message.
- When you need to report status, unresolvable failures, or explain what was fixed, use the `add-comment` safe output on the triggering pull request.
