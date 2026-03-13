# Check Upstream Fixes and Update Dependencies

**Purpose:** Check if fixes for tracked blockers have been released in upstream dependencies (duroxide) and guide updating duroxide-pg-opt.

**Last Updated:** 2025-01-07

---

## Quick Reference - Active Blockers

| Issue | Title | Status |
|-------|-------|--------|
| [#50](https://github.com/microsoft/duroxide/issues/50) | Provider validation missing prune for Running instances test | 🔴 Open |
| [#36](https://github.com/microsoft/duroxide/issues/36) | Provider validation missing lock extension verification | 🔴 Open |
| [#40](https://github.com/microsoft/duroxide/issues/40) | Idempotency test uses cross-execution activity cancellation | 🔴 Open |

## Resolved Blockers (duroxide v0.1.7)

| Issue | Title | Resolution |
|-------|-------|------------|
| [#31](https://github.com/microsoft/duroxide/issues/31) | Configurable `wait_for_orchestration` timeout | ✅ `wait_timeout_secs` field added |
| [#32](https://github.com/microsoft/duroxide/issues/32) | Validation test timing race | ✅ Fixed race condition |
| [#34](https://github.com/microsoft/duroxide/issues/34) | Lock renewal timing sensitivity | ✅ Increased timing margins |

---

## Instructions

### Step 1: Review Active Blockers

Read the active blockers in `docs/dep_issues.md` to understand what issues we're tracking.

### Step 2: Check Issue Status

For each active blocker, check if the GitHub issue has been closed/resolved:

```bash
# Check issue status (replace ISSUE_NUMBER with actual number)
gh issue view <ISSUE_NUMBER> --repo microsoft/duroxide --json state,title,closedAt
```

If the issue is still open, stop here - no action needed.

### Step 3: Check if Fix is in a Release

If an issue is closed, check if it's included in a release:

```bash
# List recent releases
gh release list --repo microsoft/duroxide --limit 10

# Check what version we currently use
grep 'duroxide = ' Cargo.toml
```

Compare the release date with the issue close date. If there's a release after the issue was closed, the fix is likely available.

### Step 4: Review Release Notes

```bash
# View specific release notes (replace TAG with version like v0.1.7)
gh release view <TAG> --repo microsoft/duroxide
```

Confirm the fix is mentioned in the release notes.

### Step 5: Update Dependency

If a fix is available in a new release:

1. **Update Cargo.toml** - change the duroxide version:
   ```toml
   duroxide = "0.1.X"
   ```

2. **Build and test**:
   ```bash
   cargo build
   cargo test
   ./scripts/run-stress-tests.sh
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
# Check active issue
gh issue view 36 --repo microsoft/duroxide --json state,title

# Current dependency versions
grep 'duroxide = ' Cargo.toml

# Find all workarounds in codebase
grep -rn "STOPGAP\|BLOCKED on duroxide\|TODO.*duroxide" --include="*.rs" .

# Run tests after update
cargo test
./scripts/run-stress-tests.sh
```

---

## Notes

- We depend on `microsoft/duroxide`. Only act on fixes released there.
- Always check the Version Compatibility Matrix to ensure versions are compatible.
- Run the full test suite including stress tests after any dependency update.
