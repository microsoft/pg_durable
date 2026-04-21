# pg_durable Workflow Templates — VS Code & GitHub Code Templates

## Overview

| Field | Value |
|------|------|
| **Status** | Draft |
| **Last Modified** | 03/27/2026 |

---

## What & Why

pg_durable provides a powerful SQL DSL for durable workflows — but writing a durable function from scratch requires understanding the operators, the detect-branch-remediate pattern, scheduling, signals, and variable substitution. **Templates** lower the barrier to entry by giving users pre-built, parameterized workflows they can instantiate with a single click from VS Code.

### The Core Insight

> *"Customers get troubleshooting guides and recommendations that show them what's wrong — but they have to fix it manually. pg_durable can close the loop."* — Sarat Balijepalli

Templates encode the **trigger → action** patterns that domain experts (DBAs, developers, data engineers) already follow manually. Instead of writing 50+ lines of SQL, a user fills in 3–4 parameters (or describes what they need in natural language) and gets a working durable function.

### Strategy: Templates First, First-Class Syntax Later

Templates are the **discovery mechanism** — not a new language feature. The approach is deliberately iterative:

1. **Phase 1 (Current):** Ship templates that generate standard pg_durable DSL. No new syntax, no first-class operators. Templates are stored in VS Code / GitHub and instantiated on demand.
2. **Phase 2 (Telemetry-Driven):** Based on usage telemetry — which templates are most popular, which parameters users customize — consider promoting the highest-value patterns to first-class DSL operators (similar to how AI Pipelines will eventually get dedicated operators like `ai.chunk()`, `ai.embed()`).

This avoids premature abstraction. We don't know yet which patterns deserve first-class syntax until real users tell us through usage.

---

## Template Dimensions

Templates are organized along three dimensions. The **Cartesian product** of these dimensions produces the full template catalog.

### Dimension 1: Persona

Who is using the template?

| Persona | Description | Example Concerns |
|---------|-------------|-----------------|
| **DBA** | Database administrators managing health, performance, and maintenance | Vacuum, bloat, replication, wraparound, index maintenance |
| **Developer** | Application developers building features on PostgreSQL | ETL pipelines, data sync, background jobs, webhook processing |
| **Data Engineer** | Users building data pipelines and analytics workflows | Batch processing, aggregation, incremental loads, data quality |
| **Security / Compliance** | Users managing access, auditing, and policy enforcement | Audit log rotation, permission reviews, compliance checks |
| **Platform / SRE** | Site reliability engineers managing infrastructure | Health checks, failover readiness, capacity monitoring |

### Dimension 2: Trigger (What Starts It)

| Trigger Type | Description | Examples |
|-------------|-------------|---------|
| **On-Demand** | User explicitly starts the workflow | "Run bloat check now", "Start ETL pipeline" |
| **Scheduled (Cron)** | Runs on a recurring schedule via `@>` + `df.wait_for_schedule()` | "Every day at 3 AM", "Weekly on Sundays" |
| **Condition-Based** | Starts when a database condition is met (detected by a monitoring loop) | "When bloat > 80%", "When tables not vacuumed for 7 days" |
| **Signal-Based** | Triggered by an external signal via `df.signal()` | "When deploy is approved", "When upstream data lands" |

### Dimension 3: Action / Workflow Pattern

| Pattern | Description | pg_durable Primitives Used |
|---------|-------------|---------------------------|
| **Detect → Report** | Monitor-only: detect a condition, log findings | `~>`, `df.sql()` |
| **Detect → Remediate** | Auto-fix: detect and remediate without human approval | `~>`, `df.sql()`, `df.if()` |
| **Detect → Approve → Remediate** | Human-in-the-loop: detect, pause for approval, then remediate | `~>`, `df.if()`, `df.wait_for_signal()` |
| **Extract → Transform → Load** | ETL: multi-step data movement with checkpointing | `~>`, `\|=>` , `$var` |
| **Fan-Out → Aggregate** | Parallel: run queries concurrently, join results | `&`, `\|=>`, `~>` |
| **Loop → Sleep → Repeat** | Recurring: execute a body on a schedule, forever | `@>`, `df.wait_for_schedule()` |
| **Race → First Wins** | Competitive: run multiple paths, take the first result | `\|`, `df.race()` |

