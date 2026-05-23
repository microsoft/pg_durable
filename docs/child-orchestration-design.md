# Child orchestration primitives (`df.call_child` / `df.await_instance`)

## Summary

pg_durable now exposes two graph-composable primitives for parent-waits-for-child flows:

- `df.await_instance(instance_id text, timeout_seconds int default null)`
- `df.call_child(fut text, label text default null, options jsonb default null)`

Both return Durofut JSON, so they compose naturally inside `df.seq`, `df.join`, `df.race`, and operator-based graphs.

## API shape

```sql
-- Wait for an already-started instance to reach a terminal state.
df.await_instance(instance_id text, timeout_seconds int default null) returns text

-- Start a child workflow and then durably wait for it.
df.call_child(
  fut text,
  label text default null,
  options jsonb default null
) returns text
```

### Supported `df.call_child` options

- `timeout_seconds` — timeout passed to the wait phase
- `database` — database argument forwarded to the child `df.start(...)`
- `on_failure` — currently only `"raise"` is supported

## Semantics in v0.2.1

### Result shape

On success, both primitives resolve to a JSON envelope:

```json
{
  "instance_id": "<child instance id>",
  "status": "completed",
  "result": <child output>
}
```

If the child output is valid JSON, it is embedded as JSON. Otherwise it is returned as a JSON string.

### Failure semantics

- `completed` child → success envelope above
- `failed` / `cancelled` child → raises in the parent
- timeout → raises in the parent

This settles the default behavior as **raise on non-success**.

### Cancellation propagation

Parent cancellation does **not** automatically cancel children started via `df.call_child` in this release. Children are regular durable instances started through `df.start(...)`, so they continue independently unless cancelled separately.

### Identity exposure

The child `instance_id` is included in the success envelope so callers can inspect child state through existing monitoring APIs.

### Variable and label inheritance

- Labels do not inherit automatically; `df.call_child(..., label => ...)` sets the child label explicitly.
- `df.vars` inheritance uses the existing `df.start(...)` behavior because `df.call_child` starts the child through `df.start(...)`. Variables visible to the running child are whatever `df.start(...)` captures in that child-starting SQL step.

## Implementation notes

- `df.await_instance` is implemented as a dedicated `AWAIT_INSTANCE` node type.
- The orchestration polls child status durably through an activity plus a durable timer, so the parent suspends without holding a backend session.
- `df.call_child` is a convenience wrapper that expands to:
  1. a SQL node that calls `df.start(...)` for the child and stores the returned child `instance_id`
  2. an `AWAIT_INSTANCE` node that waits on that stored `instance_id`

This keeps the implementation small while still giving users a first-class, graph-composable child orchestration primitive.
