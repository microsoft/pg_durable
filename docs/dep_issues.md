# Dependency Issues & Blockers

**Purpose:** Track duroxide-pg issues/limitations that require workarounds in pg_durable.

**Last Updated:** 2026-11-03

**GitHub Query:** [All pg_durable issues in duroxide-pg](https://github.com/microsoft/duroxide-pg/issues?q=is%3Aissue+label%3Apg_durable)

---

## How to Check for Fixes

1. **Check duroxide-pg releases:**
   ```bash
   gh release list --repo microsoft/duroxide-pg --limit 10
   ```

2. **Check specific issue status:**
   ```bash
   gh issue view <ISSUE_NUMBER> --repo microsoft/duroxide-pg
   ```

3. **Check current duroxide version in use:**
   ```bash
   grep 'duroxide = ' Cargo.toml
   ```

4. **After duroxide update, search for STOPGAP markers:**
   ```bash
   grep -rn "STOPGAP\|BLOCKED on duroxide\|TODO.*duroxide fix" --include="*.rs" .
   ```

---

## Active Blockers

### HTTP admission: deferred work can starve already-ready activities

| Field | Value |
|-------|-------|
| **Companion PR** | [microsoft/duroxide-pg#51](https://github.com/microsoft/duroxide-pg/pull/51) |
| **Status** | Open; not included in the pinned duroxide-pg 0.1.34 |
| **Runtime support** | [microsoft/duroxide#74](https://github.com/microsoft/duroxide/pull/74), merged and pinned at `36b789d802f98963241a59ee7706e3ce029d583f` |

The provider fetches visible worker items by their original queue ID. HTTP
admission deferrals retain that ID, so a sufficiently large saturated backlog
can repeatedly overtake later SQL, graph-load, or status activities despite
spare activity slots. Longer bounded retry delays only raise the threshold.

The companion change orders eligible items by visibility time and then ID,
preserving sessions and tags. It also adds a supporting index through a new
provider migration. Do not copy its SQL into the extension or edit historical
migrations; update the compatible provider dependency once the change lands
and revalidate high-backlog progress and upgrades.

The merged runtime already avoids a full-history read for normal activity
metadata. Execution-specific history remains a fallback when metadata is
unavailable or belongs to a different execution, and each fetch still processes
the request input. This reduces admission cost but does not fix queue ordering.

---

## Resolved Blockers

### [RESOLVED] Schema Versioning for duroxide-pg Provider

| Field | Value |
|-------|-------|
| **Issue** | [microsoft/duroxide-pg#6](https://github.com/microsoft/duroxide-pg/issues/6) |
| **Also filed** | [microsoft/duroxide-pg#1](https://github.com/microsoft/duroxide-pg/issues/1) (FYI only) |
| **Status** | ✅ Resolved |
| **Fixed In** | duroxide-pg v0.1.9 (requires duroxide 0.1.11) |

**Resolution Date:** 2026-01-06

**Problem (was):**
When upgrading `duroxide` or `duroxide-pg` versions, the PostgreSQL schema in the `duroxide` schema may change (new columns, changed function signatures, etc.). This caused runtime errors:
- `function duroxide.XXX does not exist` (function signature changed)
- `column index out of bounds` (table columns changed)
- `cached plan must not change result type` (prepared statement cache invalidated)

**Resolution:**
The duroxide-pg v0.1.9 release includes ProviderAdmin lifecycle management which handles schema versioning. No workarounds were needed in pg_durable codebase at the time of the fix.

---

## Checklist After Duroxide Update

When updating the duroxide dependency, run through this checklist:

1. [ ] Check if any issues in "Active Blockers" are fixed in the new version
2. [ ] Run `grep -rn "STOPGAP\|BLOCKED on duroxide" --include="*.rs" .` to find workarounds
3. [ ] For each fixed issue:
   - [ ] Remove the workaround code
   - [ ] Run the affected tests to confirm fix
   - [ ] Move the blocker to "Resolved Blockers" section
4. [ ] Run full test suite: `./scripts/test-unit.sh`
5. [ ] Run E2E tests with `--clean`: `./scripts/test-e2e-local.sh --clean`
6. [ ] Update this document with new status

---

## Version Compatibility Matrix

| pg_durable | duroxide | duroxide-pg | Notes |
|------------|----------|-----------------|-------|
| 0.1.1 | 0.1.11 | 0.1.9 | Current - schema versioning fix |
| 0.1.0 | 0.1.6 | 0.1.6 | Legacy |