---

## Template Catalog: DBA — Vacuum & Maintenance

Starting with the **DBA persona** and **vacuum/maintenance** use cases, derived from real-world support patterns documented in the [Sarat_scenarios/](../Sarat_scenarios/) folder.

### DBA Templates — Initial Catalog

| # | Template Name | Description | Source |
|---|--------------|-------------|--------|
| DBA-001 | **Autovacuum Is Blocked** | Detect and resolve autovacuum blockers, then run vacuum | [01_autovacuum_blocked.sql](../Sarat_scenarios/01_autovacuum_blocked.sql) |
| DBA-002 | **Database Bloat > 80%** | Address excessive table bloat by resolving blockers and vacuuming | [02_database_bloat.sql](../Sarat_scenarios/02_database_bloat.sql) |
| DBA-003 | **Wraparound Risk** | Identify and mitigate transaction ID wraparound risk | [03_wraparound_risk.sql](../Sarat_scenarios/03_wraparound_risk.sql) |
| DBA-004 | **Tables Not Vacuumed for X Days** | Find stale tables and ensure vacuum maintenance is current | [04_tables_not_vacuumed.sql](../Sarat_scenarios/04_tables_not_vacuumed.sql) |

All four templates follow the common **Detect → Branch → (Approve if needed) → Vacuum → Report** pattern documented in [SCENARIOS_DESIGN.md](../Sarat_scenarios/SCENARIOS_DESIGN.md). Each supports on-demand execution, scheduled (cron) execution via `@>` + `df.wait_for_schedule()`, and human-in-the-loop approval via `df.wait_for_signal()` when blockers are detected.

### Template Example: DBA-001 — Autovacuum Is Blocked

**Description:** Detects autovacuum blockers across 5 sources (pg_stat_activity, replication slots, prepared transactions, streaming replicas). If blockers are found, pauses for human approval before remediating. If no blockers, vacuums immediately.

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `idle_timeout` | interval | `'30 minutes'` | Terminate idle-in-transaction sessions older than this |
| `label` | text | `'autovacuum-blocked'` | Instance label for monitoring |

**Generated SQL:**

```sql
-- Log tables for diagnostics
CREATE TABLE IF NOT EXISTS autovacuum_blockers_log (
    id          SERIAL PRIMARY KEY,
    source      TEXT,
    xmin_val    TEXT,
    xmin_age    BIGINT,
    details     TEXT,
    detected_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS autovacuum_remediation_log (
    id          SERIAL PRIMARY KEY,
    action      TEXT,
    result      TEXT,
    executed_at TIMESTAMPTZ DEFAULT now()
);

-- Start the durable function: detect → branch on blockers → remediate or vacuum directly
SELECT df.start(

    -- Step 1: Log all autovacuum blockers
    'INSERT INTO autovacuum_blockers_log (source, xmin_val, xmin_age, details)
     SELECT source, xmin::text, xmin_age, details
     FROM (
         SELECT ''pg_stat_activity'' AS source, backend_xid AS xmin,
                age(backend_xid) AS xmin_age,
                format(''pid=%s, db=%s, app=%s, user=%s, state=%s'',
                       pid, datname, application_name, usename, state) AS details
         FROM pg_stat_activity WHERE backend_xid IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots (catalog_xmin)'', catalog_xmin,
                age(catalog_xmin),
                format(''slot=%s, type=%s, active=%s'', slot_name, slot_type, active)
         FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_replication_slots (xmin)'', xmin, age(xmin),
                format(''slot=%s, type=%s, active=%s'', slot_name, slot_type, active)
         FROM pg_replication_slots WHERE xmin IS NOT NULL
         UNION ALL
         SELECT ''pg_prepared_xacts'', transaction::xid, age(transaction::xid),
                format(''gid=%s, db=%s, owner=%s'', gid, database, owner)
         FROM pg_prepared_xacts WHERE transaction IS NOT NULL
         UNION ALL
         SELECT ''pg_stat_replication'', backend_xmin, age(backend_xmin),
                format(''pid=%s, app=%s'', pid, application_name)
         FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
     ) blockers ORDER BY xmin_age DESC'

    ~>

    -- Step 2: Branch — are there blockers?
    --   YES → wait for user approval, remediate, then vacuum
    --   NO  → vacuum immediately (no user interaction needed)
    'SELECT EXISTS(SELECT 1 FROM autovacuum_blockers_log)'
    ?>
        (
            df.wait_for_signal('approve-remediation')
            ~>
            'INSERT INTO autovacuum_remediation_log (action, result)
             SELECT format(''terminated pid=%s'', pid),
                    pg_terminate_backend(pid)::text
             FROM pg_stat_activity
             WHERE state = ''idle in transaction''
               AND state_change < now() - interval ''{{idle_timeout}}'''
            ~>
            'VACUUM (ANALYZE)'
        )
    !>
        'VACUUM (ANALYZE)'

    ~>

    -- Step 3: Record completion
    'INSERT INTO autovacuum_remediation_log (action, result)
     VALUES (''complete'', ''Autovacuum check finished'')',

    '{{label}}'
);
```

