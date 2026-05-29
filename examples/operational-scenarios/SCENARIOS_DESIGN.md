# pg_durable Operational Scenarios – Design & Behavior Spec

> **Context:** Based on a brainstorming session with the Azure PostgreSQL Support team. Captures real-world customer patterns and how pg_durable can automate them — with human-in-the-loop approval before destructive actions.

---

## Key Insight

Customers today get **troubleshooting guides** and **Azure Advisor** recommendations that show them what's wrong — but they have to fix it manually. pg_durable can **close the loop**: detect the problem, surface findings for review, wait for approval, then execute remediation durably.

> *"They're perfectly OK if we do it or they want scripts to do it — but they don't want us to do it immediately without them having control."* — Azure PostgreSQL Support

---

## Common Pattern Across All Scenarios

Every scenario follows the same **Detect → Branch → (Approve if needed) → Vacuum → Report** lifecycle:

```
┌──────────┐     ┌───────────────┐     ┌─────────────────────────────────────┐     ┌────────┐
│ 1. DETECT │ ──▶ │ 2. LOG & SHOW │ ──▶ │ 3. BRANCH (df.if)                   │ ──▶ │ 4. REPORT │
│ (auto)   │     │ (diagnostics) │     │                                     │     │ (notify) │
└──────────┘     └───────────────┘     │  Blockers?                          │     └────────┘
                                       │  ├─ YES → wait for approval →       │
                                       │  │        remediate → vacuum         │
                                       │  └─ NO  → vacuum immediately        │
                                       └─────────────────────────────────────┘
```

### pg_durable Pipeline Shape

The key insight: **only ask for approval when blockers exist**. If the system is clean, just vacuum.

```sql
-- Pseudocode for the common pattern using df.if() branching
SELECT df.start(
    -- Phase 1: Detect (always runs)
    'INSERT INTO <scenario>_diagnostics_log ... FROM pg_stat_activity / pg_replication_slots / ...'

    ~>

    -- Phase 2: Branch — do blockers exist?
    'SELECT EXISTS(SELECT 1 FROM <scenario>_diagnostics_log)'
    ?>  -- YES: blockers found → ask user, then remediate
        (
            df.wait_for_signal('approve-remediation')
            ~> 'SELECT pg_terminate_backend(...) ...'
            ~> 'VACUUM (ANALYZE)'
        )
    !>  -- NO: no blockers → vacuum immediately
        'VACUUM (ANALYZE)'

    ~>

    -- Phase 3: Record completion report
    'INSERT INTO <scenario>_report_log ...',

    'scenario-label'
);
```

### Branching Operators

| Operator | Function | Purpose |
|----------|----------|---------|
| `?>` | `df.if_then_op()` | If condition is true → execute this branch |
| `!>` | `df.if_else_op()` | Otherwise → execute this branch |
| `df.if(cond, then, else)` | Full function form | Same thing, function syntax |

### User Approval Flow (only when blockers exist)

1. Pipeline starts → detection phase runs automatically
2. Pipeline checks: `SELECT EXISTS(SELECT 1 FROM diagnostics_log)`
3. **If blockers found** → pipeline pauses at `df.wait_for_signal('approve-remediation')`
   - User reviews diagnostics in VS Code (or queries the log tables)
   - User sends signal to continue:
     ```sql
     SELECT df.signal('<instance_id>', 'approve-remediation');
     ```
   - Remediation runs, then vacuum executes
4. **If no blockers** → pipeline skips straight to `VACUUM (ANALYZE)` — no human interaction needed
5. Report is logged either way

### Scheduling (Off-Hours Execution)

Customers often want remediation during **off-hours** (e.g., 7–9 AM before business starts, or weekends). pg_durable has **native scheduling** — no `pg_cron` dependency needed.

#### `@>` (Loop Operator) + `df.wait_for_schedule(cron_expr)`

The `@>` prefix operator creates an **infinite loop**, and `df.wait_for_schedule()` sleeps until the next cron tick. Combined, they create a recurring durable pipeline:

