# Proposal: A Generalized Sequence Pipeline Template for pg_durable

## Problem Statement

Many analytics and data engineering workflows need to process streams of new data by **batching unprocessed rows** with an increasing identifier (often an `event_id` or sequence/serial column). Triggering such work at **scheduled intervals** and in manageable **batch sizes** is critical for performance, recovery, and analytics freshness.

[pg_incremental](https://github.com/infinyon/pg_incremental) offers a convenient way to build "sequence pipelines" that incrementally process new table inserts by batching unprocessed primary key ranges and invoking user-defined SQL aggregators for each batch. Users of [pg_cron](https://github.com/citusdata/pg_cron) have also long expressed a need for pipelines that run batch ETL jobs or rowwise computations reliably on a schedule.

We aim to deliver similar capabilities with **pg_durable**, allowing users to define pipelines that:

- Parameterize the **source table** to scan
- Set a **cron schedule** for when the pipeline runs
- Control **batch size** per run
- Specify **custom SQL code** that operates on each batch (with safe parameterization, no DSL limitations)

The template should be fully reusable, support state tracking (i.e., what's been processed), and surface a convenient SQL interface for starting new pipelines.

---

## Design Overview

We propose a pg_durable template, named `sequence_pipeline`, with placeholders for:

- **`{source_table}`** — the input table containing data to be aggregated.
- **`{schedule}`** — execution interval (cron syntax).
- **`{batch_size}`** — how many sequence values to process per batch.
- **`{user_code}`** — user-provided SQL code run for each batch. Provided as plain SQL, NOT pg_durable DSL, for maximal flexibility.

Pipelines instantiated from this template:
- Track max processed ID in a side table
- Use a durable-workflow loop to safely process new batches
- Invoke the user’s `:start` and `:end`-parameterized SQL on each chunk

---

## Implementation

### Template Definition

Register the following template with `df.create_template`:

```sql
SELECT df.create_template(
  'sequence_pipeline',
  $$
  @>(
    df.wait_for_schedule('{schedule}')
    ~> -- Get min/max range from source table, above last processed
    'SELECT COALESCE(min(event_id), -1) AS min_id, COALESCE(max(event_id), -1) AS max_id
      FROM {source_table}
      WHERE event_id > COALESCE((SELECT max_processed FROM seq_batch.progress_tracking WHERE pipeline = ''{template_id}''), -1)'
      |=> 'rng'
    ~> df.if(
         'SELECT $rng.min_id < 0',
         'SELECT ''no work''',
         df.loop(
           'SELECT LEAST($rng.min_id + {batch_size} - 1, $rng.max_id) as batch_end, $rng.min_id as batch_start' |=> 'bounds'
           ~> df.activity({user_code}, input_json := jsonb_build_object('start', $bounds.batch_start, 'end', $bounds.batch_end))
           ~> 'UPDATE seq_batch.progress_tracking SET max_processed = $bounds.batch_end WHERE pipeline = ''{template_id}''',
           'SELECT $bounds.batch_end < $rng.max_id'
         )
       )
    )
  )
  $$
  , 'Sequence batch pipeline with template params'
);
```

---

### Progress Tracking

Create a schema and support table so each pipeline instance can record which IDs have been processed:

```sql
CREATE SCHEMA IF NOT EXISTS seq_batch;

CREATE TABLE IF NOT EXISTS seq_batch.progress_tracking (
    pipeline TEXT PRIMARY KEY,
    max_processed BIGINT DEFAULT -1
);
```

---

### SQL Wrapper Function

Provide a helper so end users can easily start new pipelines:

```sql
CREATE OR REPLACE FUNCTION seq_batch.start_sequence_pipeline(
    pipeline_name TEXT,           -- The pipeline instance name
    source_table TEXT,            -- The input table
    schedule TEXT,                -- Cron syntax: e.g., '* * * * *'
    batch_size INT,               -- Number of IDs per batch
    user_code TEXT,               -- User SQL with :start and :end
    label TEXT DEFAULT NULL       -- Optional workflow label
) RETURNS TEXT AS $$
BEGIN
    RETURN df.start_template(
        'sequence_pipeline',
        label,
        jsonb_build_object(
            'template_id', pipeline_name,
            'source_table', source_table,
            'schedule', schedule,
            'batch_size', batch_size,
            'user_code', user_code
        )
    );
END;
$$ LANGUAGE plpgsql;
```

---

### Example: Aggregating Events per Day

Suppose you want to keep a daily aggregate table up-to-date as new events arrive:

```sql
-- 1. Create (or ensure) the target table:
CREATE TABLE events_agg (
  day timestamptz PRIMARY KEY,
  event_count bigint
);

-- 2. Register the pipeline’s progress (if not already present):
INSERT INTO seq_batch.progress_tracking (pipeline, max_processed) VALUES ('event-aggregation', -1)
  ON CONFLICT DO NOTHING;

-- 3. Start the pipeline:
SELECT seq_batch.start_sequence_pipeline(
  'event-aggregation',
  'events',
  '* * * * *', -- every minute
  10000,       -- batch size
  $user$
    INSERT INTO events_agg
    SELECT date_trunc('day', event_time), count(*)
    FROM events
    WHERE event_id BETWEEN :start AND :end
    GROUP BY 1
    ON CONFLICT (day) DO UPDATE SET event_count = events_agg.event_count + excluded.event_count;
  $user$,
  'agg-events'
);
```

---

## Notes

- The `{user_code}` SQL block is executed by the template, with parameters `:start` and `:end` bound to the batch limits.
- To guarantee SQL safety, recommend users use parameter substitution, not string concatenation.
- The pipeline is self-healing: if interrupted, it resumes at the last processed ID.
- This approach replicates the power and convenience of [pg_incremental](https://github.com/infinyon/pg_incremental)'s `create_sequence_pipeline` while allowing greater customization.

---

## References

- [pg_incremental README](https://github.com/infinyon/pg_incremental#readme)
- [pg_cron](https://github.com/citusdata/pg_cron)
- [pg_durable Templates](https://github.com/Azure/pg_durable)