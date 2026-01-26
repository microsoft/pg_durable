# Using pg_durable Templates as a First-Pass Replacement for `cron.schedule`

This guide shows how to use pg_durable’s `create_template` API to emulate basic features of [pg_cron](https://github.com/citusdata/pg_cron), and argues for a more advanced approach using tables and PL/pgSQL functions for true job management (schedule/unschedule) in your database.

---

## 1. Creating a Simple Cron Template (First-Pass Replacement)

A straightforward template can be registered using `df.create_template` to provide recurring SQL job capabilities, like cron.schedule, but without job tracking or cancellation.

```sql
SELECT df.create_template(
  'cron',
  $$
    @>(df.wait_for_schedule('{schedule}') ~> df.sql({program}))
  $$,
  'Runs a SQL command on a cron schedule. 
   Provide the `program` argument as a string literal.
   For complex expressions, use double dollar quoting.'
);
```

WARNING: the current spec/implementation of templates does not support this pattern because variable substitution happens during orchestration. wait_for_schedule would error out on a placeholder.

### **How to Use**

- **schedule**: Should be a standard cron-format string (e.g. `'0 0 * * *'` for midnight daily).
- **program**: The SQL command/expression to run, provided as a string literal. If your command contains single quotes or is complex, use double dollar signs in the value (e.g., `$$VACUUM$$`).
- The template does not store any mapping between job name and instance id. There’s no built-in cancellation, audit, or history at this level.

#### **Example: Midnight Vacuum**

```sql
SELECT df.start_template(
  'cron',
  'midnight_vacuum',
  jsonb_build_object(
    'schedule', '0 0 * * *',
    'program', $$VACUUM$$
  )
);
```

Or, for a more complex program:

```sql
SELECT df.start_template(
  'cron',
  'weekly_cleanup',
  jsonb_build_object(
    'schedule', '0 8 * * 1',
    'program', $$DELETE FROM logs WHERE created_at < now() - interval '7 days'$$
  )
);
```

---

## 2. Enhancing Scheduling: Support for Unschedule

While the simple template lets you launch jobs, there’s no mechanism to track them, update, list, or cancel. To emulate `cron.unschedule` and manage jobs better, you’ll want to:

1. **Create a job tracking table**  
    ```sql
    CREATE TABLE df_cron_jobs (
      job_name TEXT PRIMARY KEY,
      instance_id TEXT NOT NULL
    );
    ```

2. **Provide a helper function (or procedure) to schedule jobs and store them**  
    ```sql
    CREATE OR REPLACE FUNCTION df_schedule(
      job_name TEXT,
      schedule TEXT,
      program TEXT
    ) RETURNS TEXT AS $$
    DECLARE
      inst_id TEXT;
    BEGIN
      -- Launch job
      SELECT df.start(
        '@>(df.wait_for_schedule(''' || schedule || ''') ~> ' || program || ')',
        job_name
      ) INTO inst_id;

      -- Track instance
      INSERT INTO df_cron_jobs (job_name, instance_id) VALUES (job_name, inst_id);

      RETURN inst_id;
    END;
    $$ LANGUAGE plpgsql;
    ```

    **Note:** For complex programs, you may wish to accept a string literal. You could adapt `df_schedule` to take the argument and wrap/quote it as needed for SQL.

3. **Provide an unschedule function**  
    ```sql
    CREATE OR REPLACE FUNCTION df_unschedule(
      job_name TEXT
    ) RETURNS BOOL AS $$
    DECLARE
      inst_id TEXT;
      ok BOOL := false;
    BEGIN
      SELECT instance_id INTO inst_id FROM df_cron_jobs WHERE job_name = job_name;
      IF inst_id IS NOT NULL THEN
        PERFORM df.cancel(inst_id, 'unscheduled by df_unschedule');
        DELETE FROM df_cron_jobs WHERE job_name = job_name;
        ok := true;
      END IF;
      RETURN ok;
    END;
    $$ LANGUAGE plpgsql;
    ```
    You can also add error handling and status columns if desired.

---

### **Why Not Use Templates for Full Job Management?**

Once you start using PL/pgSQL functions and tables to manage job state, instance_id mapping, scheduling, and cancellation, the **value of templates for this use case drops sharply**.

**Reasons:**
1. **Minimal benefit for job management:**  
   Templates help abstract reusable logic, but once you control the whole scheduling lifecycle with table and functions, you’re already encapsulating the repeated code.

2. **Templates alone can't handle nested or dynamic instance creation:**  
   For “pg_cron-style” management, you want to be able to create new scheduled jobs, track their instance ids, audit, and unschedule—**but templates don’t allow you to nest workflow logic or to have a template call `df.start` and capture the created instance id.**

3. **Templates lack hooks for side effects:**  
   You can't use a template to call another durable function and intercept the returned instance_id for recording in a table, because the pg_durable DSL does not support "save my instance id to an external table on startup."

**Conclusion:**
- **Templates are a fantastic match for reusable, parameterized DSL logic,** such as reusable ETL or processing pipelines.
- **For advanced job management—scheduling, cancelling, tracking—you’re better off using functions and tables around `df.start`,** treating durable function instances as your "job" objects.

---

## **Example: Advanced Scheduling Without Templates**

**Scheduling a job:**
```sql
SELECT df_schedule('daily_report', '0 7 * * *', $$SELECT generate_daily_report()$$);
```

**Unscheduling a job:**
```sql
SELECT df_unschedule('daily_report');
```

**Listing jobs:**
```sql
SELECT * FROM df_cron_jobs;
```

**Note**: In these advanced patterns, you have all the control, audit, and update capabilities you’d expect from a scheduling engine, with jobs tracked by name and instance ID in your own table—regardless of template usage.

---

## **Summary**

- Using pg_durable templates gives you a nice first-pass replacement for basic `cron.schedule`.
- For full job lifecycle management (schedule, unschedule, tracking, audit), use PL/pgSQL functions and a jobs table to orchestrate creation/cancellation and store mappings.
- Templates aren’t well-suited for “cron server” patterns needing creation/cancellation hooks because nested instance management in template DSL is not supported.
