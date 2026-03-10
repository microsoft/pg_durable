# Merge Branch to Main

## Objective
Commit all changes on the current branch and merge into `main` with proper commit messages.

## Steps

### 1. Review Current Changes
- Run `git status` to see all uncommitted changes
- Review the changes to ensure they're ready for commit
- Check that no temporary files or debug code is included

### 2. Verify Tests Pass
Before committing, ensure all tests pass:

```bash
# Unit tests
./scripts/test-unit.sh

# E2E tests (local)
./scripts/test-e2e-local.sh

# E2E tests (Docker - if product code changed)
./scripts/test-e2e-docker.sh --rebuild
```

### 3. Commit Current Branch
- Create a descriptive commit message that:
  - Summarizes what was changed/added/fixed
  - Uses imperative mood (e.g., "Add feature" not "Added feature")
  - Includes context if the change is part of a larger effort
- Stage all relevant changes: `git add -A`
- Commit: `git commit -m "Your message here"`

### 4. Merge to Main
- Checkout main: `git checkout main`
- Pull latest: `git pull origin main` (if working with remote)
- Merge your branch: `git merge your-branch-name`
- The merge commit message should:
  - Summarize ALL work done in this branch beyond main
  - Highlight key features/changes added
  - Note any breaking changes (especially SQL API changes)
  - Reference related issues/PRs if applicable

### 5. Push to Remote
- Push main: `git push origin main`
- Verify the push succeeded

### 6. Deploy (Optional)
If deploying to ACR after merge:

```bash
# Login to ACR (if not already)
az acr login --name toygresacr

# Deploy
./scripts/deploy-acr.sh
```

## Guidelines
- **DO NOT** use `--force` or `--force-with-lease` unless explicitly instructed
- **DO NOT** skip commit hooks with `--no-verify`
- **DO NOT** commit or merge without user approval
- **DO** ensure all tests pass before merging
- **DO** run `cargo fmt` and `cargo clippy --features pg17` before committing
- **DO** create meaningful commit messages that future readers can understand

## Example Commit Messages

Good branch commit:
```
Add new operators for control flow

- Implement & operator for parallel join
- Implement | operator for race
- Implement ?> and !> operators for if-then-else
- Implement @> operator for loop
- Update all E2E tests with operator variants
```

Good merge commit:
```
Merge feature-operators: Add SQL operators for all DSL functions

This branch adds intuitive SQL operators for pg_durable:

- & for parallel join (df.join)
- | for race (df.race)  
- ?> and !> for conditionals (df.if)
- @> for loops (df.loop)

Also includes:
- Schema renamed from 'durable' to 'df'
- E2E tests updated with both operator and function variants
- USER_GUIDE.md updated with new syntax
- LLM prompts for development tasks

Breaking changes:
- Schema renamed: durable.* -> df.*
- All SQL functions now under df schema
```

## Pre-Commit Checklist

Before asking user to approve commit:

- [ ] `cargo build --features pg17` succeeds
- [ ] `cargo clippy --features pg17` has no warnings
- [ ] `cargo fmt --check` shows no changes needed
- [ ] `./scripts/test-unit.sh` passes
- [ ] `./scripts/test-e2e-local.sh` passes (all tests)
- [ ] No debug/temporary code left in changes
- [ ] Commit message is descriptive and accurate

