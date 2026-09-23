# Benchmarks

This harness measures completed pg_durable workflows with `pgbench`. SQL files
define the workloads; a Python standard-library runner manages warmups,
repetitions, a local HTTP target when needed, and JSON results. It does not build
the extension, start PostgreSQL, or change server configuration.

## Prerequisites

Use Python 3.10 or newer, PostgreSQL 17 or newer `psql` and `pgbench` on `PATH`,
and a disposable database with pg_durable installed and its worker running.
Connection settings come from libpq's `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`
and usual authentication configuration. The examples use the repository's local
pgrx development server and `postgres` role. The role needs permission to create
a schema, read its instances, and start, monitor, and cancel the chosen workflows.

For HTTP benchmarks, PostgreSQL must run on the same host/network namespace as
the runner. The target binds only to `127.0.0.1`, on an automatically chosen port.
It requires **`pg_durable.http_security = 'unrestricted'` on a development server**: restricted mode
intentionally rejects both plaintext HTTP and loopback destinations. Never use
this mode in production. The SQL baseline does not require it.

For a release-mode local PG17 HTTP build:

```sh
./scripts/pg-stop.sh
cargo pgrx install --release
./scripts/pg-start.sh
psql -h localhost -p 28817 -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "ALTER SYSTEM SET pg_durable.http_security = 'unrestricted'"
./scripts/pg-stop.sh
./scripts/pg-start.sh
```

Stop PostgreSQL before replacing its extension library. Use the appropriate
pgrx installation and PostgreSQL feature when testing another major version.
The harness never changes HTTP policy to make a workload succeed.

After HTTP benchmarking, remove the override with
`ALTER SYSTEM RESET pg_durable.http_security` and restart PostgreSQL. The local
development launcher will then use restricted mode again.

## Run a Workload

Run these commands from the repository root:

```sh
env PGHOST=localhost PGPORT=28817 PGUSER=postgres PGDATABASE=postgres \
  python3 benchmarks/run.py --workload sql --clients 1 8 \
  --transactions 50 --warmup 5 --repeat 3 --label release-sql

env PGHOST=localhost PGPORT=28817 PGUSER=postgres PGDATABASE=postgres \
  python3 benchmarks/run.py --workload http --clients 1 8 \
  --transactions 50 --warmup 5 --repeat 3 --label release-http \
  --request-bytes 1024 --response-bytes 1024 --delay-ms 10
```

Use `--workload http-multipart` for the same HTTP experiment with a multipart
file part. `sql` runs a durable `SELECT 1`; `http` sends a normal POST. Each
built-in workload starts one instance containing one activity. One client makes
sequential calls; multiple clients run independent workflows concurrently, not
parallel branches within one graph. Each client waits for completion before
starting its next workflow, so this is a closed-loop load test, not a fixed-rate
arrival generator.

`--transactions` and `--warmup` are counts **per client**. Warmup runs once per
concurrency level and is excluded from the measured repetitions. `--jobs`
controls pgbench threads, capped at the client count; it defaults to one.
`--timeout` bounds each workflow wait, and `--poll-ms` sets the completion-poll
interval (default 1 ms). Sleeps are capped at the remaining wait time, and
completion must be observed before the deadline. The runner also bounds each pgbench process by
`60 + transactions * (timeout + 1)` seconds to stop stalled phases.

HTTP response size and delay are fixed for a run. The target supports HTTP/1.1
keep-alive, consumes request bodies without retaining them, and serves a fixed
text response. Request and response payloads contain only synthetic `x` bytes.
The multipart request-byte counter includes the multipart envelope, not just
the configured file size. Zero-byte payloads and responses are supported.

## Results and Interpretation

Each invocation creates a new `target/benchmarks/<run ID>/` directory, or the
path specified with `--output`. Existing output directories are rejected.
Artifacts include:

- `results.json`: per-repetition workflow throughput, mean/min/max latency,
  nearest-rank p50/p95/p99, client/thread counts, server versions and settings,
  initial instance count, machine information, source revision and dirty state.
  Source state is captured before creating output files and includes untracked
  files regardless of Git's display settings.
  The run ID is saved before database setup. Failed reports retain chained
  errors, including database diagnostics and any cleanup failure.
- `workload.sql` and `await.sql`: the executed workload and completion helper.
- `c<clients>-r<repetition>.txt`: full pgbench output, including per-command
  timings. Matching PID-suffixed files retain every raw transaction sample.
  Warmup output and logs use `c<clients>-warmup` prefixes.