```sql
-- Run blocker detection every day at 2 AM
SELECT df.start(
    @> (
        df.wait_for_schedule('0 2 * * *')
        ~>
        'INSERT INTO autovacuum_blockers_log (source, xmin_val, xmin_age, details)
         SELECT source, xmin::text, xmin_age, details FROM ( ... ) blockers'
        ~>
        -- Pause for user approval before remediation
        df.wait_for_signal('approve-remediation')
        ~>
        'VACUUM (ANALYZE)'
        ~>
        'INSERT INTO autovacuum_remediation_log (action, result)
         VALUES (''cycle_complete'', ''Scheduled vacuum cycle finished'')'
    ),
    'nightly-vacuum-check'
);
```

#### Cron Expression Examples

| Expression | Schedule |
|------------|----------|
| `0 2 * * *` | Every day at 2:00 AM |
| `0 7 * * 1-5` | Weekdays at 7:00 AM (before business hours) |
| `0 */6 * * *` | Every 6 hours |
| `0 2 * * 0` | Every Sunday at 2:00 AM |
| `*/30 * * * *` | Every 30 minutes (for monitoring) |

#### How It Works

1. `@>` wraps the body in an infinite `LOOP` node
2. `df.wait_for_schedule('0 2 * * *')` computes seconds until the next cron tick and sleeps
3. After waking, the pipeline runs: detect → wait for approval → remediate → vacuum
4. Loop repeats — sleeps until the *next* 2 AM, then runs again
5. The pipeline is **durable** — survives PostgreSQL restarts, picks up where it left off

#### Monitoring-Only (No Approval Required)

For pure monitoring without remediation, skip the signal:

```sql
-- Every 5 minutes: check for vacuum blockers and log them
SELECT df.start(
    @> (
        df.wait_for_schedule('*/5 * * * *')
        ~>
        'INSERT INTO autovacuum_blockers_log (source, xmin_val, xmin_age, details)
         SELECT source, xmin::text, xmin_age, details FROM ( ... ) blockers'
    ),
    'blocker-monitor-5min'
);
```

#### Stopping a Scheduled Pipeline

```sql
-- Cancel the recurring pipeline
SELECT df.cancel('<instance_id>');
```

---

## Scenario 0: Common Prerequisite – Identify Blockers

**File:** [00_common_prerequisite.sql](00_common_prerequisite.sql)

**What it does:** Queries 5 sources to find the oldest xmin holder blocking vacuum:

| Source | Blocker Type | Remediation |
|--------|-------------|-------------|
| `pg_stat_activity` | Long-running or idle-in-transaction session | Terminate session (`pg_terminate_backend`) |
| `pg_replication_slots (catalog_xmin)` | Logical replication slot not consumed | Drop unused slot or fix consumer |
| `pg_replication_slots (xmin)` | Physical replica lagging/stuck | Check replication health |
| `pg_prepared_xacts` | Orphaned two-phase commit transaction | `COMMIT PREPARED` or `ROLLBACK PREPARED` |
| `pg_stat_replication` | Streaming replica holding old xmin | Check replica lag |

> This query runs as **Step 1** in every scenario below.

---

## Scenario 1: Autovacuum Is Blocked

**File:** [01_autovacuum_blocked.sql](01_autovacuum_blocked.sql)

**Trigger:** Autovacuum cannot proceed — dead tuples accumulate, table bloat grows.

### Expected Behavior

1. **Detect** — Run the blocker identification query, log results to `autovacuum_blockers_log`
2. **Branch** — Check if any blockers were found:
   - **Blockers found** → Surface to user in VS Code, pause for approval, then remediate
   - **No blockers** → Skip straight to vacuum (no human interaction needed)
3. **Remediate** (only if blockers) — After approval:
   - Terminate idle-in-transaction sessions older than 30 min
   - Drop confirmed-unused replication slots
   - Resolve orphaned prepared transactions
4. **Vacuum** — Run `VACUUM (ANALYZE)` (runs in both branches)
5. **Report** — Log summary: how many blockers found, how many resolved, vacuum status

### Pipeline (with branching)