**User approval (only when blockers found):**

```sql
-- Review blockers
SELECT * FROM autovacuum_blockers_log ORDER BY xmin_age DESC;

-- Approve remediation
SELECT df.signal('<instance_id>', 'approve-remediation');
```

---

## Future Template Categories

The DBA vacuum templates are the starting point. Additional categories will follow the same dimension model (persona × trigger × pattern):

### Developer Templates

| # | Template Name | Pattern | Use Case |
|---|--------------|---------|----------|
| DEV-001 | **Sequential ETL Pipeline** | Extract → Transform → Load | Multi-step data import with checkpointing |
| DEV-002 | **Parallel Aggregation Report** | Fan-Out → Aggregate | Run queries concurrently, combine results |
| DEV-003 | **Scheduled Data Sync** | Loop → Extract → Upsert | Periodic sync from staging to production |
| DEV-004 | **Background Job Processor** | Loop → Fetch → Process | Poll a queue table, process items durably |
| DEV-005 | **Webhook Retry Pipeline** | Detect → Retry → Report | Retry failed webhook deliveries with backoff |

### Data Engineer Templates

| # | Template Name | Pattern | Use Case |
|---|--------------|---------|----------|
| DE-001 | **Incremental Load** | Detect Changed → Extract → Load | CDC-style incremental data loads |
| DE-002 | **Data Quality Check** | Detect → Validate → Report | Run validation rules, flag exceptions |
| DE-003 | **Partition Maintenance** | Detect → Create/Drop Partitions | Automated time-based partition management |
| DE-004 | **Materialized View Refresh** | Cron → Refresh → Report | Scheduled refresh of materialized views |

### Security / Compliance Templates

| # | Template Name | Pattern | Use Case |
|---|--------------|---------|----------|
| SEC-001 | **Audit Log Rotation** | Cron → Archive → Truncate | Rotate audit logs on a schedule |
| SEC-002 | **Permission Review** | Cron → Detect → Report | Flag excessive or stale role grants |
| SEC-003 | **Connection Anomaly Monitor** | Loop → Detect → Alert | Monitor for unusual connection patterns |

### Platform / SRE Templates

| # | Template Name | Pattern | Use Case |
|---|--------------|---------|----------|
| SRE-001 | **Health Check Loop** | Cron → Query → Report | Periodic database health assessment |
| SRE-002 | **Replication Lag Monitor** | Loop → Detect → Alert | Watch for replica lag exceeding threshold |
| SRE-003 | **Connection Pool Monitor** | Loop → Detect → Alert | Monitor active/idle connection counts |

---

## VS Code Integration

### Instantiation Experience

Templates are surfaced in VS Code as a **single-click** experience. The user should go from "I need a vacuum monitor" to a running durable function in under 60 seconds.

#### Option A: Template Picker (Command Palette)

