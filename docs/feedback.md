# pg_durable Feedback & Feature Requests

This document tracks user feedback and potential feature requests for pg_durable.

---

## Feedback Session: December 2024

### Source
Initial testing feedback from early users.

---

## 1. Use `$$SQL$$` Dollar-Quoting in Examples

**Status:** ✅ Quick win - Update docs

**Feedback:**
> You can make the examples much more clean by using the `$$SQL$$` syntax

**Example (before):**
```sql
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('* * * * *') ~>
        durable.sql('INSERT INTO playground.logs (msg) VALUES (''Minute tick: '' || now()::text)')
    ),
    'every-minute-tick'
);
```

**Example (after):**
```sql
SELECT durable.start(
    durable.loop(
        durable.wait_for_schedule('* * * * *') ~>
        durable.sql($$INSERT INTO playground.logs (msg) VALUES ('Minute tick: ' || now()::text)$$)
    ),
    'every-minute-tick'
);
```

**Benefits:**
- No escape hell with nested single quotes
- VS Code SQL syntax highlighting works inside `$$...$$`
- Cleaner, more readable queries
- Already works (standard PostgreSQL string syntax)

**Action:** Update USER_GUIDE.md examples to use dollar-quoting style.

**Priority:** High | **Effort:** Low

---

## 2. Multi-User Job Delegation / Row-Level Security

**Status:** 🔮 Future consideration

**Feedback:**
> It would be good to have an easy way to delegate, allow a different database user to create jobs/tasks narrowed down to them without a way to change/impact jobs created by other users.

**Problem:**
In multi-tenant or team environments, users should only see and manage their own workflows, not others'.

**Proposed Implementation:**

1. Add `owner` column to `durable.instances`:
```sql
ALTER TABLE durable.instances ADD COLUMN owner TEXT DEFAULT current_user;
```

2. Enable Row-Level Security:
```sql
ALTER TABLE durable.instances ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_isolation ON durable.instances 
    FOR ALL
    USING (owner = current_user);

-- Allow superusers to see all
CREATE POLICY admin_all ON durable.instances
    FOR ALL
    TO pg_durable_admin
    USING (true);
```

3. Update `list_instances()` and other monitoring functions to respect RLS.

**Considerations:**
- Need to track owner at workflow creation time
- `durable.nodes` table may also need owner/RLS
- Admin role for cross-user visibility
- Background worker runs as superuser, needs to bypass RLS for execution

**Priority:** Medium | **Effort:** Medium

---

## 3. SET ROLE for Job Execution (Principle of Least Privilege)

**Status:** 🔮 Future consideration

**Feedback:**
> It would be good to tie a SET ROLE option for a job, so that we can force execution of specific tasks as a lower privileged user.

**Problem:**
Currently, all SQL in workflows executes with the background worker's privileges (typically superuser). For security, jobs should run with minimal required permissions.

**Proposed Implementation:**

1. Add optional `execution_role` parameter to `durable.start()`:
```sql
SELECT durable.start(
    durable.sql($$SELECT * FROM sensitive_table$$),
    'my-job',
    'app_readonly'  -- execution role
);
```

2. Store role in `durable.instances`:
```sql
ALTER TABLE durable.instances ADD COLUMN execution_role TEXT;
```

3. In `ExecuteSQL` activity, wrap execution:
```sql
SET ROLE app_readonly;
-- execute the query
RESET ROLE;
```

**Considerations:**
- Security audit of role switching
- What if role doesn't exist?
- Should default to a restricted role or current_user?
- Need to handle role switching failures gracefully
- Connection pool implications

**Security Benefits:**
- SQL injection in workflow queries has limited blast radius
- Accidental `DROP TABLE` in workflow can't affect system tables
- Audit trail shows which role executed what

**Priority:** Medium-High | **Effort:** Medium-High

---

## 4. Resource Tracking for External Task Execution

**Status:** 🔮 v2 / Architecture change

**Feedback:**
> If the tasks are ran externally and not within pg process then it would be great to have system resource usage by said executed tasks (CPU, memory, anything that we can track).

**Problem:**
Currently, all tasks run inside the PostgreSQL background worker process. There's no way to:
- Isolate resource consumption per task
- Track CPU/memory per workflow
- Prevent a runaway workflow from affecting PostgreSQL

**Current Architecture:**
```
PostgreSQL Process
└── Background Worker (pg_durable_worker)
    └── Duroxide Runtime
        └── ExecuteSQL Activity (runs queries via sqlx)
```

**Future Architecture for Resource Tracking:**
```
PostgreSQL Process
└── Background Worker (coordinator only)
    └── Dispatches to External Workers

External Worker Pool (separate processes/containers)
├── Worker 1 (with metrics agent)
├── Worker 2 (with metrics agent)
└── Worker N (with metrics agent)

Metrics Collection
└── Prometheus / OpenTelemetry
```

**What This Would Require:**
- External worker process(es) written in Rust
- gRPC or HTTP API for task dispatch
- Task serialization/deserialization
- Worker health monitoring
- Metrics collection (CPU, memory, duration)
- Potentially Kubernetes Job/Pod per task for full isolation

**Metrics to Track:**
- CPU time (user + system)
- Peak memory usage
- Wall clock duration
- I/O operations
- Network bytes (if applicable)

**Considerations:**
- Significant architectural change
- Adds operational complexity
- May not be needed for most use cases
- Could be optional "enterprise" feature

**Priority:** Low (v2) | **Effort:** High

---

## Summary Matrix

| Feature | Priority | Effort | Status |
|---------|----------|--------|--------|
| `$$..$$` in docs | High | Low | ✅ Do now |
| Multi-user RLS | Medium | Medium | 🔮 Post-MVP |
| SET ROLE execution | Medium-High | Medium-High | 🔮 Post-MVP |
| External resource tracking | Low | High | 🔮 v2 |

---

## Notes

- Feedback indicates users are thinking about production use cases
- Security features (RLS, SET ROLE) are important for enterprise adoption
- Resource tracking would require significant architecture changes
- Dollar-quoting is a quick documentation improvement