```sql
SELECT df.start(
    -- Step 1: Log all autovacuum blockers
    'INSERT INTO autovacuum_blockers_log (source, xmin_val, xmin_age, details)
     SELECT source, xmin::text, xmin_age, details FROM ( ... ) blockers'

    ~>

    -- Step 2: Branch — are there blockers?
    'SELECT EXISTS(SELECT 1 FROM autovacuum_blockers_log)'
    ?>  -- YES: blockers found → ask user, remediate, then vacuum
        (
            df.wait_for_signal('approve-remediation')
            ~>
            'INSERT INTO autovacuum_remediation_log (action, result)
             SELECT format(''terminate pid=%s'', pid), pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND state_change < now() - interval ''30 minutes'''
            ~>
            'VACUUM (ANALYZE)'
        )
    !>  -- NO: no blockers → vacuum immediately
        'VACUUM (ANALYZE)'

    ~>

    -- Step 3: Record completion
    'INSERT INTO autovacuum_remediation_log (action, result)
     VALUES (''complete'', ''Autovacuum check finished'')',

    'scenario1-autovacuum-blocked'
);
```

### Approval (only when blockers exist)

```sql
-- Pipeline pauses here ONLY if blockers were detected.
-- User reviews blockers:
SELECT * FROM autovacuum_blockers_log ORDER BY xmin_age DESC;

-- User approves remediation:
SELECT df.signal('<instance_id>', 'approve-remediation');

-- If no blockers were found, the pipeline already ran VACUUM
-- without any user interaction.
```

---

## Scenario 2: Database Bloat > 80%

**File:** [02_database_bloat.sql](02_database_bloat.sql)

**Trigger:** Table bloat exceeds threshold — wasted disk, slow sequential scans.

### Expected Behavior

1. **Detect** — Identify bloated tables (dead tuple ratio, table size), log to `bloat_detection_log`
2. **Check blockers** — Log vacuum blockers
3. **Branch** — If blockers found → surface to user, wait for approval, remediate; if no blockers → vacuum immediately
4. **Vacuum** — Run `VACUUM (ANALYZE)` to reclaim space (runs in both branches)
5. **Report** — Log summary: tables detected, space reclaimed, bloat ratios

### Pipeline (with branching)

```sql
SELECT df.start(
    -- Step 1: Identify bloated tables
    'INSERT INTO bloat_detection_log (schema_name, table_name, table_size, dead_tup, live_tup, bloat_ratio)
     SELECT schemaname, relname, pg_size_pretty(pg_total_relation_size(...)),
            n_dead_tup, n_live_tup, round(n_dead_tup::numeric / n_live_tup * 100, 2)
     FROM pg_stat_user_tables WHERE n_dead_tup > 0'

    ~>

    -- Step 2: Log vacuum blockers
    'INSERT INTO bloat_remediation_log (action, result)
     SELECT ''blocker_detected'', format(''source=%s, xmin_age=%s'', source, xmin_age)
     FROM ( ... ) blockers'

    ~>

    -- Step 3: Branch — are there blockers?
    'SELECT EXISTS(
         SELECT 1 FROM bloat_remediation_log WHERE action = ''blocker_detected''
     )'
    ?>  -- YES: blockers found → ask user, remediate, then vacuum
        (
            df.wait_for_signal('approve-bloat-remediation')
            ~>
            'INSERT INTO bloat_remediation_log (action, result)
             SELECT format(''terminated pid=%s'', pid), pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND state_change < now() - interval ''30 minutes'''
            ~>
            'VACUUM (ANALYZE)'
        )
    !>  -- NO: no blockers → vacuum immediately
        'VACUUM (ANALYZE)'

    ~>

    -- Step 4: Report
    'INSERT INTO bloat_remediation_log (action, result)
     VALUES (''complete'', format(''Detected %s bloated tables, remediation finished'',
            (SELECT count(*) FROM bloat_detection_log)))',

    'scenario2-database-bloat'
);
```

---

## Scenario 3: Wraparound Risk

**File:** [03_wraparound_risk.sql](03_wraparound_risk.sql)

**Trigger:** Database approaching the ~2 billion XID limit — risk of emergency shutdown.

### Expected Behavior

