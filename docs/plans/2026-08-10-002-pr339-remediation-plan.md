---
title: "fix: PR 339 post-remediation review findings"
type: fix
status: retained-for-reference
date: 2026-08-10
origin: review of PR #339 after commits 51cfca3..baee419
---

# fix: PR 339 post-remediation review findings

> **Retained for reference.** Tiers 0-2 were implemented and verified; PR #339
> was closed on 2026-08-11 after v0.2.1 installations were found in the field.
>
> Three of this document's own findings turned out to be wrong and are marked
> WITHDRAWN below (items 3, 8, 9). Item 9 in particular would have deleted a
> load-bearing branch that was concealing a real hang — see the fix recorded in
> commit `a4e39c6`.

## Context

PR #339 (`refactor/retire-pre-v0.2.2-compat`) landed as one planned commit
(`31833bb`) plus ten remediation commits (`51cfca3`..`baee419`) that implemented
`docs/retire-pr339-review.md` findings F1-F8 via
`docs/plans/2026-08-10-001-fix-provider-compatibility-guard-plan.md`.

A second review of the full branch found that most of what looks like scope creep
in the remediation commits was in fact mandated by F1/F4/F5/F7/F8 and the 001
plan. The items below are what survives that check: four blocking defects (two of
them plan **non-compliance**), three cosmetics, and three optional calls.

Items already verified as deliberate decisions and **not** in scope here: the
per-operation backend compatibility check (F1 combined resolution + 001 R3), the
`semver` dependency (001 Open Questions), phase 68 (F5 and the original plan's
Unit 4), and the positive B1 object assertion (F7).

---

# Tier 0 — CI is red, fix first

## 0. `67_provider_compatibility_lifecycle` fails in the Docker E2E job

Observed: run 31413801328, job "Docker Build & E2E Tests", exit code 3, reproduced
on re-run. Not a flake.

