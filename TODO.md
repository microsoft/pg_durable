# TODO 

- build/test with pg15, 16, 17, 18
- implement security spec docs/spec-security-model.md 
- think of error handling, retries and compensating transactions
- azure functions integration
- metrics and logging
- add stress tests
- Configurable multiple background workers via GUC (pg_durable.worker_count) for horizontal scaling;
- Function templates
- [ ] Implement Parameterized Queries (See [Proposal](docs/parameterized_queries_proposal.md))
- [ ] Implement `df.run` stub
- Dump the function definition, explain chops off the statements
- Compensation/Saga: `<->` operator and `df.with_undo()` for saga-style rollback (see docs/spec-compensation.md)
- samples for pg_fdw
- retries on all df.* object update operations
- figure out the right way and level to do logging in pg extensions
- fault injection using mocks for all node types
- reformat e2e tests to pull up the actual durable functions at the top, well delimited and separated from all the helpers
- GC/maintenance: prune old completed/failed orchestration history from duroxide.* tables; detect stuck df.instances rows that never started
- figure out process to build/release the extension for linux, windows and macos, with instructions for installation
- figure out process for releasing prepackaged docker containers
- figure out the right security model with least possible priveleges 
- resource constraining the duroxide runtime
- variable logging/tracing levels?
- evaluate provider work-dispatch latency under sustained load
- error handling stratgy, impl and tests
- rename ExecuteWorkflow orchestration to DurableFunction, add a version to list_instances.
- think through SQL error handling in details
- versioning for upgrades!
- perf, too many updates on node and orch statuses going on
- feedback.md
- error handling
- reliability/hardening sql calls
- Duroxide runtime tied to a single database, how to make it work for all DBs

# DONE

- add architecutre and detailed design docs
- Comments on spec-sercurity-model
    - get GPT5.2 and Gemini 3 to review
    - think about how the vars work with RLS, only admin can set/read?
- Switch to postgres duroxide provider
- Enble E2E tests
- join needs to just ctx.join2()
- Unit + functional + integration tests
- support for signals (df.wait_for_signal, df.signal)
- LoadFunctionGraph retry logic for transaction safety
- Cached Duroxide client per backend process
- Grammar rules and examples (docs/grammar.md)
