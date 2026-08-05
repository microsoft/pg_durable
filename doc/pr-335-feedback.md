# PR 335 Review Feedback Disposition

Evaluated against rebased PR 335 at commit `8fabd62` on 2026-08-05. The review
was written against `4b3d47e`, before PR 335 was rebased onto the final PR 334
implementation.

## Decision summary

| ID | Finding | Decision | Status |
|---|---|---|---|
| F1 | Node limit does not bound the discovery frontier | Fix in PR 335 | Completed |
| F2 | Node insertion uses the retry helper with one fixed candidate | Fix in PR 335 | Completed |
| F3 | Graph ID generation is unbounded and flattening has no interrupt point | Fix in PR 335 | Completed |
| F4 | Flattened nodes contain fabricated identity fields | Fix in PR 335 | Completed |
| F5 | `validate_recursive()` uses non-production IDs and discards the graph | Partially accept; retain the helper but make its IDs realistic and test `flatten_graph()` directly | Completed |
| F6 | Tests do not pin the new materialization invariants and some assertions are weak | Add focused tests in PR 335 | Completed |
| F7 | New graph-materialization APIs do not document their contracts | Add documentation in PR 335 | Completed |
| P3.1 | `df.explain()` no longer renders a partial tree for invalid graphs | Accept behavior change | No action |
| P3.2 | Validation error precedence changed | Accept behavior change | No action |
| P3.3 | Pre-order insertion depends on three deferred foreign keys | Add an explicit schema regression assertion | Completed |
| P3.4 | `root.clone()` duplicates the input graph | Defer optimization | No action in PR 335 |
| P3.5 | Embedded-config validation runs twice | Stale after rebase | No action |
| P3.6 | Paths allocate eagerly and can make long errors | Accept current implementation | No action |
| P3.7 | Unknown `node_type` is echoed in errors | Pre-existing and out of scope | No action |
| P3.8 | Root parse errors differ between start and explain | Pre-existing and out of scope | No action |
| O1 | Batch the per-node SPI inserts | Track separately | Deferred |
| O2 | Remove quadratic DSL envelope serialization | Track separately | Deferred |

`Completed` means the accepted work was implemented and validated in follow-up
commits on PR 335. Deferred and no-action decisions remain intentionally open
only as separate follow-up opportunities.

## Rebase impact

The PR 334 rebase materially changes one review conclusion:

- `flatten_graph()` now calls `validate_config_children()` once per emitted
  node. That method enforces that `condition_node` is only used by IF/LOOP,
  `extra_nodes` is only used by JOIN, and legacy children embedded in `query`
  remain rejected.
- `materialized_query()` only parses and updates the config object. It no longer
  repeats structural validation.
- The existing-query test now exercises `flatten_graph()` through
  `test_flatten_graph_preserves_existing_query`.

Therefore P3.5 is stale. The rebase does not resolve the other accepted
findings below.

## Accepted work

### F1: Bound discovery before parsing children

**Decision:** Accept. This is the highest-priority correction.

`MAX_GRAPH_NODES` is checked against `nodes.len()` at the top of the pop loop,
but all children of the current node are deserialized, assigned IDs, and added
to `children` before another node is popped. One wide JOIN can therefore make
the pending frontier proportional to input size rather than to the configured
node limit.

Change `flatten_graph()` to count discovered nodes, including the root, and
reject a child in `parse_child` before `child_from_raw()` or `ids.next_id()`
would exceed `MAX_GRAPH_NODES`. Keep the pop-time check only if it remains a
useful defensive assertion.

Validation:

- Exactly 10,000 total nodes succeeds and 10,001 fails.
- An oversized wide JOIN calls the ID source at most 10,000 times.
- The failure retains the path of the first child beyond the limit.

### F2: Remove the misleading one-attempt retry

**Decision:** Accept the cleanup, not a late re-roll.