1. **Detect** — Check database-level transaction ages, identify tables closest to wraparound
2. **Check blockers** — Log vacuum blockers
3. **Branch** — If blockers found → surface to user, wait for approval, remediate; if no blockers → freeze immediately
4. **Freeze** — Run `VACUUM (FREEZE, ANALYZE)` (runs in both branches)
5. **Report** — Log remaining XIDs after freeze, before/after comparison

> **Note:** Even the "no blockers" path still runs `VACUUM FREEZE`, which is expensive. For Scenario 3 specifically, you may still want approval on the freeze itself (see "Always-Approve Variant" below).

### Pipeline (with branching)

```sql
SELECT df.start(
    -- Step 1: Log database-level XID ages
    'INSERT INTO wraparound_db_log (datname, dat_xid_age, txids_remaining)
     SELECT datname, age(datfrozenxid), 2000000000 - age(datfrozenxid)
     FROM pg_database WHERE datallowconn'

    ~>

    -- Step 2: Log top 50 at-risk tables
    'INSERT INTO wraparound_table_log ... FROM pg_class'

    ~>

    -- Step 3: Log vacuum blockers
    'INSERT INTO wraparound_action_log (action, result)
     SELECT ''blocker_detected'', format(''source=%s, xmin_age=%s'', source, xmin_age)
     FROM ( ... ) blockers'

    ~>

    -- Step 4: Branch — are there blockers?
    'SELECT EXISTS(
         SELECT 1 FROM wraparound_action_log WHERE action = ''blocker_detected''
     )'
    ?>  -- YES: blockers found → ask user, remediate, then freeze
        (
            df.wait_for_signal('approve-wraparound-remediation')
            ~>
            'INSERT INTO wraparound_action_log (action, result)
             SELECT format(''terminated pid=%s'', pid), pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND state_change < now() - interval ''30 minutes'''
            ~>
            'VACUUM (FREEZE, ANALYZE)'
        )
    !>  -- NO: no blockers → freeze immediately
        'VACUUM (FREEZE, ANALYZE)'

    ~>

    -- Step 5: Report
    'INSERT INTO wraparound_action_log (action, result)
     VALUES (''complete'', format(''Wraparound risk mitigated for %s at-risk tables'',
            (SELECT count(*) FROM wraparound_table_log WHERE txid_remaining < 1000000000)))',

    'scenario3-wraparound-risk'
);
```

### Always-Approve Variant (for cautious customers)

Since `VACUUM FREEZE` is expensive even without blockers, some customers may want approval **regardless**. Use nested branching:

```sql
-- Branch on blockers, but always ask before FREEZE
'SELECT EXISTS(SELECT 1 FROM wraparound_action_log WHERE action = ''blocker_detected'')'
?>  -- Blockers → approve remediation first, then approve freeze
    (
        df.wait_for_signal('approve-remediation')
        ~> 'terminate blockers ...'
        ~> df.wait_for_signal('approve-freeze')
        ~> 'VACUUM (FREEZE, ANALYZE)'
    )
!>  -- No blockers → still ask before freeze (it's expensive!)
    (
        df.wait_for_signal('approve-freeze')
        ~> 'VACUUM (FREEZE, ANALYZE)'
    )
```

### Scheduled Recurring Check

> Combine `@>` + `df.wait_for_schedule()` with the branching pipeline for a fully autonomous weekly wraparound monitor:
>
> ```sql
> -- Weekly Sunday 2 AM: detect, branch on blockers, remediate or vacuum directly
> SELECT df.start(
>     @> (
>         df.wait_for_schedule('0 2 * * 0')
>         ~> 'INSERT INTO wraparound_db_log ... FROM pg_database'
>         ~> 'INSERT INTO wraparound_table_log ... FROM pg_class'
>         ~> 'INSERT INTO wraparound_action_log ... FROM blockers'
>         ~>
>         'SELECT EXISTS(SELECT 1 FROM wraparound_action_log WHERE action = ''blocker_detected'')'
>         ?>  (df.wait_for_signal('approve-remediation') ~> 'terminate ...' ~> 'VACUUM (FREEZE, ANALYZE)')
>         !>  'VACUUM (FREEZE, ANALYZE)'
>         ~>
>         'INSERT INTO wraparound_action_log ... VALUES (''cycle_complete'', ...)'
>     ),
>     'weekly-wraparound-check'
> );
> ```

