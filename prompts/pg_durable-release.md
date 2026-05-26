# Release Workflow

## Objective
Prepare and release a new version of pg_durable with quality checks, documentation updates, and optional Docker deployment.

## Step 1: Check for Dependency Updates

### 1.1 Check duroxide Dependencies

The project uses these duroxide dependencies from `Cargo.toml`:
- `duroxide` (crates.io version)
- `duroxide-pg` (crates.io version)

**Check for new duroxide version:**
```bash
# Check current version in Cargo.toml
grep "duroxide" Cargo.toml

# Check latest version on crates.io
cargo search duroxide --limit 5
```

**Check for new duroxide-pg version:**
```bash
# Check latest version on crates.io
cargo search duroxide-pg --limit 5
```

Before proposing a `duroxide-pg` update, check its release notes or compatibility matrix to determine whether the `duroxide` crate must also be updated. Treat the two versions as a compatible pair, not independent choices.

### 1.2 Ask User About Updates

If new versions are available, present them to the user:

```
📦 Dependency Update Check:

Current versions:
  - duroxide: 0.1.6
  - duroxide-pg: v0.1.1

New versions available:
  - duroxide: [new_version] ✨
  - duroxide-pg: [new_version] ✨

Would you like to update to the new versions? (y/n)
```

**If user approves updates:**

Update the dependency versions in `Cargo.toml`:
```toml
# duroxide = "NEW_VERSION"
# duroxide-pg = "NEW_VERSION"
```

Then refresh `Cargo.lock`:
```bash
# If only duroxide-pg changed:
cargo update -p duroxide-pg

# If both changed:
cargo update -p duroxide -p duroxide-pg
```

## Step 2: Update Package Version (if releasing)

### 2.1 Ask User About Version Bump

If this is a release (not just a dependency update), ask:

```
📦 Version Update:

Current version in Cargo.toml: X.Y.Z

Would you like to bump the version? (y/n)
  1. Patch bump (X.Y.Z → X.Y.Z+1) - for bug fixes, dependency updates
  2. Minor bump (X.Y.Z → X.Y+1.0) - for new features
  3. Major bump (X.Y.Z → X+1.0.0) - for breaking changes
  4. Custom version
  5. Skip version bump
```

### 2.2 Update Cargo.toml Version

If user approves, update the version in `Cargo.toml`:
```toml
[package]
name = "pg_durable"
version = "NEW_VERSION"
```

## Step 3: Build and Clean Warnings

### 3.1 Build the Extension
```bash
cargo build --features pg17
```

- Check for compilation errors
- Note any new warnings

### 3.2 Run Clippy
```bash
cargo clippy --features pg17 -- -W clippy::all
```

- Address all clippy warnings
- Do NOT silence warnings with `#[allow(...)]` without understanding them

### 3.3 Fix Warnings

Follow the guidance in `@pg_durable-clean-warnings.md`:

**❌ DO NOT:**
- Add `#[allow(unused)]` without understanding why
- Prefix with `_` just to silence warnings
- Remove code that's part of public API

**✅ DO:**
- Investigate why code is unused
- Check if it's used in feature gates or tests
- Delete genuinely unused code
- Use `_name` for trait-required but unused parameters

### 3.4 Format Code
```bash
cargo fmt
```

### 3.5 Verify Clean Build
```bash
# Should produce no warnings
cargo build --features pg17 2>&1 | grep -c "warning:" || echo "0 warnings"
cargo clippy --features pg17 2>&1 | grep -c "warning:" || echo "0 warnings"
```

## Step 4: Update Documentation and Tests

Follow `@pg_durable-update-docs-tests.md` for comprehensive documentation updates.

### 4.1 Scan Changes
```bash
# See what changed since last release
git log --oneline main..HEAD

# Or if on main, see recent changes
git log --oneline -20

# See detailed diff
git diff --stat HEAD~10..HEAD
```

### 4.2 Update Documentation

Check and update as needed:
- **USER_GUIDE.md** - Main user documentation
- **README.md** - Project overview
- **docs/api-reference.md** - API documentation

