# Phase 5 Review: Documentation

**Reviewer**: impl-review (local)
**Diff range**: `c354d52..413056b`
**Date**: 2025-07-24

## Verdict: ✅ APPROVE

Phase 5 documentation is accurate, well-structured, and consistent with the existing USER_GUIDE.md style. One minor issue noted below — not blocking.

---

## Checklist

| Criterion | Status | Notes |
|-----------|--------|-------|
| GUC names accurate | ✅ | All four GUC names match `src/lib.rs:78-118` exactly |
| Default values accurate | ✅ | management=6, duroxide=10, user=10, timeout=30 — all match `src/lib.rs:20-23` |
| Postmaster context stated | ✅ | Correctly identified; matches `GucContext::Postmaster` on all four GUCs |
| Connection budget formula | ✅ | `mgmt + duroxide + user + (backends × 1)` matches pool/semaphore architecture in `src/worker.rs:125-149,446-473` |
| Backpressure behavior | ✅ | Semaphore queuing + timeout correctly described |
| Error message format | ⚠️ | Minor formatting difference (see below) |
| Startup validation | ✅ | Both checks (duroxide < 2 → FATAL, mgmt == 1 → WARNING) match `src/worker.rs:102-116` |
| Style consistency | ✅ | Headings, tables, code blocks, blockquote tips — all match existing USER_GUIDE.md patterns |
| ToC updated | ✅ | Section 15 inserted, subsequent sections renumbered |
| Placement correct | ✅ | After "User Isolation & Privileges" (§14), before "Troubleshooting" (§16) |
| CHANGELOG format | ✅ | Follows existing `- New: <feature>` pattern |
| Plan checkboxes | ✅ | Phase 5 and success criteria marked complete |

---

## Cross-Reference Detail

### GUC Declarations vs Documentation

| GUC | Doc Default | Code Default | Doc Context | Code Context | Min/Max |
|-----|-------------|--------------|-------------|--------------|---------|
| `max_management_connections` | 6 | 6 (`lib.rs:20`) | Postmaster | Postmaster (`lib.rs:85`) | 1–1000 |
| `max_duroxide_connections` | 10 | 10 (`lib.rs:21`) | Postmaster | Postmaster (`lib.rs:96`) | 2–1000 |
| `max_user_connections` | 10 | 10 (`lib.rs:22`) | Postmaster | Postmaster (`lib.rs:107`) | 1–1000 |
| `execution_acquire_timeout` | 30 | 30 (`lib.rs:23`) | Postmaster | Postmaster (`lib.rs:118`) | 1–3600 |

All match. ✅

### Connection Budget Formula

Doc: `Total = max_management_connections + max_duroxide_connections + max_user_connections + (active_backend_sessions × 1)`

Code:
- Management pool: `PgPoolOptions::new().max_connections(mgmt_conns)` (`worker.rs:125-149`)
- Duroxide pool: `DUROXIDE_PG_POOL_MAX` env var set to `get_max_duroxide_connections()` (`worker.rs:446-455`)
- User execution: `Semaphore::new(get_max_user_connections())` (`worker.rs:467-473`)
- Backend: `backend_provider_config()` with `long_poll.enabled = false` creates per-session connections (`types.rs:156-162`)

Formula matches. Example `6 + 10 + 10 + 5 = 31` is arithmetically correct. ✅

### Startup Validation

| Doc Claim | Code | Match |
|-----------|------|-------|
| `max_duroxide_connections < 2` → worker refuses to start | `if duroxide_conns < 2 { log!("...FATAL..."); return; }` (`worker.rs:102-108`) | ✅ |
| `max_management_connections = 1` → warning logged | `if mgmt_conns == 1 { log!("...WARNING..."); }` (`worker.rs:111-116`) | ✅ |
| Invalid values caught before connections created | Validation at `worker.rs:97-116`, pools created at `worker.rs:125+` | ✅ |

### Backpressure Behavior

Doc correctly describes: semaphore queuing → slots free up → timeout → workflow fails. Matches `execute_sql.rs:50-69`. ✅

---

## Issues

### Issue 1 (Minor, Non-blocking): Error message line break

**Doc shows** (in code block):
```
pg_durable: connection limit reached (max_user_connections=10).
Timed out after 30s waiting for an available execution slot.
```

**Actual code** (`execute_sql.rs:63-66`):
```rust
"pg_durable: connection limit reached (max_user_connections={limit}). \
 Timed out after {}s waiting for an available execution slot.",
```

The Rust `\` line continuation produces a **single-line** string with a space between the period and "Timed". The documentation renders it as two lines, which could imply there's a newline in the output. In practice this won't confuse users (the message content is correct), but joining it into one line would be more precise.

**Suggestion**: Render as one line, or add a note that it's a single-line message shown wrapped for readability.

---

## Observations (Non-blocking)

1. **Phase 4 review feedback addressed**: The `trap restore_defaults EXIT` added to `test-connlimit-e2e.sh` addresses Observation 1 from the Phase 4 review. Good follow-through. ✅

2. **CHANGELOG mentions "Backend provider pools reduced to 1 connection"**: The `backend_provider_config()` (`types.rs:156-162`) doesn't explicitly set `pool_max = 1` — it uses `ProviderConfig::default()` with `long_poll.enabled = false`. The "1 connection" claim depends on the duroxide-pg-opt default pool size. This is technically a prior-phase concern (not Phase 5), but worth noting for accuracy.

3. **GUC ranges not shown to users**: The doc mentions behavioral minimums (1 for management → warning, 2 for duroxide → FATAL) but doesn't list the GUC-enforced ranges (e.g., timeout max of 3600s). This is a reasonable editorial choice — users rarely need the upper bounds — but could be added to the GUC Reference table if desired.

---

## CHANGELOG Review

Entry at line 14:
```
- New: Connection limits — four Postmaster-context GUCs (`max_management_connections`, `max_duroxide_connections`, `max_user_connections`, `execution_acquire_timeout`) control the background worker's connection budget. User-execution connections are gated by a semaphore with configurable backpressure timeout. The former polling and activity pools are consolidated into a single management pool. Backend provider pools reduced to 1 connection.
```

- Follows `- New:` prefix convention ✅
- Lists all four GUC names ✅
- Mentions key behavioral changes (semaphore, pool consolidation) ✅
- Placed in `v0.2.0 (in development)` section ✅

---

## Summary

Phase 5 delivers high-quality documentation that accurately reflects the connection limits implementation. The User Guide section covers all four GUCs, the connection budget formula, backpressure behavior, startup validation, and provides practical configuration examples. The CHANGELOG entry is comprehensive and follows existing format conventions. One minor formatting issue (error message line break) is noted but does not warrant blocking.