---

## Scenario 4: Tables Not Vacuumed for X Days

**File:** [04_tables_not_vacuumed.sql](04_tables_not_vacuumed.sql)

**Trigger:** Tables haven't been vacuumed (manually or by autovacuum) for a configurable threshold (default: 7 days).

### Expected Behavior

1. **Detect** — Identify stale tables: `last_vacuum` and `last_autovacuum` older than X days
2. **Check blockers** — Log vacuum blockers
3. **Branch** — If blockers found → surface to user, wait for approval, remediate; if no blockers → vacuum immediately
4. **Vacuum** — Run `VACUUM (ANALYZE)` (runs in both branches)
5. **Report** — Log summary: tables vacuumed, dead tuples reclaimed

### Pipeline (with branching)

```sql
SELECT df.start(
    -- Step 1: Identify stale tables
    'INSERT INTO stale_tables_log (schema_name, table_name, last_vacuum, last_autovacuum, n_dead_tup, days_since_vacuum)
     SELECT schemaname, relname, last_vacuum, last_autovacuum, n_dead_tup, ...
     FROM pg_stat_user_tables
     WHERE (last_autovacuum IS NULL OR last_autovacuum < now() - interval ''7 days'')
       AND (last_vacuum IS NULL OR last_vacuum < now() - interval ''7 days'')'

    ~>

    -- Step 2: Check for blockers
    'INSERT INTO stale_vacuum_action_log (action, result)
     SELECT ''blocker_detected'', format(''source=%s, xmin_age=%s'', source, xmin_age)
     FROM ( ... ) blockers'

    ~>

    -- Step 3: Branch — are there blockers?
    'SELECT EXISTS(
         SELECT 1 FROM stale_vacuum_action_log WHERE action = ''blocker_detected''
     )'
    ?>  -- YES: blockers found → ask user, remediate, then vacuum
        (
            df.wait_for_signal('approve-stale-vacuum')
            ~>
            'INSERT INTO stale_vacuum_action_log (action, result)
             SELECT format(''terminated pid=%s'', pid), pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND state_change < now() - interval ''30 minutes'''
            ~>
            'VACUUM (ANALYZE)'
        )
    !>  -- NO: no blockers → vacuum immediately, no user interaction needed
        'VACUUM (ANALYZE)'

    ~>

    -- Step 4: Report
    'INSERT INTO stale_vacuum_action_log (action, result)
     VALUES (''complete'', format(''Found %s stale tables, vacuum finished'',
            (SELECT count(*) FROM stale_tables_log)))',

    'scenario4-tables-not-vacuumed'
);
```

### Scheduled Daily Check (Recommended)

This scenario is ideal for a recurring schedule — run daily, auto-vacuum if clean, pause only when blockers need attention:

```sql
SELECT df.start(
    @> (
        df.wait_for_schedule('0 3 * * *')   -- every day at 3 AM
        ~>
        'INSERT INTO stale_tables_log ... FROM pg_stat_user_tables WHERE ...'
        ~>
        'INSERT INTO stale_vacuum_action_log ... FROM blockers'
        ~>
        'SELECT EXISTS(SELECT 1 FROM stale_vacuum_action_log WHERE action = ''blocker_detected'')'
        ?>  (df.wait_for_signal('approve-stale-vacuum') ~> 'terminate ...' ~> 'VACUUM (ANALYZE)')
        !>  'VACUUM (ANALYZE)'
        ~>
        'INSERT INTO stale_vacuum_action_log ... VALUES (''cycle_complete'', ...)'
    ),
    'daily-stale-table-check'
);
```

> **Best-case behavior:** Every night at 3 AM, the pipeline wakes up, finds no blockers, vacuums stale tables, and goes back to sleep. The user never has to touch it. Only if blockers appear does it pause and notify.

---

## Surfacing in VS Code

The discussion identified VS Code as the primary surface for these scenarios. Here's how each piece maps:

### 1. Diagnostics Dashboard (Read-Only View)

