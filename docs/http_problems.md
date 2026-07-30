# Open Problems in the HTTP Activities

Findings from the review of `df.http_multipart()` (#302) that are **still
unresolved** on `main` as of `09e08f0`, after the follow-up fixes in #303
(base64 whitespace) and #304 (binary response bodies).

Resolved findings are not repeated here. The one blocking issue that *was*
fixed — PostgreSQL's `encode(bytea, 'base64')` line wrapping breaking every
part larger than 56 source bytes — was closed by #303.

`0.2.5` is still **Unreleased**, so items that would otherwise be locked in by
a shipped upgrade contract are still changeable.

---

## Summary

Ordered by severity.

| # | Short name | Applies to | Severity | Status |
|---|---|---|---|---|
| 1 | [Unbounded payloads](#1-unbounded-payloads) | both | 🔴 Blocking | Open |
| 2 | [Unvalidated JSONB inputs](#2-unvalidated-jsonb-inputs) | both (see detail) | 🟡 Medium | Open |
| 3 | [Upgrade does not grant `df.http_multipart()` to existing roles](#3-upgrade-does-not-grant-dfhttp_multipart-to-existing-roles) | `df.http_multipart` | 🟡 Medium | Open |
| 4 | [Malformed node config panics the orchestration](#4-malformed-node-config-panics-the-orchestration) | both | 🟡 Medium | Open |
| 5 | [Unvalidated `filename` in `Content-Disposition`](#5-unvalidated-filename-in-content-disposition) | `df.http_multipart` | 🟡 Medium | Open |
| 6 | [Missing negative tests](#6-missing-negative-tests) | `df.http_multipart` | 🟡 Medium | Open |
| 7 | [Tests that pass without asserting](#7-tests-that-pass-without-asserting) | `df.http_multipart` | 🟡 Medium | Open |
| 8 | [Documentation gaps](#8-documentation-gaps) | both | 🟢 Low | Open — partially addressed |
| 9 | [Activity duplication](#9-activity-duplication) | both | 🟢 Low | Open — partially addressed |
| 10 | [Privilege error message does not name the function](#10-privilege-error-message-does-not-name-the-function) | both | 🟢 Low | Open |
| 11 | [`USER_GUIDE.md` misdescribes 5xx and retry behaviour](#11-user_guidemd-misdescribes-5xx-and-retry-behaviour) | both | 🟢 Low | Open |
| 12 | [`content_type` not substituted](#12-content_type-not-substituted) | `df.http_multipart` | 🟢 Low | Open |
| 13 | [Framing headers forwarded unfiltered](#13-framing-headers-forwarded-unfiltered) | both | 🟢 Low | Open |
| 14 | [No upper bound on `timeout_seconds`](#14-no-upper-bound-on-timeout_seconds) | both | 🟢 Low | Open |
| 15 | [Exact-case method match](#15-exact-case-method-match) | both | 🟢 Low | Open |
| 16 | [`ensure_durofut` search_path change undocumented](#16-ensure_durofut-search_path-change-undocumented) | n/a (introduced by #302) | 🟢 Low | Open |
| 17 | [`ensure_durofut` body differs between install and upgrade](#17-ensure_durofut-body-differs-between-install-and-upgrade) | n/a (introduced by #302) | 🟢 Low | Open |
| 18 | [`HTTP_MULTIPART` node type is unnecessary](#18-http_multipart-node-type-is-unnecessary) | `df.http_multipart` | Design | Not adopted |

---

## 1. Unbounded payloads

**Severity: 🔴 Blocking — applies to both `df.http()` and `df.http_multipart()`.**

Nothing in the HTTP path bounds the number of bytes the background worker will
buffer, in either direction.

### Request side (caller-controlled)

Neither DSL function checks payload length. `df.http()`'s `body` is an
unbounded `Option<&str>`; `df.http_multipart()`'s `data_b64` is an unbounded
`String`. Both accept 32 MB without complaint:

```
df.http 32MB body            | durofut_json_len = 33554584
df.http_multipart 32MB part  | durofut_json_len = 33554627
```

Each becomes a ~33 MB `df.nodes.query` row (TEXT, so the ceiling is 1 GB) and a
duroxide history activity-input row, and is replayed on every background worker
restart.

### Response side (remote-controlled)

`http_response::read_body` is shared by both activities and reads the entire
body with no `Content-Length` pre-check, no streaming, and no limit:

```rust
if is_textual_content_type(...) {
    let text = response.text().await?;   // whole body, no cap
    Ok(ResponseBody::text(text))
} else {
    let bytes = response.bytes().await?; // whole body, no cap
    Ok(ResponseBody::base64(&bytes))     // +33% on top
}
```

This is the sharper edge: the size is chosen by the **remote server**, not by
the caller, so no one has to author a large value to trigger it. An allowlisted
endpoint serving a multi-gigabyte object is buffered whole in the worker,
base64-inflated, then persisted into the duroxide history and `df.instances`.

The binary/base64 branch is new in #304. The request-side half predates the
multipart work and has shipped since HTTP support landed.

### The telling detail

The only size cap anywhere in the HTTP path is:

```rust
/// Without a cap, a large binary error response would be base64-encoded
/// into the error string and then persisted in the duroxide history — several
/// times over, since the history records both activity input and output.
const ERROR_BODY_PREVIEW_LIMIT: usize = 512;
```

That comment states the amplification risk precisely and correctly, then bounds
only the **error-message preview**. The success path, which persists the same
body through the same history, is unbounded.

| Vector | `df.http` | `df.http_multipart` | Controlled by | Cap today |
|---|---|---|---|---|
| Request body / part payload | ✔ | ✔ | Caller (SQL) | none |
| Response body (text) | ✔ | ✔ | Remote server | none |
| Response body (binary → base64, +33%) | ✔ | ✔ | Remote server | none |
| Response body inside a 5xx error string | ✔ | ✔ | Remote server | 512 bytes ✅ |

### Suggested fix

A multipart-specific GUC would cover roughly a quarter of this. Because the
code path is shared, prefer one pair of `SUSET` GUCs applying to both
functions:

- `pg_durable.http_max_request_bytes` — enforced at DSL time, re-checked in the
  activity so that hand-written `df.nodes` rows cannot bypass it.
- `pg_durable.http_max_response_bytes` — enforced in `read_body` by checking
  `Content-Length` up front *and* streaming with a running byte budget, so an
  absent or lying `Content-Length` cannot bypass it.

The repo already has precedent for this style of cap: `MAX_GRAPH_NODES`,
`MAX_ROWSET_EXPANSION`, `MAX_GRAPH_DEPTH`.

---

## 2. Unvalidated JSONB inputs

**Severity: 🟡 Medium.** The `parts` half is `df.http_multipart()`-only; the
`headers` half applies to **both** functions.

Neither function inspects the structure of its JSONB arguments at DSL
construction time, so mistakes surface late or not at all.

### `parts` — `df.http_multipart()` only

`src/dsl.rs` checks only that `parts` is a non-empty array, then discards the
result:

```rust
let parts_arr = match parts_value.as_array() {
    None => pgrx::error!("parts must be a JSON array of part objects"),
    Some(arr) if arr.is_empty() => pgrx::error!("parts must contain at least one part"),
    Some(arr) => arr,
};
let _ = parts_arr; // shape validated; activity re-parses from the JSON below
```

The comment is inaccurate — the shape was *not* validated. Both of these are
accepted at DSL time:

```
multipart parts=[1,2,3]      | accepted = t
multipart part missing data  | accepted = t
```

They fail later, when the activity deserializes `MultipartConfig` and serde
enforces the required `name` and `data_b64`. That is a loud failure, but it
arrives as a durable orchestration failure rather than an immediate error from
`df.http_multipart()`.

`df.http()` has no structural argument of this kind — its `body` is plain TEXT,
and `url` / `method` / `timeout_seconds` are validated at DSL time in both
functions identically.

### `headers` — both functions, and it fails **silently**

`HttpConfig.headers` and `MultipartConfig.headers` are both untyped
`Option<serde_json::Value>`. Neither DSL function looks at them. Both activities
then do the same thing:

```rust
if let Some(obj) = headers.as_object() {   // non-object → whole map dropped
    for (key, value) in obj {
        if let Some(v) = value.as_str() {  // non-string → that header dropped
            request = request.header(key, v);
        }
    }
}
```

There is no `else` on either branch. All of these are accepted at DSL time:

```
http headers=array            | accepted = t
http headers=scalar           | accepted = t
http headers=nonstring value  | accepted = t
multipart headers=array       | accepted = t
```

So `df.http(url, 'GET', NULL, '{"Authorization": 12345}'::jsonb)` sends an
**unauthenticated request** and reports no error anywhere. This is a plausible
mistake rather than a contrived one: `jsonb_build_object('Authorization', some_int_col)`
produces exactly that shape, and `jsonb_agg` produces the array case.

This is worse than the `parts` case. A durable failure is visible and retriable;
a silently dropped `Authorization` header is neither — the workflow simply
receives a 401/403 with `ok=false` and carries on.

| Sub-issue | `df.http` | `df.http_multipart` | Failure mode |
|---|---|---|---|
| `parts` shape unvalidated at DSL time | n/a | ✔ | Loud — durable node failure |
| `headers` shape unvalidated at DSL time | ✔ | ✔ | **Silent** — headers dropped, request still sent |

### Suggested fix

Type both fields. Make `headers` a `HashMap<String, String>`, or validate
object-of-strings at DSL time and `pgrx::error!` otherwise; deserialize `parts`
into `Vec<MultipartPart>` in the DSL rather than passing the raw `Value`
through, and add `#[serde(deny_unknown_fields)]` to `MultipartPart`.

**Caveat:** the strictness must be applied at DSL time *only*. The activities
have to keep tolerating old-shaped configs, because `df.nodes` rows written by
a previous version replay through the new `.so` (the B1 backward-compatibility
contract in [upgrade-testing.md](upgrade-testing.md)). Tightening `headers` is
also a behaviour change for anyone currently relying on the silent drop, so it
needs a CHANGELOG note.

---

## 3. Upgrade does not grant `df.http_multipart()` to existing roles

**Severity: 🟡 Medium — `df.http_multipart()`, upgrade path.**

`df.http_multipart()` is documented as riding on the existing `include_http`
opt-in, but nothing in `sql/pg_durable--0.2.4--0.2.5.sql` propagates that opt-in
to the new function. Two distinct failures:

**(a) No backfill.** The upgrade script creates `df.http_multipart()` and
revokes `EXECUTE` from `PUBLIC`, but never grants it to the roles that already
hold `EXECUTE ON df.http` from a prior `df.grant_usage(..., include_http => true)`.
An existing HTTP-enabled role gets `permission denied for function
http_multipart` until an administrator re-runs `df.grant_usage()`. The upgrade
script contains no `aclexplode` or `DO $$` backfill of any kind.

**(b) Delegated admins fail harder.** `df.grant_usage()` is `SECURITY INVOKER`,
and the new `GRANT` is unguarded inside the `include_http` branch
([src/lib.rs:499](../src/lib.rs), mirrored at
[sql/pg_durable--0.2.4--0.2.5.sql:153](../sql/pg_durable--0.2.4--0.2.5.sql)):

```sql
IF include_http THEN
    EXECUTE format('GRANT EXECUTE ON FUNCTION df.http(...) TO %I', p_role) || grant_opt;
    -- df.http_multipart() shares the same opt-in (HTTP egress is one privilege).
    EXECUTE format('GRANT EXECUTE ON FUNCTION df.http_multipart(...) TO %I', p_role) || grant_opt;
END IF;
```

A delegated admin created under ≤ 0.2.4 holds grant option on `df.http` but
nothing on `df.http_multipart`. After the upgrade their previously-working
`df.grant_usage(role, include_http => true)` aborts on the second `GRANT`, and
because the whole function is one transaction the target role receives
*nothing* — not even the schema `USAGE` and table grants that execute earlier.
The failure is silent-until-invoked and looks like an unrelated permissions
regression.

`df.revoke_usage()` already guards the same function with `EXCEPTION WHEN
insufficient_privilege`; `df.grant_usage()` does not.

### Suggested fix

Wrap the `df.http_multipart()` grant in its own `BEGIN ... EXCEPTION WHEN
insufficient_privilege THEN NULL; END` block, mirroring `revoke_usage()`, so a
partially-privileged delegated admin degrades instead of aborting. Add a
backfill `DO` block to the upgrade script deriving grantees (and grant-option
holders) from `aclexplode(proacl)` on `df.http`. At minimum, document the
manual re-grant in the CHANGELOG and in the v0.2.5 entry of
[upgrade-testing.md](upgrade-testing.md).

A backfill is Scenario-A safe: a fresh install and the upgrade harness both have
zero `df.http` grantees, so the added block is a no-op there.

---

## 4. Malformed node config panics the orchestration

**Severity: 🟡 Medium — both functions.**

In `execute_function_graph.rs`, both HTTP node handlers write `submitted_by`
into the parsed config unconditionally
([:1818](../src/orchestrations/execute_function_graph.rs) for `HTTP`,
[:1917](../src/orchestrations/execute_function_graph.rs) for `HTTP_MULTIPART`):

```rust
config["submitted_by"] = serde_json::Value::String(node.submitted_by.clone());
```

Every other access in those handlers is guarded (`config.get(...).and_then(|v|
v.as_str())`), but `IndexMut` on `serde_json::Value` panics for any value that
is neither an object nor null.

The path is reachable. `nodes_structure_chk` only requires `query IS NOT NULL`
— there is no JSON-shape constraint — so a hand-written node whose `query` is
valid JSON but not an object (`"[1,2,3]"`, `"42"`, `"\"str\""`) inserts
successfully, parses successfully, passes every guarded read as `None`, and then
panics with `cannot access key "submitted_by" in JSON array`.

This is worse than the failure mode in finding 2: an `Err` produces a clean
failed node with a readable message, whereas a panic inside a replayed
orchestration is a much less graceful outcome for a caller-supplied input.

### Suggested fix

Add `if !config.is_object() { return Err("HTTP node config must be a JSON
object".into()); }` immediately after parsing, in both handlers. Optionally
tighten `nodes_structure_chk` to require `jsonb_typeof(query::jsonb) = 'object'`
for HTTP node types — but that is an upgrade-script change and must not reject
rows written by an older version.

---

## 5. Unvalidated `filename` in `Content-Disposition`

**Severity: 🟡 Medium — `df.http_multipart()` only.**

`part.filename` is variable-substituted in the orchestration — so it can carry
values from an upstream SQL node or an HTTP response body — and is then passed
straight into the part header
([src/activities/execute_multipart.rs:181](../src/activities/execute_multipart.rs)):

```rust
if let Some(filename) = &part.filename {
    req_part = req_part.file_name(filename.clone());
}
```

Of the three attacker-influenceable part fields, `filename` is the only
unguarded sink:

| Field | reqwest handling | Result |
|---|---|---|
| `name` | percent-encoded (`\r` → `%0D`, `\n` → `%0A`) | safe |
| `content_type` | validated by `mime_str()`, rejects invalid tokens | safe |
| `filename` | quoted-string with backslash escaping only | raw CR/LF survive |

Backslash-escaping produces a valid RFC 7578 quoted-pair, so a strict parser
reconstructs the literal filename. Lenient server-side parsers that split part
headers on CRLF before unquoting can be induced to see forged per-part headers.

### Suggested fix

Reject control characters (and cap length) in `filename` inside the activity,
*after* substitution — validating only at DSL time would miss substituted
values. Same treatment for `name`, for consistency, even though reqwest already
encodes it.

---

## 6. Missing negative tests

**Severity: 🟡 Medium — `df.http_multipart()` only.**

`execute_multipart` reimplements the four-layer security gate by hand
(privilege check, scheme validation, allowlist validation, SSRF-safe resolver).
None of it is exercised by a test.

Specifically missing:

- No SSRF / allowlist-block test for multipart.
- No raw-`Durofut`-JSON bypass test. `tests/e2e/sql/47_http_dsl_disabled.sql`
  covers hand-written `HTTP` nodes but has no `HTTP_MULTIPART` case, so the
  execution-time enforcement that backstops the DSL guard is unverified.
- No privilege-denial test for `df.http_multipart()`.

`HTTP_MULTIPART` appears in no test file other than
`tests/e2e/sql/06_http_and_ssrf.sql`. #303 and #304 added multipart tests, but
all of them are positive-path (produced payload, partial-interpolation
rejection, binary roundtrip).

---

## 7. Tests that pass without asserting

**Severity: 🟡 Medium — `df.http_multipart()` only.**

The multipart E2E tests treat a non-200 from `httpbingo.org` as a pass:

```sql
RAISE NOTICE 'TEST PASSED: http_multipart (completed; httpbingo non-200, body checks skipped): %', node_result;
```

The pattern is now repeated across the tests added in #303 and #304. A
httpbingo outage — or any upstream change that stops returning 200 — turns the
whole multipart suite green while asserting nothing about the request that was
actually sent.

Even on the 200 path the assertions are thin. The first multipart test builds a
two-part body but only checks for `multipart/form-data` and the plain field
value `hello multipart`; the file part's `filename` (`test.txt`), its
`content_type` (`text/plain`) and its decoded contents are never asserted. The
file part is the whole point of the feature and is the only part that exercises
base64 decoding and `Content-Disposition` construction — precisely the code that
finding 5 and the #303 base64 fix concern.

The tests should either fail on a non-200, or assert against a local fixture
server so the outcome does not depend on a third-party service — and should
assert on the echoed file part, not just the plain field.

---

## 8. Documentation gaps

**Severity: 🟢 Low (reduced from Medium). Status: partially addressed.**

#303 and #304 added the missing `USER_GUIDE.md`, `docs/api-reference.md` and
`CHANGELOG.md` coverage. What remains:

- [grammar.md](grammar.md) — zero mentions of `df.http_multipart`.
- [http-security.md](http-security.md) — zero mentions. The document opens by
  scoping itself to `df.http()`, but the security model it describes now governs
  two functions.
- The `include_http` and sensitive-function lists still name only `df.http()`,
  even though `df.grant_usage()` / `df.revoke_usage()` now cover
  `df.http_multipart()` as well:
  - `USER_GUIDE.md` — the `include_http` parameter table, the sensitive-functions
    paragraph, and the `df.revoke_usage()` description.
  - `docs/api-reference.md` — the `df.grant_usage()` description and its
    `include_http` parameter row, which spells out the full
    `df.http(text, text, text, jsonb, integer)` signature and omits the
    multipart one.
  - [src/lib.rs:603](../src/lib.rs) — the code comment above the
    `REVOKE ... FROM PUBLIC` block still reads "df.http(), df.metrics(),
    df.grant_usage() and df.revoke_usage() are sensitive", while the block
    immediately below it revokes `df.http_multipart()` too.

---

## 9. Activity duplication

**Severity: 🟢 Low. Status: partially addressed.**

`execute_multipart.rs` began as a near-copy of `execute_http.rs`. #304
extracted the shared `activities::http_response` module (`collect_headers`,
`read_body`, `build_envelope`), and `build_client` was already shared.

Still hand-duplicated between the two activities:

- `check_multipart_privilege` / `check_http_privilege` — near-identical.
- The three-layer validation chain (scheme, allowlist, resolver) plus its audit
  `trace_info` calls.
- The `map_err` error classification (SSRF block detection, timeout, connect
  failure).

`execute_multipart.rs` is now 319 lines against `execute_http.rs`'s 250. The
risk is unchanged from the original finding: future hardening applied to one
path and not the other. The `http_response` module header makes the argument
for sharing better than this document can — the same reasoning applies to the
security chain, which has a stronger claim to it than envelope construction
does.

Note that this finding and [finding 18](#18-http_multipart-node-type-is-unnecessary)
are two routes to the same place. Extracting the shared preamble fixes the
duplication without touching the node type; collapsing the node type removes it
as a side effect. Only one of the two needs doing.

---

## 10. Privilege error message does not name the function

**Severity: 🟢 Low — applies to both.**

Both activities emit a byte-identical string when the privilege check fails:

```rust
// execute_http.rs:39 and execute_multipart.rs:44
.map_err(|e| format!("HTTP privilege check failed for role '{submitted_by}': {e}"))?;
```

The multipart text is a copy-paste from `execute_http`. Read in isolation — in
a log line, or in an instance's error field — the message does not say which of
the two functions was denied.

This is a message-quality nit rather than a triage blocker: `df.nodes.node_type`
records `HTTP` or `HTTP_MULTIPART` on the failing row, so the surrounding record
is unambiguous even when the string is not. Naming the function in the message
would still save a lookup.

---

## 11. `USER_GUIDE.md` misdescribes 5xx and retry behaviour

**Severity: 🟢 Low — applies to both.**

[USER_GUIDE.md:679](../USER_GUIDE.md) states:

> - **5xx responses**: Activity fails and may be retried

Neither half is true of the current implementation.

**5xx does not fail the activity.** There is no `error_for_status()` call
anywhere in `src/`. Only a transport-level failure from `request.send()`
produces an `Err`; the status of a response that did arrive is simply read into
the envelope ([execute_http.rs:220](../src/activities/execute_http.rs),
[execute_multipart.rs:231](../src/activities/execute_multipart.rs)):

```rust
let status = response.status();
let is_ok = status.is_success();
```

A 500 therefore returns `Ok` with `"ok": false`, exactly like the 404 that
`tests/e2e/sql/06_http_and_ssrf.sql` already asserts flows through as a normal
result. Branching on `$result.ok` is the intended handling, and the guide's
line sends users looking for a failure that never arrives.

**Nothing retries.** Both call sites are
`ctx.schedule_activity(...).await?`
([:1826](../src/orchestrations/execute_function_graph.rs),
[:1925](../src/orchestrations/execute_function_graph.rs)) with no retry policy
configured — there is no `with_retry` or `max_attempts` anywhere in
`src/orchestrations/`, `src/worker.rs` or `src/registry.rs`. An activity `Err`
propagates and fails the node on the first attempt.

### The residual concern

Activity execution is nonetheless at-least-once: if the worker dies after the
request reaches the wire but before the activity result is appended to history,
recovery re-executes the activity and the upload is delivered twice. That is a
real hazard for a non-idempotent multipart POST, and it is the caveat
`USER_GUIDE.md` should carry — along with guidance on idempotency keys where the
endpoint supports them.

**This half is unverified.** It follows from the usual durable-execution
replay model, but duroxide's exact crash-recovery behaviour for in-flight
activities has not been confirmed against the runtime. Confirm before writing
it into the user guide.

---

## 12. `content_type` not substituted

**Severity: 🟢 Low — `df.http_multipart()` only.**

Variable substitution is applied to `url`, `headers`, each part's `name` and
`filename`, and — since #303 — each part's `data_b64` as a whole value.
`content_type` is the sole field that is silently skipped; it does not appear
anywhere in `execute_function_graph.rs`.

#303 widened the asymmetry by adding `data_b64`. A user who parameterizes
`filename` will reasonably expect `content_type` to behave the same way, and
gets a literal `$var` sent as a MIME type instead. Either substitute it or
document the exclusion.

---

## 13. Framing headers forwarded unfiltered

**Severity: 🟢 Low — both functions.**

`execute_multipart` filters exactly one caller-supplied header
([src/activities/execute_multipart.rs:160](../src/activities/execute_multipart.rs)):

```rust
if key.eq_ignore_ascii_case("content-type") {
    // skipped — reqwest sets the boundary
}
```

`execute_http` filters nothing at all. Everything else in the `headers` JSONB
goes to `RequestBuilder::header()`, which *appends* rather than replaces — and
`.multipart()` appends its own `Content-Type` and `Content-Length`. So a caller
can attach a second `Content-Length`, a `Transfer-Encoding: chunked` alongside
the generated `Content-Length` (the CL.TE pair), or a `Host` that decouples
request routing from the host the allowlist and SSRF resolver actually
validated.

Whether hyper normalises or rejects these before they reach the wire is
version-dependent, so this is hardening rather than a demonstrated bypass. But
the allowlist is the extension's own control, and leaving its integrity to the
transport layer's cleanup behaviour is the wrong place for it.

### Suggested fix

A shared case-insensitive deny-list in `activities::http_response` (or a new
shared request-building helper), covering `content-length`,
`transfer-encoding`, `host`, `connection`, `expect`, `te`, `trailer`,
`upgrade`, and `proxy-*`, plus `content-type` for the multipart path only.
Reject rather than silently drop, consistent with the fix proposed in finding 2.

---

## 14. No upper bound on `timeout_seconds`

**Severity: 🟢 Low — both functions.**

The DSL rejects `timeout_seconds <= 0` but imposes no ceiling, and both
activities deserialize the value straight from the node config into
`Duration::from_secs`
([execute_http.rs:144](../src/activities/execute_http.rs),
[execute_multipart.rs:136](../src/activities/execute_multipart.rs)).

`df.http(url, 'GET', NULL, NULL, 2147483647)` against a slow endpoint holds an
activity slot and its pooled connection for roughly 68 years. A handful of such
nodes exhausts the shared background worker's concurrency for every tenant on
the instance — no privilege beyond `include_http` required.

The natural fix is the same GUC treatment proposed in finding 1: a `SUSET`
`pg_durable.http_max_timeout_seconds` clamp enforced in the activity, so it
applies to hand-written nodes as well as DSL-built ones.

---

## 15. Exact-case method match

**Severity: 🟢 Low — both functions.**

`execute_multipart` matches the method with an exact-case comparison
([src/activities/execute_multipart.rs:141](../src/activities/execute_multipart.rs)):

```rust
let mut request = match config.method.as_str() {
    "POST" => ..., "PUT" => ..., "PATCH" => ...,
    _ => return Err(format!("Unsupported HTTP method for multipart: {}", config.method)),
};
```

The DSL uppercases the method, so the normal path always matches. A
hand-written node with `"method": "post"` gets `Unsupported HTTP method for
multipart: post`, which reads as "POST is not supported" rather than "the
method is mis-cased". `execute_http` has the same shape.

This fails closed, so it is purely a diagnostics problem.
`config.method.to_ascii_uppercase().as_str()` fixes it.

---

## 16. `ensure_durofut` search_path change undocumented

**Severity: 🟢 Low.**

#302 narrowed `df.ensure_durofut()`'s search_path from
`pg_catalog, df, pg_temp` to `pg_catalog, pg_temp` and added a matching PS002
entry to the pgspot allowlist in `scripts/run-pgspot.sh`. Both are still in
place on `main`.

This is a security-posture change made to satisfy a linter, and the v0.2.4 →
0.2.5 entry in [upgrade-testing.md](upgrade-testing.md) records only the
`HTTP_MULTIPART` re-emit, not the search_path narrowing or the new allowlist
entry.

It also contradicts an earlier entry in the same file, which records *adding*
`df` to that same function's search_path as "defense-in-depth". One of the two
rationales is wrong, and the file currently asserts both.

---

## 17. `ensure_durofut` body differs between install and upgrade

**Severity: 🟢 Low.**

#302 re-emitted `df.ensure_durofut()` in the upgrade script, but the copy is not
byte-identical to the one in `src/lib.rs`. One line inside the function body
differs (verified with `cat -A`):

| Source | Line | Content |
|---|---|---|
| [src/lib.rs:790](../src/lib.rs) | after `END;` | `    ` (four spaces) |
| [sql/pg_durable--0.2.4--0.2.5.sql:116](../sql/pg_durable--0.2.4--0.2.5.sql) | after `END;` | empty |

Everything else matches. The consequence is that `pg_proc.prosrc` — and
therefore `pg_get_functiondef()` — differs between a fresh `CREATE EXTENSION`
at 0.2.5 and an `ALTER EXTENSION UPDATE` to 0.2.5, which is exactly the Scenario
A equivalence that [upgrade-testing.md](upgrade-testing.md) sets out to
guarantee.

CI cannot see it. The Scenario A function snapshot selects only `proname`,
`pg_get_function_arguments` and the return type
([scripts/test-upgrade.sh:648](../scripts/test-upgrade.sh)) — no `prosrc`, and
no `provolatile`, `proisstrict`, `proparallel`, `prosecdef` or `proconfig`. The
same blind spot means the search_path narrowing in finding 16 is unverified
against the fresh install, as is the attribute set on the hand-written
`CREATE FUNCTION df.http_multipart` in the upgrade script.

### Suggested fix

Restore the four spaces in the upgrade script (or drop them from `src/lib.rs`),
and extend the Scenario A function snapshot with the OID-free attribute columns
so the next divergence is caught rather than found by inspection. Still
changeable while 0.2.5 is unreleased.

---

## 18. `HTTP_MULTIPART` node type is unnecessary

**Severity: Design. Status: not adopted.**

`df.http_multipart()` has to exist as a separate SQL function — PostgreSQL
forces that, since adding `parts jsonb DEFAULT NULL` to `df.http()` makes every
existing call ambiguous, and a DROP + CREATE to avoid the overload would
destroy the function's ACL and silently revoke `include_http` from every granted
role.

But the *node type* does not have to be separate. `df.http_multipart()` could
emit a plain `HTTP` node carrying `parts` in its config, handled by
`execute_http`. That would remove:

- both CHECK constraint drop/re-adds in the upgrade script,
- the `df.ensure_durofut()` re-emit, its search_path change (finding 16) and
  its whitespace divergence (finding 17) — that function validates `node_type`
  against a list kept in sync with `VALID_NODE_TYPES`, so it only needed
  touching because a node type was added,
- the new pgspot PS002 allowlist entry,
- the `VALID_NODE_TYPES` entry and both `explain.rs` sites,
- the orchestration dispatch arm and `execute_http_multipart_node`,
- the duplicated preamble in `execute_multipart.rs` — privilege check,
  validation chain, error classification (finding 9),
- the grant / revoke / `REVOKE ... FROM PUBLIC` triplication.

The multipart *body building* — base64 decoding, `Part` construction,
`mime_str()` validation, `filename` handling, the `content-type` skip — is
required either way and does not go away; it just moves into `execute_http`.

Privilege enforcement would stay on `df.http` alone, which matches #302's own
framing that HTTP egress is one privilege. The 235-line upgrade script collapses
to roughly a single `CREATE FUNCTION`.

This remains actionable because `0.2.5` is unreleased, so the upgrade script is
not yet a shipped contract. That window closes at release.

### Experiment and decision

This change was implemented and tested on `fix/http-and-multipart`. It replaced
`HTTP_MULTIPART` with `HTTP`, dispatched multipart requests by inspecting
`query.parts`, and removed the corresponding constraint and
`ensure_durofut()` migration changes. Focused E2E and upgrade tests passed.

The full E2E suite then exposed the cost: one workflow contains both a normal
HTTP download and a multipart upload. A query that previously selected its
download with `node_type = 'HTTP'` became ambiguous and selected the multipart
response instead. Fixing that required each consumer to inspect the internal
JSON payload shape (`query::jsonb->'parts'`) rather than use the explicit,
database-enforced operation type.

The implementation was reverted. The DDL removed by the merge was one-time,
mechanical upgrade work, while the merge added permanent runtime branching and
made operational and test queries less clear. `HTTP_MULTIPART` therefore
remains the intentional discriminator between ordinary HTTP requests and
multipart uploads.
