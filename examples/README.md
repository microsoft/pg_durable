# Examples

This directory contains runnable examples that demonstrate pg_durable patterns
end to end.

## Example Conventions

### `scripts/smoke_check.sh` is CI-safe

If an example provides `scripts/smoke_check.sh`, it should be safe to run in CI
and on a fresh local checkout:

- No Azure login, cloud credentials, or provisioned resources required
- No dependency on previously deployed function apps or external state
- Fast validation only: shell syntax, Python syntax, JSON shape, file presence,
  or similar offline checks

CI runs all example smoke checks with:

```bash
for smoke_check in examples/*/scripts/smoke_check.sh; do
  bash "$smoke_check"
done
```

### Live cloud probes use a separate script

If an example also needs a real deployed-resource check, use a separate script
name such as `scripts/live_smoke_check.sh`.

That keeps the CI contract clear:

- `smoke_check.sh` = offline, deterministic, CI-safe
- `live_smoke_check.sh` = real cloud validation after provisioning/deploy

## Current Examples

- `azure-functions/` — Call an Azure Function from `df.http()`
- `azure-http-domains/` — Validate Azure allowlisted HTTP domains
- `invoice-approval/` — Human approval workflow with an Azure Function
- `operational-scenarios/` — Vacuum, bloat, and wraparound remediation scenarios