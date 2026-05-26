# Check Upstream Fixes and Update Dependencies

**Purpose:** Check if fixes for tracked blockers have been released in upstream dependencies (duroxide-pg) and guide updating pg_durable.

---

## Instructions

### Step 1: Review Active Blockers

Read the active blockers in `docs/dep_issues.md` to understand what issues we're tracking.

### Step 2: Check Issue Status

For each active blocker, check if the GitHub issue has been closed/resolved:

```bash
# Check issue status (replace ISSUE_NUMBER with actual number)
gh issue view <ISSUE_NUMBER> --repo microsoft/duroxide-pg --json state,title,closedAt
```

If the issue is still open, stop here - no action needed.

### Step 3: Check if Fix is in a Release

If an issue is closed, check if it's included in a release:

```bash
# List recent releases
gh release list --repo microsoft/duroxide-pg --limit 10

# Check what version we currently use
grep 'duroxide-pg' Cargo.toml
```

Compare the release date with the issue close date. If there's a release after the issue was closed, the fix is likely available.

### Step 4: Review Release Notes

```bash
# View specific release notes (replace TAG with version like v0.1.7)
gh release view <TAG> --repo microsoft/duroxide-pg
```

Confirm the fix is mentioned in the release notes.

### Step 5: Update Dependency

If a fix is available in a new release:

1. **Check duroxide compatibility** before bumping `duroxide-pg`. Use the release notes or compatibility matrix to determine whether `duroxide` must also be updated, then refresh the lockfile for the package set you changed:
   ```bash
   # Edit Cargo.toml: duroxide-pg = "0.1.X"
   # If required, also edit Cargo.toml: duroxide = "0.1.Y"
   cargo update -p duroxide-pg
   # Or, when both changed:
   cargo update -p duroxide -p duroxide-pg
   ```

2. **If duroxide also needs to be updated**:
   ```toml
   duroxide = "0.1.X"
   ```

3. **Build and test**:
   ```bash
   cargo build
   ./scripts/test-e2e-local.sh --clean
   ```

### Step 6: Remove Workarounds

Search for workaround code related to the fixed issue:

```bash
grep -rn "STOPGAP\|BLOCKED on duroxide" --include="*.rs" .
```

For each workaround related to the fixed issue:
1. Remove the workaround code
2. Run tests to confirm the fix works without the workaround
3. Update any affected documentation

### Step 7: Update Tracking Documents

1. **Move the blocker to "Resolved Blockers"** in `docs/dep_issues.md`:
   - Change status to ✅ Resolved
   - Add "Fixed In" version
   - Add resolution date

2. **Update the Version Compatibility Matrix** in the same file

3. **Update TODO.md** if the blocker was tracked there

### Step 8: Commit Changes

Present the changes to the user for review before committing. Include:
- Cargo.toml dependency update
- Removed workaround code (if any)
- Updated documentation

---

## Quick Reference Commands

```bash
# Check all tracked issues at once
gh issue view 6 --repo microsoft/duroxide-pg --json state,title

# Current dependency versions
grep -E 'duroxide|duroxide-pg' Cargo.toml

# Find all workarounds in codebase
grep -rn "STOPGAP\|BLOCKED on duroxide\|TODO.*duroxide" --include="*.rs" .

# Test after update (--clean ensures fresh schema)
./scripts/test-e2e-local.sh --clean
```

---

## Notes

- We depend on `microsoft/duroxide-pg`. Only act on fixes released in duroxide-pg.
- The `--clean` flag is important when testing dependency updates to ensure fresh schema creation.
- Always check the Version Compatibility Matrix to ensure duroxide and duroxide-pg versions are compatible.
