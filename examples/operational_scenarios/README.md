# PostgreSQL Durable Extension – Vacuum, Bloat, and Wraparound Scenarios

This document describes standard operational scenarios and step-by-step remediation actions to ensure PostgreSQL durability by proactively managing autovacuum blockers, table bloat, and transaction ID (XID) wraparound risk.

## Scenarios

| # | Scenario | Description | File |
|---|----------|-------------|------|
| 0 | **Common Prerequisite** | Identify autovacuum blockers before taking any manual vacuum action | [00_common_prerequisite.sql](00_common_prerequisite.sql) |
| 1 | **Autovacuum Is Blocked** | Detect and resolve autovacuum blockers, then run vacuum | [01_autovacuum_blocked.sql](01_autovacuum_blocked.sql) |
| 2 | **Database Bloat > 80%** | Address excessive table bloat by resolving blockers and vacuuming | [02_database_bloat.sql](02_database_bloat.sql) |
| 3 | **Wraparound Risk** | Identify and mitigate transaction ID wraparound risk | [03_wraparound_risk.sql](03_wraparound_risk.sql) |
| 4 | **Tables Not Vacuumed for X Days** | Find stale tables and ensure vacuum maintenance is current | [04_tables_not_vacuumed.sql](04_tables_not_vacuumed.sql) |

## Usage

Each scenario file is a standalone SQL script that can be run against a PostgreSQL database. Always start with the **Common Prerequisite** (Scenario 0) to identify autovacuum blockers before proceeding with any remediation.

### Quick Start

```bash
# Connect to your database
psql -h <host> -U <user> -d <database>

# Run the common prerequisite to check for blockers
\i examples/operational_scenarios/00_common_prerequisite.sql

# Then run the relevant scenario
\i examples/operational_scenarios/01_autovacuum_blocked.sql
```

## Blocker Identification Reference

Before taking any manual vacuum action, always identify the oldest xmin holder, as it can prevent vacuum, freeze, and catalog cleanup.

| Source | What it means | Next steps |
|--------|--------------|------------|
| `pg_stat_activity` | A backend transaction is holding an old xmin, usually due to a long-running transaction or idle session in transaction state. | Identify the pid, user, and query. If safe, terminate the session. Review long-running transactions on the primary server. |
| `pg_replication_slots (catalog_xmin)` | A logical replication slot is preventing system catalog cleanup by holding an old catalog_xmin. | Verify whether the slot is still required. If unused, drop the slot. If active, fix the logical replication consumer and allow it to catch up. |
| `pg_replication_slots (xmin)` | A physical standby or replica is lagging or stuck and holding xmin on the primary server. | Check replication health and lag. If the replica is broken or not progressing, redeploy it or contact Azure Support. |
| `pg_prepared_xacts` | A prepared (two-phase commit) transaction has not been committed or rolled back and is holding xmin. | Commit or roll back the prepared transaction as appropriate. Investigate and clean up orphaned prepared transactions. |