**Root cause.** The two harnesses select tests independently.
[scripts/test-e2e-local.sh](../../scripts/test-e2e-local.sh) gates by phase via
`phase_for_test()`, so 67/68 only run after `prepare_phase` builds the below-floor
fixture. [scripts/test-e2e-docker.sh](../../scripts/test-e2e-docker.sh) globs
`tests/e2e/sql/*.sql` and runs everything against one fixed-config healthy
container, filtered only by its own hand-maintained
[`SKIP_TESTS`](../../scripts/test-e2e-docker.sh#L30-L44) array. Commit `4b13ed2`
registered 67/68 with the local harness and never added them to `SKIP_TESTS`, so
67 runs against `extversion = 0.2.6` with no fixture and fails its first
assertion. 68 has the same defect and was never reached.

**Second bug exposed.** [scripts/test-e2e-docker.sh](../../scripts/test-e2e-docker.sh#L20)
sets `set -e`, and the runner uses `output=$(docker exec ... psql ...)` followed by
`exit_code=$?`. Under errexit an assignment inherits its command substitution's
status, so a nonzero `psql` exit kills the script at the assignment. The `else`
branch at [L241-L245](../../scripts/test-e2e-docker.sh#L241-L245) that prints
`FAIL` and increments `FAILED` is unreachable for any failing test — the Docker
harness can only die, never report. Errexit-safe form:

```bash
if output=$(docker exec "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -f "/tests/$test_name.sql" 2>&1); then
    exit_code=0
else
    exit_code=$?
fi
```

**Immediate fix:** add `67_*` and `68_*` to `SKIP_TESTS` with a comment naming the
lifecycle-phase requirement, and apply the errexit-safe capture.

**Durable fix (fold into item 1):** both harnesses glob `"$SQL_DIR"/*.sql
**non-recursively**, and `tests/e2e/sql/lifecycle/` already exists and is already
invisible to both — which is why the setup fixtures never broke Docker. Move
`67*`/`68*` into `tests/e2e/sql/lifecycle/` and have the item 1 phase sequencer
reference them by explicit path. This removes the failure class instead of adding
a fourth manually-synced list, and prevents the new `67b` from reintroducing the
same break.

**Note:** this is the third shell error-handling defect in this PR, alongside item
3 and item 10's no-op trap `return`.

---

# Tier 1 — Blocking

## 1. Fix A: make the stand-down shutdown check actually test stand-down

**Problem:** `verify_compatibility_rejection_phase` runs after
[67_provider_compatibility_lifecycle.sql](../../tests/e2e/sql/67_provider_compatibility_lifecycle.sql)
has already corrected `extversion` and resumed the worker, so it times a healthy
shutdown. The `tokio::select!` on `wait_for_shutdown()` inside
`wait_for_compatibility_change` has never been exercised, which means 001 plan
Unit 2 scenario 4 and Unit 4 scenario 3 are marked complete but unverified.

Wall-clock timing is also the wrong instrument.
[scripts/test-e2e-local.sh](../../scripts/test-e2e-local.sh#L305) already runs
`pg_ctl stop -m fast -t 30` with an immediate-mode fallback, so "did fast stop
succeed" is a deterministic signal a hung worker cannot fake.

### 1a. Expose the fast-stop outcome

```bash
STOP_SERVER_FAST_OK=true
STOP_SERVER_FAST_TIMEOUT=30

stop_server() {
    STOP_SERVER_FAST_OK=true
    if [ -d "$DATA_DIR" ] && "$PG_CTL" status -D "$DATA_DIR" >/dev/null 2>&1; then
        echo -e "${YELLOW}Stopping PostgreSQL...${NC}"
        if ! "$PG_CTL" -D "$DATA_DIR" stop -m fast -t "$STOP_SERVER_FAST_TIMEOUT" >/dev/null 2>&1; then
            STOP_SERVER_FAST_OK=false
            echo -e "${RED}Fast stop timed out; falling back to immediate stop${NC}"
            "$PG_CTL" -D "$DATA_DIR" stop -m immediate >/dev/null 2>&1 || true
        fi
        sleep 1
    fi
}
```

### 1b. Split test 67 across the shell check

- `67_provider_compatibility_rejected.sql` — current 67 **minus** the tail from
  `UPDATE pg_catalog.pg_extension SET extversion = '0.2.6'` onward.
- `67b_provider_compatibility_recovery.sql` — the removed tail (version restore,
  stand-down wake, `df.start()` recovery).

### 1c. Sequence the phase explicitly instead of "all SQL, then one hook"

Replace the trailing lifecycle block in `run_phase`
([scripts/test-e2e-local.sh](../../scripts/test-e2e-local.sh#L942-L952)) with a
dedicated sequencer:

```bash
is_lifecycle_phase() {
    [ "$1" = "compatibility-rejection" ] || [ "$1" = "provider-ownership-rejection" ]
}

lifecycle_step() {
    local label="$1"; shift
    printf "  %-45s ... " "$label"
    if "$@"; then
        echo -e "${GREEN}PASS${NC}"; return 0
    fi
    echo -e "${RED}FAIL${NC}"; return 1
}

# Boot #1 is still below-floor here: the worker is stood down.
verify_standdown_logs() {
    local refusals inits
    refusals=$(tail -n +"$PHASE_LOG_START_LINE" "$LOG_FILE" | grep -c "refusing to initialize duroxide runtime" || true)
    inits=$(tail -n +"$PHASE_LOG_START_LINE" "$LOG_FILE" | grep -c "initializing duroxide runtime" || true)
    [ "$refusals" -eq 1 ] || { echo "    expected 1 refusal, found $refusals"; return 1; }
    [ "$inits" -eq 1 ]    || { echo "    expected 1 init attempt, found $inits"; return 1; }
}

verify_standdown_shutdown() {
    local saved="$STOP_SERVER_FAST_TIMEOUT"
    STOP_SERVER_FAST_TIMEOUT=10
    stop_server
    STOP_SERVER_FAST_TIMEOUT="$saved"
    [ "$STOP_SERVER_FAST_OK" = true ] || {
        echo "    stood-down worker did not honour fast shutdown within 10s"
        return 1
    }
}

rearm_phase_log_window() {
    restart_server || return 1
    PHASE_LOG_START_LINE=$(( $(wc -l < "$LOG_FILE") + 1 ))
}
```

Then, for `compatibility-rejection`, run in this order:

| # | Step | Boot |
|---|---|---|
| 1 | `prepare_phase` (fixture + below-floor `extversion`) | boot 1 |
| 2 | `67_provider_compatibility_rejected.sql` | boot 1 |
| 3 | `verify_standdown_logs` | boot 1 |
| 4 | `verify_standdown_shutdown` — **the real assertion** | boot 1 -> down |
| 5 | `rearm_phase_log_window` | boot 2, still rejected |
| 6 | `67b_provider_compatibility_recovery.sql` | boot 2 |
| 7 | `restore_current_extension` | boot 3 |

`provider-ownership-rejection` keeps its current single-hook shape; only
`restore_current_extension` moves into `lifecycle_step`.

**Verification:** temporarily stub `wait_for_shutdown()` out of the
`tokio::select!` in `wait_for_compatibility_change`
([src/worker.rs](../../src/worker.rs#L384-L407)) — step 4 must fail. It currently
passes with that stub, which is the whole point.

**Note:** if you also apply optional item 8, the `pg_sleep(4)` at the top of the
rejected-state test must grow past two poll intervals or step 3 races.

---

## 2. Fix B: stop the provider-failure log flood

[src/worker.rs](../../src/worker.rs#L497-L505) appends a full recovery paragraph
to a line that retries every second, for *any* store-construction failure —
reintroducing F1's own symptom on a different path.

```rust
async fn initialize_duroxide_runtime(...) -> Option<...> {
    log!("pg_durable: initializing duroxide runtime...");
    let mut lineage_hint_logged = false;   // guidance is logged once per init attempt
    loop {
        ...
        Err(e) => {
            log!("pg_durable: failed to create PostgreSQL store (will retry): {}", e);
            if !lineage_hint_logged {
                lineage_hint_logged = true;
                log!(
                    "pg_durable: if this database originated before pg_durable 0.2.2 and still \
                     has extension-owned provider objects, that lineage is unsupported and \
                     retries cannot repair it; see the destructive reset procedure in CHANGELOG.md"
                );
            }
            tokio::select! { ... }
        }
    }
}
```

Keeps the 001 plan's constraints (provider error intact, conditional wording, no
lineage detector) while removing the per-retry repetition.

---

## 3. ~~Fix the `exit` -> `return` regression~~ — WITHDRAWN, false positive

**This finding was wrong.**
[scripts/test-e2e-local.sh](../../scripts/test-e2e-local.sh#L33) has
`set -euo pipefail`; the original check only grepped the first 20 lines and
missed it. Under errexit a plain command returning nonzero still aborts the
script, and all 10 call sites are plain commands — none sits in a condition,
`&&`/`||` list, or negation, which are the contexts where errexit is suppressed.
`wait_for_server` and `wait_for_worker_ready` also print their own diagnostic
before returning, so no message was lost either.

Commit `baee419` was therefore correct as written: `exit` inside the EXIT trap
would have been fatal, and `return` is errexit-safe at the existing call sites.
A `require` wrapper was implemented and then reverted; it added 11 lines of
redundancy for a regression that does not exist.

**What this did surface** is a real bug in the item 1 sequencer. Under errexit,
`lifecycle_record <step>` as a plain command aborts the phase on the first
failing step, so `restore_current_extension` never runs and the below-floor
fixture is left behind for every later run of that data directory. The existing
`run_phase` avoids this by calling `run_test_file` inside `if`. Fixed by
appending `|| true` to each recorded step. Only reachable on failure, so a green
run would never have shown it — it was found by the item 1 negative test.

---

## 4. Fix E: correct the doc overstatement

[docs/extension_lifecycle.md](../extension_lifecycle.md#L229) claims every
backend engine operation checks the version before constructing a provider.
False for [src/monitoring.rs](../../src/monitoring.rs#L606),
[src/explain.rs](../../src/explain.rs#L175), and
[src/lib.rs](../../src/lib.rs#L850) — and it violates 001 plan Unit 6's explicit
instruction to avoid claiming provider-backed monitoring is covered. Replace with:

> `df.start()`, `df.signal()`, and `df.cancel()` re-read the installed extension
> version on every call, before consulting `_worker_ready`, constructing a
> provider, or using a cached client. A below-floor schema returns the permanent
> compatibility error; a compatible schema whose BGW has not initialized yet
> returns `"pg_durable background worker not yet initialized — try again in a
> moment"`. Table-only inspection (`df.status()`, `df.result()`, terminal-state
> `df.await_instance()`) is deliberately **not** gated and stays available while
> the worker is stood down. Provider-backed monitoring in `src/monitoring.rs` and
> `src/explain.rs` constructs a `VerifyOnly` provider directly and carries no
> compatibility gate; it fails with the provider's own error.

---

# Tier 2 — Cosmetic, same PR

## 5. Fix D: qualify the catalog reference

[src/worker.rs](../../src/worker.rs#L371-L377):

```rust
sqlx::query_scalar("SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_durable'")
```

Recommended in the same pass for consistency with
[src/client.rs](../../src/client.rs#L36): `check_extension_exists` at
[L335-L341](../../src/worker.rs#L335-L341) and the `pg_namespace` / `pg_depend` /
`'pg_namespace'::regclass` references in `check_duroxide_schema_owned` at
[L346-L369](../../src/worker.rs#L346-L369).

## 6. Fix G: rename `unit4_*`

"Unit 4" is a section number from `docs/retire-pre-v0.2.2-compatibility.md`, a
do-not-commit document. Mechanical rename across 6 files:

| Current | Proposed |
|---|---|
| `unit4_blocked_worker` (server role) | `lifecycle_blocked_worker` |
| `unit4_provider_sentinel` | `compat_rejection_sentinel` |
| `unit4_ownership_sentinel` | `provider_ownership_sentinel` |
| `unit4_live_recovery`, `unit4_recovery_state` | `compat_recovery_state` |
| labels `unit4-*` | `compat-*` |

## 7. Fix H: stop hardcoding `0.2.6`

In
[compatibility-rejection-setup.sql](../../tests/e2e/sql/lifecycle/compatibility-rejection-setup.sql),
capture the real version before overwriting:

```sql
CREATE TABLE _duroxide.compat_fixture_state AS
SELECT extversion AS original_version
FROM pg_catalog.pg_extension
WHERE extname = 'pg_durable';

UPDATE pg_catalog.pg_extension
SET extversion = '0.2.2-rc1'
WHERE extname = 'pg_durable';
```

In `67b_provider_compatibility_recovery.sql`:

```sql
UPDATE pg_catalog.pg_extension e
SET extversion = s.original_version
FROM _duroxide.compat_fixture_state s
WHERE e.extname = 'pg_durable';
```

Keep the `'0.2.2-rc1'` literal in the guard assertion — that one is a deliberate
below-floor sentinel and should not track the release version.

---

# Tier 3 — all withdrawn except item 10

**8. ~~Slow the stand-down poll.~~ WITHDRAWN.** Both halves fail on inspection.
The 1s interval is the recovery detector: it is what notices `ALTER EXTENSION
UPDATE` or a drop/recreate, so slowing it slows recovery from the only
non-restart path. And the CHANGELOG phrase was misquoted here — in full it reads
"a bounded stand-down state **instead of a CPU/query/log hot loop**", which
plainly means bounded resource use, not bounded duration.

**9. ~~Delete the `Recheck` arm.~~ WITHDRAWN — this was the worst call in the
review.** The claim that `Recheck` is reachable only by catalog tampering is
wrong twice over.

First, the repo's own `recreate_extension` runs `DROP EXTENSION` and
`CREATE EXTENSION` in **one transaction** (a gap lets the BGW's migration runner
create the provider schema independently and break `CREATE EXTENSION`).
Transactionally, the worker never observes the extension as absent — it observes
a version change. `Recheck` is therefore the branch the documented recovery
actually takes, and `ExtensionMissing` is the rare one.

Second, once the pre-floor upgrade scripts are kept rather than deleted,
`ALTER EXTENSION pg_durable UPDATE` from v0.2.1 changes `extversion` in place
while the extension exists — a mainstream, non-exotic path straight through
`Recheck`.

Deleting it would have replaced a working recovery with a permanent hang, and
removed the only test capable of exposing the stale-schema bug fixed in
`a4e39c6`. 001 plan Unit 2 scenario 6 was right to require this; its weakness was
failing to record *why* a version can change, which is what made it look like
dead code here.

**10. Minor.** Drop the redundant identifier regex + `quote_ident` round-trip in
`resolve_provider_schema()`
([scripts/test-upgrade.sh](../../scripts/test-upgrade.sh#L434-L459)); make the
`COUNT(*) = 7` assertion name the missing relation on failure; delete the no-op
`return "$original_status"` in `cleanup()` (bash preserves the pre-trap exit
status unless the trap calls `exit` — verified).

---

# Sequencing

1. Items 2 and 5 (Rust) — independent, land first.
2. Item 3 (`require`) — must precede item 1, which adds new abort paths.
3. Items 6 and 7 (renames, fixture state) — mechanical, before the file split.
4. Item 1 (split + resequence) — the substantive change.
5. Item 4 (docs) — last, so wording matches shipped behavior.

# Verification

```bash
cargo fmt -p pg_durable -- --check
cargo clippy --features pg17 --no-default-features --all-targets
./scripts/test-unit.sh
./scripts/test-e2e-local.sh 67          # rejected-state + recovery
./scripts/test-e2e-local.sh 68
./scripts/test-e2e-local.sh             # full suite: proves item 3 didn't over-abort
./scripts/test-upgrade.sh
```

Plus the negative check for item 1: with `wait_for_shutdown()` removed from the
stand-down `tokio::select!`, `compatibility-rejection-shutdown` must fail. If it
still passes, the fix is not done.
