# Release Workflow Prompt

> Use this prompt to prepare and tag a new release of duroxide-pg-opt.

> **⚠️ IMPORTANT:** This is a **private repository**. Do NOT publish to public crates.io.
> The release workflow ends at git push - no `cargo publish` step.

## Instructions for AI Assistant

Execute the following release workflow steps in order. 

**On Failure:** If any step fails (tests fail, build errors, etc.), **STOP immediately** and present the user with options:
1. **Investigate** - Analyze the failure and attempt to fix it
2. **Skip** - Skip this step and continue (user takes responsibility)
3. **Abort** - Cancel the release workflow entirely

Do not proceed to the next step until the current step passes or the user explicitly chooses to skip.

### 1. Pre-Release Checks

#### 1.1 Clean Warnings and Errors

```bash
# Check for compiler warnings (treat warnings as errors)
cargo clippy --all-targets --all-features -- -D warnings

# Check formatting
cargo fmt --check

# If there are issues, fix them:
cargo fmt
# Then address any clippy warnings
```

#### 1.2 Build All Targets

```bash
# Build main crate
cargo build --release

# Build pg-stress binary
cd pg-stress && cargo build --release && cd ..

# Build with all feature combinations
cargo build --release --all-features
cargo build --release --no-default-features
```

#### 1.3 Run Tests

> **IMPORTANT:** All tests must be run against **localhost PostgreSQL**, not a remote database.
> Remote databases have higher latency that causes timing-sensitive tests to fail.
> Ensure `DATABASE_URL` in `.env` points to `localhost` or `127.0.0.1` before running tests.

```bash
# Verify DATABASE_URL points to localhost
grep DATABASE_URL .env  # Should contain localhost or 127.0.0.1

# Unit tests
cargo test --lib

# Integration tests (requires DATABASE_URL pointing to localhost)
cargo test --test postgres_provider_test

# All tests
cargo test

# Stress tests (optional, for major releases)
./scripts/run-stress-tests.sh --duration 30
```

### 2. Version Bump

#### 2.1 Determine Version

Current version is in `Cargo.toml`. Follow semver:
- **PATCH** (0.1.x → 0.1.y): Bug fixes, documentation updates
- **MINOR** (0.x.0 → 0.y.0): New features, backward-compatible changes
- **MAJOR** (x.0.0 → y.0.0): Breaking changes

#### 2.2 Update Cargo.toml Files

Update version in:
- `/Cargo.toml` (main crate)
- `/pg-stress/Cargo.toml` (stress test binary, if applicable)

Also update the `duroxide-pg-opt` dependency version in `pg-stress/Cargo.toml` if it references a specific version.

### 3. Documentation Updates

#### 3.1 Capture Duroxide Dependency Changes

If the duroxide dependency version was updated since the last release, document the changes:

```bash
# Check if duroxide version changed
git diff HEAD~10 -- Cargo.toml | grep duroxide

# If version changed, get the changelog between versions
# Visit: https://github.com/microsoft/duroxide/compare/v{OLD_VERSION}...v{NEW_VERSION}
# Or check the duroxide CHANGELOG.md for the versions in between
```

Include in the release notes:
- **From version** → **To version** (e.g., 0.1.10 → 0.1.11)
- Key changes that affect duroxide-pg-opt:
  - New Provider trait methods added
  - Breaking API changes
  - New validation tests that need implementation
  - Bug fixes that may affect provider behavior

Example CHANGELOG entry:
```markdown
### Dependencies
- Updated `duroxide` from 0.1.10 to 0.1.11
  - Added lock-stealing cancellation support (new `cancelled_activities` parameter)
  - Removed `execution_status` from fetch/renew returns
  - New validation tests: `cancellation::test_cancelled_activities_*`
```

#### 3.2 Update CHANGELOG.md

Add a new section at the top following this format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- New feature description

### Changed
- Change description

### Fixed
- Bug fix description

### Removed
- Removed feature description
```

Include:
- All user-facing changes since last release
- Breaking changes (highlighted)
- Migration notes if applicable

#### 3.3 Update README.md

Review and update if needed:
- Version references
- Installation instructions
- Feature documentation
- Example code
- Badge versions (if any)

#### 3.4 Update Other Docs

Check `docs/` folder for any documentation that needs updating:
- Design documents
- API changes
- Configuration options

### 4. Final Verification

```bash
# Ensure everything still builds after changes
cargo build --release

# Run tests one more time
cargo test

# Check for uncommitted changes
git status
```

### 5. Commit and Tag

```bash
# Stage all changes
git add -A

# Commit with release message
git commit -m "chore: release v{VERSION}

- Bump version to {VERSION}
- Update CHANGELOG.md
- Update documentation"

# Create annotated tag
git tag -a v{VERSION} -m "Release v{VERSION}"

# Push commit and tag
git push origin main
git push origin v{VERSION}
```

### 6. Post-Release

- [ ] Verify tag appears in GitHub
- [ ] Create GitHub Release (optional) with CHANGELOG excerpt
- [ ] Update any dependent projects

---

## Checklist Summary

- [ ] `cargo clippy` passes with no warnings
- [ ] `cargo fmt --check` passes
- [ ] `cargo build --release` succeeds
- [ ] `cargo test` passes
- [ ] Version bumped in Cargo.toml
- [ ] Version bumped in pg-stress/Cargo.toml (if applicable)
- [ ] Duroxide dependency changes documented (if version changed)
- [ ] CHANGELOG.md updated with new version section
- [ ] README.md reviewed and updated
- [ ] All changes committed
- [ ] Tag created and pushed

---

## Example Usage

```
I need to create a new release. The changes since last release include:
- Fixed large payload test timeout for remote databases
- Added --duration flag to stress test script
- Fixed provider name reporting

Please execute the release workflow and bump to version 0.1.2.
```