### 4.3 Propose New Tests

For each significant change, propose tests:
- New DSL functions → E2E tests in `tests/e2e/sql/`
- New operators → E2E tests with both variants
- Bug fixes → Regression tests

**Ask user before implementing tests:**
```
📋 Proposed Tests:

Based on changes found, I recommend adding these tests:
1. [Test description] - tests/e2e/sql/NN_name.sql
2. [Test description] - tests/e2e/sql/NN_name.sql

Would you like me to implement these tests? (y/n/select numbers)
```

## Step 5: Run Tests

### 5.1 Unit Tests
```bash
./scripts/test-unit.sh
```

Expected output: All pgrx tests pass.

### 5.2 Local E2E Tests
```bash
./scripts/test-e2e-local.sh
```

Expected output: All SQL tests show `TEST PASSED`.

### 5.3 Handle Test Failures

If tests fail:
1. Review the error output
2. Check `~/.pgrx/17.log` for background worker logs
3. Fix issues and re-run
4. Do NOT proceed to Docker/release until all tests pass

## Step 6: Docker Testing (Optional)

### 6.1 Ask User
```
✅ All local tests passed!

Would you like to build and test the Docker container? (y/n)
  - This will build a fresh Docker image with the extension
  - Run E2E tests inside the container
  - Useful for verifying the release will work in production
```

### 6.2 Build and Test Docker
```bash
# Build and run E2E tests in Docker
./scripts/test-e2e-docker.sh --rebuild
```

This will:
- Build a new Docker image with pg_durable
- Start a container with PostgreSQL
- Run all E2E tests
- Report results

### 6.3 Handle Docker Test Failures

If Docker tests fail but local tests passed:
- Check for environment differences
- Review Docker logs: `docker logs <container_id>`
- Ensure all dependencies are properly included

## Step 7: Deploy to ACR (Optional)

### 7.1 Ask User
```
✅ Docker tests passed!

Would you like to push the image to Azure Container Registry? (y/n)
  - Registry: ${ACR_REGISTRY:-toygresacr.azurecr.io}
  - Image: ${ACR_IMAGE:-pg_durable}
  
Options:
  1. Push as :latest only
  2. Push as :latest AND with a version tag (e.g., :v0.1.0)
  3. Push with version tag only (specify tag)
  4. Skip
```

If user selects option 2 or 3, ask for the version tag:
```
Enter version tag (e.g., v0.1.6): 
```

### 7.2 Login to ACR (if needed)
```bash
# Check if already logged in
docker pull toygresacr.azurecr.io/pg_durable:latest 2>/dev/null && echo "Already logged in" || az acr login --name toygresacr
```

### 7.3 Deploy
```bash
# Push as latest
./scripts/deploy-acr.sh

# Or with a specific tag
./scripts/deploy-acr.sh --tag v0.1.0

# Force rebuild before push
./scripts/deploy-acr.sh --rebuild --tag v0.1.0
```

### 7.4 Verify Deployment
```bash
# List images in registry
az acr repository show-tags --name toygresacr --repository pg_durable --output table
```

## Step 8: Review, Commit, and Push

### 8.1 Review All Changes

Present changes to the user for review:
```bash
git status
git diff --stat
```

**Ask user to review:**
```
📋 Changes Summary:

Files modified:
  - Cargo.toml (dependency updates, version bump)
  - src/*.rs (import changes)
  - [other files]

Please review the changes above. 

Options:
  1. Show full diff (git diff)
  2. Show diff for specific file
  3. Accept changes and continue
  4. Abort release
```

### 8.2 Show Detailed Diff (if requested)
```bash
# Full diff
git diff

# Specific file
git diff path/to/file.rs
```

### 8.3 Compose Commit Message

**Ask user for commit message:**
```
📝 Compose commit message:

Suggested message based on changes:
  "Release v0.1.X: Update duroxide dependencies

  - Bump version from X.Y.Z to X.Y.Z+1
  - Upgrade duroxide from vA.B.C to vX.Y.Z
  - Upgrade duroxide-pg from vA.B.C to vX.Y.Z
  - [other changes]"

Would you like to:
  1. Use suggested message
  2. Edit message
  3. Cancel
```