Node IDs are already embedded in parent references and materialized config
before insertion. `insert_node()` therefore cannot safely generate a new ID
after a conflict. Calling `pick_id_with_retry()` with a constant generator and
one attempt suggests resilience that the path cannot provide and emits an
inaccurate exhaustion message.

Use one direct `INSERT ... ON CONFLICT ... DO NOTHING RETURNING id` claim and
report a node-ID conflict explicitly. Keep `pick_id_with_retry()` for the
instance ID, where generating a fresh candidate is safe.

### F3: Bound ID generation and make flattening interruptible

**Decision:** Accept.

The graph-local `HashSet` makes duplicate IDs harmless, but its generation loop
has no attempt bound. More importantly, iterative materialization can perform a
large amount of pure Rust work without reaching SPI, so PostgreSQL cancellation
is not checked during the loop.

- Check PostgreSQL interrupts once per `pending.pop()` iteration.
- Limit each graph-local ID allocation to `MAX_ID_ATTEMPTS` and return a clear
  graph-construction error on exhaustion. Adapt the ID-source abstraction if
  necessary so failure is represented as a `Result` rather than raised inside
  a generic closure.
- Preserve graph-local uniqueness and the persisted eight-lowercase-hex format.

The F1 frontier fix sharply bounds this work, but it does not replace an
interrupt point.

### F4: Use an honest flattened-node type

**Decision:** Accept the dedicated-type recommendation.

`flatten_graph()` currently returns `FunctionNode` values with
`submitted_by: ""` and `database: None`. Current consumers happen to overwrite
or discard those fields, but `FunctionNode` is serializable and those fields
carry security-sensitive persistence meaning.

Introduce a crate-private materialized-node type containing only `id`,
`node_type`, `query`, `result_name`, `left_node`, and `right_node`. Use it in
`flatten_graph()`, `insert_node()`, and explain conversion. Do not encode
"not populated yet" as a valid `FunctionNode`.

### F5: Keep validation compatibility, improve its IDs and coverage

**Decision:** Partially accept.

The claim that tests exercise wholly different logic is too strong:
`validate_recursive()` calls the same `flatten_graph()` implementation used by
production. It remains useful as a compatibility helper for callers that only
need validation. However, its constant empty ID source is unrealistic, and the
discarded result cannot test materialization invariants.

Retain the helper, but generate deterministic, unique, eight-hex-character IDs
within it. Keep validation-focused tests on the helper and move ordering,
linkage, uniqueness, and boundary assertions to direct `flatten_graph()` tests.

### F6: Strengthen focused tests

**Decision:** Accept the substantive gaps, with the following scope:

- Correct the unit depth tests to exercise depths 256 and 257 exactly. The
  current "exactly the limit" test reaches only depth 255.
- Add direct materialization assertions for `nodes[0].id == root_id`, unique
  IDs, pre-order emission, and every child reference resolving to a later
  vector entry.
- Rename or strengthen
  `test_flatten_graph_assigns_preorder_ids_and_reports_error_path`; it currently
  asserts only the error path.
- Add the exact node-count and bounded-ID-source tests listed under F1.
- Make the invalid-node E2E test non-vacuous. Its `WHEN OTHERS` block currently
  also catches its own `TEST FAILED` exception. Assert the returned explain
  error rather than merely asserting that explain does not raise.
- Add semantic assertions for IF/LOOP condition links and JOIN extra links in
  the flattened output. Existing explain tests mostly check keywords and query
  fragments.

Do not add a 10,001-node E2E test. The limit is owned by pure materialization
code and can be pinned precisely and much more cheaply in unit tests.

The changed child-deserialization wording is acceptable: the new structural
path is more actionable than the removed `in IF` wording. Tests should assert
the path and the error category, not freeze the complete serde error text.

### F7: Document materialization contracts

**Decision:** Accept.

Add concise rustdoc for the flattened-node type, `IdSource`, `GraphError`, and
`flatten_graph()`. Document these invariants:

- IDs must be unique within one graph.
- A persistence caller must provide IDs satisfying `^[0-9a-f]{8}$`.
- The returned vector is pre-order and parents precede referenced children.
- The returned root ID equals the first node's ID for a non-empty valid graph.
- The ID source may fail if F3 changes it to return `Result`.

The type system need not force explain-only IDs such as `N1` to satisfy the
database constraint, because explain does not persist them. The distinction
must be explicit in the contract.

### P3.3: Pin the deferred-FK dependency

**Decision:** Accept a small regression test.

Pre-order insertion now relies on the root-node and node-reference foreign keys
being both deferrable and initially deferred. Existing E2E coverage would fail
if this changed, but the failure would be indirect. Extend the schema
constraint test to query `pg_constraint` and assert the required properties for
all three constraints. No extension upgrade script is required.

## No-action findings

### P3.1: Explain graceful degradation

The all-or-error explain behavior is intentional. A partial tree could imply
that a graph is executable when `df.start()` would reject it, while the shared
path now gives a precise structural location and returns a string instead of
aborting the statement. Add the stronger error assertion described in F6, but
do not restore partial rendering.

### P3.2: Error precedence

The precedence changes are real but move toward rejecting malformed parent
configuration before traversing descendants. Error precedence is not a public
contract, and no compatibility behavior should be added.

### P3.4: Root cloning

The clone temporarily increases memory use, but the shared single-pass design
still reduces aggregate parsing and serialization work. F1 removes the more
important unbounded-frontier amplification. Avoid complicating ownership in
this PR; consider a borrowed-root work item only with measured evidence.

### P3.5: Duplicate embedded-child validation

Rejected as stale. The rebased code validates structure once in
`flatten_graph()` and leaves `materialized_query()` responsible only for config
parsing and mutation.

### P3.6-P3.8: Paths, error echoing, and root wording

Eager path allocation is bounded by F1 and negligible at the supported graph
size. Echoing `node_type` and the start/explain root wording difference both
predate PR 335. None warrants expanding this refactor.

## Informational performance items

Batching node insertion is a credible follow-up now that materialization
produces a flat vector, but it changes SQL construction, error attribution, and
backward-compatibility-sensitive persistence code. Track and benchmark it
separately.

The quadratic JSON envelope serialization in composition operators is also
pre-existing and independent of this refactor. Track it separately rather than
mixing it into PR 335.

## Confirmed conclusions from the review

The rebase does not invalidate these no-action conclusions:

- Materialized `df.nodes.query` representations retain their prior format;
  focused condition, existing-query, and extra-node tests cover this path.
- Physical insertion order is not part of worker replay behavior because graph
  loading keys nodes by ID.
- No extension schema or upgrade script changes are needed.
- Shipped schemas in the supported upgrade range provide the deferred
  constraints required by pre-order insertion; P3.3 adds an explicit guard for
  the current schema.
- The accepted graph boundaries remain 10,000 nodes and depth 256. F1 changes
  when excess work stops, not the accepted set.
- Reversing `children` before extending the LIFO worklist preserves pre-order
  DFS emission.
- Owned raw child values represent a tree, so cycle and DAG detection is not
  required.
- Flattening completes before instance reservation and node insertion, so graph
  validation cannot leave partial rows.
- Materialization is not reachable from orchestrations and introduces no
  durable replay ordering concern.
- The iterative walker removes the previous recursive stack-growth risk.
- Reserving the instance ID before inserting its pre-generated root fixes the
  old unhandled root-ID collision path.

The adversarial probes listed in the review do not identify additional work:
input cannot forge generated node IDs; serde limits nested JSON inside query
config; the rebased structural gates reject misplaced config children;
transaction rollback prevents partial orphan writes; supported schemas permit
pre-order insertion; and no validation rule was dropped. F1 remains necessary
because those conclusions do not bound the amount of work performed before an
oversized graph is rejected.