1. User opens Command Palette → **"pg_durable: New Workflow from Template"**
2. VS Code shows a categorized template picker (DBA, Developer, Data Engineer, etc.)
3. User selects a template (e.g., "DBA-003: Scheduled Autovacuum Monitor")
4. VS Code shows a parameter form:
   ```
   ┌─────────────────────────────────────────────────────┐
   │  Scheduled Autovacuum Monitor                       │
   │                                                     │
   │  Cron Schedule:     [0 2 * * *          ]           │
   │  Idle Timeout:      [30 minutes         ]           │
   │  Instance Label:    [nightly-vacuum-check]           │
   │                                                     │
   │  [ Preview SQL ]  [ Run ]  [ Save to File ]         │
   └─────────────────────────────────────────────────────┘
   ```
5. User clicks **Run** → template is rendered with parameters → SQL executed against the connected database
6. User clicks **Preview SQL** → rendered SQL opens in a new editor tab for review/customization
7. User clicks **Save to File** → SQL saved to workspace for version control

#### Option B: Natural Language (Copilot Chat)

1. User types in Copilot Chat: *"I need a vacuum check that asks me before killing sessions"*
2. Copilot identifies the matching template (DBA-001: Autovacuum Is Blocked), fills in parameters from the description
3. Copilot presents the rendered SQL for review
4. User confirms → SQL is executed

#### Option C: GitHub Code Template Repository

Templates are also published to a **public GitHub repository** so users can:

- Browse templates without VS Code
- Fork and customize for their environment
- Submit new templates via PR
- Use `gh` CLI to fetch templates directly

Repository structure:

```
pg-durable-templates/
├── README.md
├── dba/
│   ├── 01-autovacuum-blocked.sql
│   ├── 02-database-bloat.sql
│   ├── 03-wraparound-risk.sql
│   └── 04-tables-not-vacuumed.sql
├── developer/
│   ├── sequential-etl-pipeline.sql
│   ├── parallel-aggregation-report.sql
│   ├── scheduled-data-sync.sql
│   ├── background-job-processor.sql
│   └── webhook-retry-pipeline.sql
├── data-engineer/
│   ├── incremental-load.sql
│   ├── data-quality-check.sql
│   ├── partition-maintenance.sql
│   └── materialized-view-refresh.sql
├── security/
│   ├── audit-log-rotation.sql
│   ├── permission-review.sql
│   └── connection-anomaly-monitor.sql
└── sre/
    ├── health-check-loop.sql
    ├── replication-lag-monitor.sql
    └── connection-pool-monitor.sql
```

Each template file includes:

```sql
-- =============================================================================
-- TEMPLATE: Autovacuum Is Blocked (DBA-001)
-- PERSONA:  DBA
-- PATTERN:  Detect → Branch → (Approve if needed) → Vacuum → Report
-- =============================================================================
--
-- PARAMETERS:
--   {{idle_timeout}}  — Kill idle-in-transaction sessions older than (default: '30 minutes')
--   {{label}}         — Instance label (default: 'autovacuum-blocked')
--
-- USAGE:
--   1. Replace {{parameters}} with your values
--   2. Run against your PostgreSQL database
--   3. Monitor with: SELECT df.status('<instance_id>');
--
-- =============================================================================

-- ... template SQL follows ...
```

### Template Metadata Format

Each template includes machine-readable metadata (YAML frontmatter in a companion file or embedded in a SQL comment block) for VS Code tooling:

```yaml
id: DBA-001
name: Autovacuum Is Blocked
persona: DBA
category: Vacuum & Maintenance
trigger: on-demand
pattern: detect-approve-remediate
description: >
  Detects autovacuum blockers across 5 sources. If blockers are found,
  pauses for human approval before remediating. If no blockers, vacuums
  immediately.
parameters:
  - name: idle_timeout
    type: interval
    default: "30 minutes"
    description: Terminate idle-in-transaction sessions older than this
  - name: label
    type: text
    default: "autovacuum-blocked"
    description: Instance label for monitoring
tags: [vacuum, autovacuum, blocker, maintenance]
requires_approval: true
signal_names: [approve-remediation]
```

### VS Code Sidebar Integration

The PostgreSQL VS Code extension shows a **Templates** section in the sidebar:

```
POSTGRESQL
├── Connections
│   └── my-server
├── Durable Functions
│   ├── Running (3)
│   └── Waiting for Approval (1)
└── Templates
    ├── DBA
    │   ├── Autovacuum Is Blocked
    │   ├── Database Bloat > 80%
    │   ├── Wraparound Risk
    │   └── Tables Not Vacuumed for X Days
    ├── Developer
    │   ├── Sequential ETL Pipeline
    │   ├── ...
    ├── Data Engineer
    │   ├── ...
    └── Security
        ├── ...
```

---

## Telemetry & Iteration

### What We Track

| Metric | Purpose |
|--------|---------|
| Template instantiation count (by template ID) | Which templates are most popular |
| Parameter customization rate | Which defaults are changed most often |
| Completion/failure rate per template | Which templates work reliably |
| Time from instantiation to first `df.start()` | How quickly users go from template → running workflow |
| Natural language queries that match templates | What users are asking for that maps to existing templates |
| Natural language queries with no match | Gaps — new templates needed |

### Promotion to First-Class Syntax

When a template consistently shows:

- **High instantiation count** — many users need this pattern
- **Low parameter customization** — the defaults work for most cases
- **High completion rate** — the generated SQL is reliable

…it becomes a candidate for promotion to a first-class DSL operator. For example:

| Template | Potential First-Class Operator |
|----------|-------------------------------|
| DBA-001: Autovacuum Is Blocked | `df.vacuum_check(idle_timeout => '...')` |
| DEV-001: Sequential ETL Pipeline | `df.etl(source => '...', transform => '...', target => '...')` |
| SEC-001: Audit Log Rotation | `df.rotate_log(table => '...', retention => '...')` |

This is the same iterative approach used for AI Pipelines: start with templates, learn from usage, then promote proven patterns to first-class citizens.

---

## Implementation Plan

### Phase 1: DBA Vacuum Templates (Current)

1. **Finalize DBA-001 through DBA-004** — convert the existing [Sarat_scenarios/](../Sarat_scenarios/) SQL scripts into parameterized templates
2. **Create GitHub template repository** — publish templates with metadata, parameter documentation, and usage instructions
3. **VS Code Command Palette integration** — "New Workflow from Template" command with parameter form
4. **Copilot Chat integration** — natural language → template matching → parameter extraction → SQL generation

### Phase 2: Expand Catalog

1. **Developer templates** (DEV-001 through DEV-005) — ETL, aggregation, data sync patterns
2. **Data Engineer templates** (DE-001 through DE-004) — incremental loads, data quality, partitions
3. **Security templates** (SEC-001 through SEC-003) — audit, permissions, anomaly detection
4. **SRE templates** (SRE-001 through SRE-003) — health checks, replication, connections

### Phase 3: Telemetry-Driven Promotion

1. **Instrument telemetry** on template usage
2. **Analyze patterns** — identify high-usage, low-customization templates
3. **Promote to first-class operators** where warranted
4. **Community contributions** — accept new templates via PR to the GitHub repository

---

## Open Questions

1. **Template storage:** Should templates live in the VS Code extension bundle, a separate GitHub repo, or both? (Recommendation: both — extension ships with built-in templates, GitHub repo allows community contributions and updates between extension releases.)
2. **Template versioning:** When pg_durable DSL evolves (new operators, changed syntax), how do we version templates? (Recommendation: templates specify a minimum pg_durable version in metadata.)
3. **Parameter validation:** Should VS Code validate parameters before rendering SQL (e.g., cron expression syntax, interval format)? (Recommendation: yes, lightweight validation in the parameter form.)
4. **Multi-database:** Sarat's scenarios run per-database. Should templates handle multi-database execution, or is that a separate concern? (Recommendation: separate concern — each template targets one database, multi-database orchestration is a future addition.)
5. **Permissions:** Many DBA templates require elevated privileges (`pg_terminate_backend`, `pg_drop_replication_slot`). Should templates include permission checks or require the user to handle this? (Recommendation: templates include a "Required Privileges" section in metadata, VS Code warns if the connected role may lack permissions.)
6. **Community curation:** How do we handle quality control for community-submitted templates? (Recommendation: maintainer review process, automated testing against a test database, template CI.)