### 8.4 Commit Changes (with user approval)
```bash
git add -A
git commit -m "Your commit message here"
```

### 8.5 Merge to Main (if on feature branch)

Check current branch:
```bash
git branch --show-current
```

If not on main:
```bash
# Checkout main
git checkout main

# Pull latest
git pull origin main

# Merge feature branch
git merge <feature-branch>
```

### 8.6 Push to Remote

**Ask user before pushing:**
```
🚀 Ready to push to remote:

Branch: main
Remote: origin
Commits to push: [number]

Would you like to push? (y/n)
```

```bash
git push origin main
```

### 8.7 Create Release Tag (Optional)

**Ask user about tagging:**
```
🏷️ Would you like to create a release tag? (y/n)

Suggested tag: v0.1.X (based on version in Cargo.toml)
```

```bash
# Create annotated tag
git tag -a v0.1.X -m "Release v0.1.X: [description]"

# Push tag
git push origin v0.1.X
```

### 8.8 Verify Push
```bash
# Check remote status
git log --oneline origin/main -5

# Verify tag (if created)
git ls-remote --tags origin | tail -5
```

## Step 9: Final Verification

### 9.1 Display Expected Version

At the end of the release, display the expected version string for verification:

```
✅ Release Complete!

Expected df.version() output:
  X.Y.Z (built YYYY-MM-DDTHH:MM:SSZ)

To verify after deployment, connect to a pg_durable instance and run:
  SELECT df.version();

The version should match the build timestamp from:
  - Docker build: check the "pg_durable version:" line from E2E test output
  - ACR image: the image was pushed at [timestamp]
```

### 9.2 Get Version Info
```bash
# Get version from Cargo.toml
grep '^version' Cargo.toml

# Get build timestamp from most recent Docker build
docker inspect pg_durable:latest --format '{{.Created}}'
```

## Checklist Summary

### Pre-Release Checklist
- [ ] Check for dependency updates (duroxide, duroxide-pg)
- [ ] Update dependencies if user approves
- [ ] Bump version in Cargo.toml if releasing
- [ ] `cargo build --features pg17` - no errors
- [ ] `cargo clippy --features pg17` - no warnings
- [ ] `cargo fmt` - code formatted
- [ ] Documentation reviewed and updated
- [ ] New tests proposed and implemented (if applicable)
- [ ] `./scripts/test-unit.sh` - all pass
- [ ] `./scripts/test-e2e-local.sh` - all pass

### Optional Deployment Checklist
- [ ] `./scripts/test-e2e-docker.sh --rebuild` - all pass
- [ ] `./scripts/deploy-acr.sh` - image pushed
- [ ] Verify image in registry

### Post-Release
- [ ] User reviewed all changes
- [ ] Changes committed with descriptive message
- [ ] Merged to main (if on feature branch)
- [ ] Pushed to remote
- [ ] Tag created for release (optional)
- [ ] Changelog updated (optional)

## Common Issues

### 1. Dependency Update Fails
```bash
# Clear cargo cache and retry
cargo clean
cargo update
cargo build --features pg17
```

### 2. pgrx Version Mismatch
If updating duroxide causes pgrx conflicts:
- Check both use same pgrx version
- May need to update pgrx in Cargo.toml

### 3. Docker Build Fails
```bash
# Check Docker daemon is running
docker info

# Clean Docker cache
docker builder prune -f

# Rebuild from scratch
docker build --no-cache -t pg_durable_e2e_test .
```

### 4. ACR Push Fails
```bash
# Re-authenticate
az acr login --name toygresacr

# Check network/permissions
az acr show --name toygresacr --query "loginServer"
```

## ⚠️ IMPORTANT: User Approval Required

**DO NOT** proceed with these actions without explicit user approval:
- Updating dependencies in Cargo.toml
- Implementing new tests
- Building Docker images
- Pushing to ACR
- Committing changes
- Merging to main
- Pushing to remote
- Creating tags

Always present options and wait for user confirmation before proceeding.
