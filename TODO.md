# TODO 

- support for signals
- reformat e2e tests to pull up the actual durable functions at the top, well delimited and separated from all the helpers
- add architecutre and detailed design docs
- figure out process to build/release the extension for linux, windows and macos, with instructions for installation
- figure out process for releasing prepackaged docker containers
- figure out the right security model with least possible priveleges 
- resource constraining the duroxide runtime
- variable logging/tracing levels?
- update to long polling PG provider 
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

- Switch to postgres duroxide provider
- Enble E2E tests
- join needs to just ctx.join2()
- Unit + functional + integration tests
