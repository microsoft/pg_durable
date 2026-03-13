# TODO

- Test timeouts/waits are too generous assuming remote DB. We might be missing some bugs.
    - Scan and tune for local container execution only
- Pull json parsing into rust code where it makes sense
- Competing consumer instead of all dispatchers racing
- fix up perf testing prompt and tests
- Connection pool pre-warming in `provider.rs` is still needed - the `test_multi_threaded_lock_expiration_recovery` validation test requires pre-warmed connections to avoid connection-establishment latency affecting lock ordering. This is not a duroxide bug.
- fetch_orchestration_item review as listed below
- remove all dead code masked by allow dead code
- Add `visible_at` to worker queue - see [proposal](docs/WORKER_VISIBLE_AT_PROPOSAL.md)
- **BLOCKED on duroxide**: Large payload stress test uses reduced intensity for remote DBs due to hardcoded 60s `wait_for_orchestration` timeout in `duroxide/src/provider_stress_test/core.rs`. See [GitHub issue #31](https://github.com/microsoft/duroxide/issues/31). Once fixed, update `pg-stress/src/lib.rs` to use full intensity for all DBs.

# DONE

- verify FI tests, verify perf tests, figure out counters