A VS Code webview panel or sidebar that queries the diagnostic log tables and shows:

| View | Data Source | What It Shows |
|------|------------|---------------|
| **Blocker Summary** | `autovacuum_blockers_log` | Active blockers: PIDs, slots, prepared txns |
| **Bloat Report** | `bloat_detection_log` | Tables ranked by bloat ratio, dead tuples, size |
| **Wraparound Risk** | `wraparound_db_log`, `wraparound_table_log` | Databases/tables with remaining XIDs |
| **Stale Tables** | `stale_tables_log` | Tables not vacuumed, days since last vacuum |
| **Pipeline Status** | `df.status(<id>)` | Current step, waiting-for-signal status |

### 2. Approval Actions (Interactive)

When a pipeline is paused at `df.wait_for_signal(...)`, VS Code can show:

- **"Review & Approve" button** → Runs `SELECT df.signal('<id>', 'approve-...')` 
- **"Schedule for Later" option** → Wraps the pipeline in `@> df.wait_for_schedule('cron_expr')` for recurring execution, or lets user pick a one-time delay
- **"Reject / Cancel" button** → Runs `SELECT df.cancel('<id>')`

### 3. Notifications & Reporting

| Event | Notification Type | Content |
|-------|------------------|---------|
| Detection complete | Info toast | "Found 3 autovacuum blockers — review required" |
| Waiting for approval | Warning banner | "Pipeline paused: approve remediation for 5 bloated tables" |
| Remediation complete | Success toast | "VACUUM complete: 12 stale tables cleaned, 450K dead tuples reclaimed" |
| Pipeline failed | Error toast | "Scenario 3 failed at step 5: VACUUM FREEZE interrupted" |

### 4. Reporting Table

Each scenario writes a final summary to its action log. VS Code can render this as a **completion report**:

```
┌─────────────────────────────────────────────────────────┐
│ Scenario 1: Autovacuum Blocked – COMPLETED              │
├─────────────────────────────────────────────────────────┤
│ Blockers found:    3                                    │
│   - 2 idle-in-transaction sessions (terminated)         │
│   - 1 unused replication slot (dropped)                 │
│ Vacuum status:     VACUUM (ANALYZE) completed           │
│ Duration:          4m 32s                               │
│ Next scheduled:    2026-03-24 02:00 UTC (via @> loop)   │
└─────────────────────────────────────────────────────────┘
```

---

## Implementation Priorities

### Must Have (MVP)

- [x] Blocker detection queries (Scenario 0) — **done** in SQL scripts
- [x] Durable pipelines for all 4 scenarios — **done** in SQL scripts
- [ ] `df.wait_for_signal()` / `df.signal()` — human-in-the-loop pause/resume
- [ ] VS Code extension: query diagnostic tables and show results
- [ ] VS Code extension: "Approve" button that sends signal to pipeline

### Should Have

- [ ] Scheduled pipelines using `@>` + `df.wait_for_schedule()` for recurring scenarios
- [ ] VS Code notifications (toast) when pipeline reaches approval stage
- [ ] Completion report rendering in VS Code panel
- [ ] Configurable thresholds (bloat %, days stale, idle timeout)

### Nice to Have

- [ ] Azure Advisor integration — surface pg_durable recommendations alongside existing advisories
- [ ] Per-table targeted vacuum (instead of whole-database `VACUUM ANALYZE`)
- [ ] Historical trend tracking (bloat over time, vacuum frequency)
- [ ] Email/webhook notifications for pipeline events

---

## Open Questions

1. **Signal discovery:** How does the VS Code extension discover which pipelines are waiting for signals? Does `df.status()` expose the signal name?
2. **Partial approval:** Can users approve remediation for *some* blockers but not others (e.g., terminate idle sessions but keep the replication slot)?
3. **Rollback:** If remediation causes issues (e.g., terminated session was important), what's the recovery path?
4. **Multi-database:** These scenarios run per-database. How do we handle customers with many databases on one server?
5. **Permissions:** The pipeline needs superuser-like privileges (`pg_terminate_backend`, `pg_drop_replication_slot`). How do we handle least-privilege access?