Failed workflows include their persisted node errors in the pgbench output.

HTTP results also include request, byte, and newly accepted TCP connection
counts, plus peak simultaneous target requests. These are per-phase counts:
zero new connections after warmup is expected when the client's pool is reused.
The target stays alive across warmups and repetitions. It validates that each
HTTP transaction produced one request and that no target I/O errors occurred.

Latency covers graph construction, submission/commit, durable execution, and
observation of completion. Polling adds overhead and detection delay; use the
same interval for comparisons. The benchmark-only wait helper avoids
`df.await_instance()`'s fixed 100 ms polling interval. TPS excludes pgbench's
initial database-connection time. For these one-request HTTP workloads,
workflow throughput also equals HTTP request throughput.

This is not a pure HTTP-client or TLS benchmark. PostgreSQL, orchestration,
history writes, and the Python target can dominate. Connection counts expose
pooling behavior even when end-to-end latency changes little. The local target
does not model TLS, external DNS, redirects, streaming uploads, or internet
latency. It requires Content-Length request framing; chunked requests fail the
benchmark. There are no performance pass/fail thresholds in CI.

For comparisons, use release builds, the same workload and configuration,
multiple repetitions, and an otherwise idle machine. Restore the same disposable
database snapshot between builds so accumulated history does not bias results.
Record build profile/features in `--label`: the source revision describes the
checkout, not proof of which binary PostgreSQL loaded. `df.version()` records
the loaded binary's version/build timestamp. Use enough samples for tail
percentiles; the small integration tests are correctness checks, not baselines.

## Add a Workload

Pass a trusted pgbench SQL script with `--workload path/to/workload.sql`, or add
one under [workloads/](workloads/) and select it by name. For example:

```sql
SELECT df.start(df.seq('SELECT 1', 'SELECT 2'), ':run_label') AS instance_id
\gset
```

The runner uses pgbench's simple-query mode, which substitutes `:name` even
inside SQL string literals. Use `':run_label'`, not psql's `:'run_label'` syntax,
in workload scripts. The supplied string values are generated by the runner;
this substitution does not escape arbitrary user-provided values.

The script must start exactly one workflow per transaction, label it with
`:run_label`, and capture its ID in `instance_id` using `\gset`. The runner
appends the completion wait. Do not wrap submission and waiting in a single
database transaction: the worker must see the committed submission. Prepare
any persistent workload tables before running the harness.

Custom scripts can use `:timeout_seconds`, `:poll_ms`, and `:request_bytes`, plus
pgbench's built-in variables. `--http-fixture` makes `:http_url` available for
custom local-HTTP workloads; those must currently issue one POST per workflow.
SQL, sequences, joins, and other finite graphs can use the same runner without
an HTTP target. Workload SQL and raw errors are saved, so do not put secrets in
them. The runner does not record libpq credentials.

## Cleanup and Compatibility

Each run creates a uniquely named `pgd_bench_<run ID>` schema containing its wait
function. Normal exit, failure, Ctrl-C, and SIGTERM trigger cancellation of only
that run's pending/running instances and removal of the helper schema. The runner
checks cancellation outcomes and still attempts schema removal if cancellation
fails. The local HTTP target closes its accepted connections and joins its handlers.
Failed
workflows, timeouts, missing samples, and cleanup errors produce a nonzero exit
and a failed report rather than a successful measurement. An uncatchable kill
(SIGKILL) or an unavailable database can leave a schema or workflows behind;
use the saved run ID to identify them.

Completed instances, nodes, and durable history are deliberately retained,
including warmup instances. Large payload tests can consume substantial disk
space. The harness neither prunes history nor resets the database; use a
disposable cluster and inspect or reset it separately.

No extension API, installation SQL, or upgrade script changes are required.
Benchmark helpers are not extension objects, and the extension's binary/schema
backward-compatibility contract is unchanged.

## Test the Harness

Lightweight tests run without PostgreSQL and are included in CI:

```sh
python3 -m unittest discover -s benchmarks -p 'test_*.py'
```

To include real workflow completion, failure, cancellation, and HTTP tests on a
disposable local server configured with unrestricted HTTP:

```sh
env PGHOST=localhost PGPORT=28817 PGUSER=postgres PGDATABASE=postgres \
  PGD_BENCH_INTEGRATION=1 PGD_BENCH_HTTP=1 \
  python3 -m unittest discover -s benchmarks -p 'test_*.py'
```

Omit `PGD_BENCH_HTTP=1` to test only the database-independent and SQL paths on a
restricted-mode server.