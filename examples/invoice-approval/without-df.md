# Building the Invoice Pipeline Without pg_durable

What if `df.http()` was the *only* pg_durable feature you had? No `~>`, no `|=>`, no `df.if()`, no `@>` loops, no `df.wait_for_signal()`, no crash recovery. Just the ability to call an HTTP endpoint from SQL.

You'd need to build everything else yourself: polling, state machines, error handling, human approval gates, crash recovery, and observability. Here's what that looks like.

## What You Need to Build

| pg_durable gives you | You must build yourself |
|---|---|
| `@>` infinite loop | `pg_cron` job |
| `~>` sequencing | PL/pgSQL procedural code |
| `\|=>` named results | Local variables |
| `df.if()` branching | `IF/THEN/ELSE` |
| `df.wait_for_signal()` | Polling table + timeout logic |
| Crash recovery (replay) | Manual "stuck in processing" cleanup |
| `df.explain()` visualization | Nothing — you're flying blind |
| `df.cancel()` | Kill the cron job and hope for the best |

## The Code

### 1. Processing Function (~200 lines of PL/pgSQL)

```sql
CREATE OR REPLACE FUNCTION demo.process_one_invoice()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_inv        RECORD;
    v_req_body   TEXT;
    v_resp       TEXT;
    v_resp_json  JSONB;
    v_ok         BOOLEAN;
    v_body       JSONB;
    v_amount     NUMERIC;
BEGIN
    -- ── Poll for one pending invoice ──
    SELECT id, description, raw_amount
    INTO v_inv
    FROM demo.invoices
    WHERE status = 'pending'
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;          -- need this to avoid races

    IF NOT FOUND THEN
        RETURN;                       -- nothing to do
    END IF;

    -- ── Mark as processing ──
    UPDATE demo.invoices SET status = 'processing' WHERE id = v_inv.id;

    -- ── Build HTTP request body ──
    v_req_body := jsonb_build_object(
        'invoice_id',  v_inv.id,
        'description', v_inv.description,
        'raw_amount',  v_inv.raw_amount
    )::text;

    -- ── Call Azure Function ──
    BEGIN
        -- df.http is the ONE pg_durable feature we have
        SELECT df.start(
            df.http(
                current_setting('demo.classify_url') || '/api/classify_invoice',
                'POST',
                v_req_body,
                jsonb_build_object(
                    'Content-Type', 'application/json',
                    'x-functions-key', current_setting('demo.function_key')
                ),
                30
            )
        ) INTO v_resp;

        -- But wait — df.start() is async. We don't get the result back
        -- directly. We'd need to poll df.result() in a loop:
        FOR i IN 1..300 LOOP           -- 30 second timeout
            SELECT df.result(v_resp) INTO v_resp;
            EXIT WHEN v_resp IS NOT NULL;
            PERFORM pg_sleep(0.1);
        END LOOP;

        IF v_resp IS NULL THEN
            RAISE EXCEPTION 'HTTP call timed out';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        UPDATE demo.invoices
        SET status = 'failed', processed_at = now()
        WHERE id = v_inv.id;

        INSERT INTO demo.invoice_audit (invoice_id, action, details)
        VALUES (v_inv.id, 'classification_failed',
                jsonb_build_object('error', SQLERRM));
        RETURN;
    END;

    -- ── Parse HTTP response ──
    v_resp_json := v_resp::jsonb;
    v_ok := (v_resp_json->>'ok')::boolean;
    v_body := (v_resp_json->>'body')::jsonb;

    IF NOT v_ok THEN
        UPDATE demo.invoices
        SET status = 'failed', processed_at = now()
        WHERE id = v_inv.id;

        INSERT INTO demo.invoice_audit (invoice_id, action, details)
        VALUES (v_inv.id, 'classification_failed',
                jsonb_build_object('http_status', v_resp_json->>'status'));
        RETURN;
    END IF;

    -- ── Update invoice with classification ──
    v_amount := (v_body->>'amount')::numeric;

    UPDATE demo.invoices SET
        vendor   = v_body->>'vendor',
        category = v_body->>'category',
        amount   = v_amount
    WHERE id = v_inv.id;

    INSERT INTO demo.invoice_audit (invoice_id, action, details)
    VALUES (v_inv.id, 'classified',
            jsonb_build_object(
                'vendor',   v_body->>'vendor',
                'category', v_body->>'category',
                'amount',   v_body->>'amount'));

    -- ── Branch on amount ──
    IF v_amount > 10000 THEN
        -- High value: flag for approval
        UPDATE demo.invoices
        SET status = 'awaiting_approval'
        WHERE id = v_inv.id;

        INSERT INTO demo.invoice_audit (invoice_id, action, details)
        VALUES (v_inv.id, 'awaiting_approval',
                jsonb_build_object(
                    'amount', v_body->>'amount',
                    'vendor', v_body->>'vendor',
                    'reason', 'Amount exceeds $10,000'));

        -- Can't wait here. A separate job must poll for approvals.
        -- (see process_approvals below)
    ELSE
        -- Low value: auto-approve
        UPDATE demo.invoices
        SET status = 'approved', processed_at = now()
        WHERE id = v_inv.id;

        INSERT INTO demo.invoice_audit (invoice_id, action, details)
        VALUES (v_inv.id, 'auto_approved',
                jsonb_build_object(
                    'amount', v_body->>'amount',
                    'vendor', v_body->>'vendor'));
    END IF;
END $$;
```

### 2. Approval Polling Function (separate, because you can't "wait")

```sql
-- You need a SECOND function because the first one can't block waiting
-- for human input. This polls for approval decisions.

CREATE TABLE IF NOT EXISTS demo.approval_decisions (
    invoice_id   BIGINT PRIMARY KEY REFERENCES demo.invoices(id),
    approved     BOOLEAN NOT NULL,
    approver     TEXT,
    decided_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION demo.process_approvals()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_inv    RECORD;
    v_decide RECORD;
BEGIN
    FOR v_inv IN
        SELECT id FROM demo.invoices
        WHERE status = 'awaiting_approval'
    LOOP
        -- Check if there's a decision
        SELECT * INTO v_decide
        FROM demo.approval_decisions
        WHERE invoice_id = v_inv.id;

        IF FOUND THEN
            IF v_decide.approved THEN
                UPDATE demo.invoices SET
                    status = 'approved',
                    approved_by = v_decide.approver,
                    processed_at = now()
                WHERE id = v_inv.id;

                INSERT INTO demo.invoice_audit (invoice_id, action, details)
                VALUES (v_inv.id, 'approved',
                        jsonb_build_object('approver', v_decide.approver));
            ELSE
                UPDATE demo.invoices SET
                    status = 'rejected',
                    processed_at = now()
                WHERE id = v_inv.id;

                INSERT INTO demo.invoice_audit (invoice_id, action, details)
                VALUES (v_inv.id, 'rejected',
                        jsonb_build_object('approver', v_decide.approver));
            END IF;

            DELETE FROM demo.approval_decisions WHERE invoice_id = v_inv.id;

        ELSE
            -- Check for timeout (5 minutes)
            IF (SELECT updated_at FROM demo.invoices WHERE id = v_inv.id)
               < now() - INTERVAL '5 minutes'
            THEN
                UPDATE demo.invoices SET
                    status = 'rejected',
                    processed_at = now()
                WHERE id = v_inv.id;

                INSERT INTO demo.invoice_audit (invoice_id, action, details)
                VALUES (v_inv.id, 'rejected',
                        jsonb_build_object('timed_out', true));
            END IF;
        END IF;
    END LOOP;
END $$;
```

### 3. Crash Recovery Function (because nothing is durable)

```sql
-- If PostgreSQL crashes mid-processing, invoices get stuck in 'processing'.
-- You need a cleanup job to reset them.

CREATE OR REPLACE FUNCTION demo.recover_stuck_invoices()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE demo.invoices
    SET status = 'pending'
    WHERE status = 'processing'
      AND updated_at < now() - INTERVAL '2 minutes';

    -- Log what we recovered
    INSERT INTO demo.invoice_audit (invoice_id, action, details)
    SELECT id, 'crash_recovery',
           jsonb_build_object('was_stuck_since', updated_at)
    FROM demo.invoices
    WHERE status = 'pending'
      AND updated_at < now() - INTERVAL '2 minutes';
END $$;
```

### 4. Scheduling (3 separate cron jobs)

```sql
-- You need pg_cron. That's another extension to install and manage.

-- Poll for new invoices every 5 seconds
SELECT cron.schedule('invoice-processor', '5 seconds',
    $$SELECT demo.process_one_invoice()$$);

-- Poll for approval decisions every 5 seconds
SELECT cron.schedule('approval-processor', '5 seconds',
    $$SELECT demo.process_approvals()$$);

-- Clean up stuck invoices every minute
SELECT cron.schedule('stuck-recovery', '* * * * *',
    $$SELECT demo.recover_stuck_invoices()$$);
```

### 5. Human Approval (manual table insert instead of signal)

```sql
-- To approve an invoice, the human inserts into a table:
INSERT INTO demo.approval_decisions (invoice_id, approved, approver)
VALUES (2, true, 'demo-user');

-- Then they wait for the cron job to pick it up. Eventually.
```

### 6. Cancellation (disable cron jobs)

```sql
SELECT cron.unschedule('invoice-processor');
SELECT cron.unschedule('approval-processor');
SELECT cron.unschedule('stuck-recovery');
-- Hope nothing was mid-flight.
```

## Side-by-Side

### Starting the pipeline

**Without pg_durable:**
```sql
-- Create 3 functions (~250 lines of PL/pgSQL)
-- Install pg_cron extension
-- Schedule 3 separate cron jobs
-- Create an extra approval_decisions table
-- Hope nothing crashes between steps
```

**With pg_durable:**
```sql
SELECT df.start(
    @> (
        ($$SELECT ... FROM demo.invoices WHERE status = 'pending'$$ |=> 'inv')
        ~> df.if_rows('inv',
            $$UPDATE ... SET status = 'processing'$$
            ~> (df.http(...) |=> 'resp')
            ~> df.if($$SELECT $r.ok$$,
                -- classify, branch, wait for signal ...
            ),
            df.sleep(5)
        )
    ),
    'invoice-approval-pipeline'
);
```

### Sending an approval

**Without pg_durable:**
```sql
INSERT INTO demo.approval_decisions (invoice_id, approved, approver)
VALUES (2, true, 'demo-user');
-- Wait up to 5 seconds for cron to pick it up
```

**With pg_durable:**
```sql
SELECT df.signal('<instance-id>', 'approval',
    '{"approved": true, "approver": "demo-user"}');
-- Immediate. The waiting orchestration resumes.
```

### Seeing what's happening

**Without pg_durable:**
```sql
-- Check cron job status? Check each table manually? grep the logs?
-- There's no unified view of the pipeline.
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
```

**With pg_durable:**
```sql
SELECT df.explain('<instance-id>');
-- Shows the full execution tree with ✓/⏳/✗ on each node.
```

### Crash recovery

**Without pg_durable:** You build it yourself and pray it covers all the edge cases. What if the crash happens between the `UPDATE` and the `INSERT INTO audit`? You get inconsistent state.

**With pg_durable:** Automatic. The runtime replays from the last checkpoint. Every step is durable.

## What You're Really Building

Without pg_durable, you're building a bespoke workflow engine out of:
- **3 PL/pgSQL functions** (~250 lines) instead of 1 SQL expression (~50 lines)
- **3 cron jobs** instead of 1 `df.start()` call
- **1 extra table** (`approval_decisions`) for the approval handshake
- **1 extra extension** (`pg_cron`) for scheduling
- **Manual crash recovery** that will miss edge cases
- **No visualization** of the pipeline state
- **No clean cancellation** — just disable cron and clean up manually

And you still don't get durability. If PostgreSQL crashes between any two statements in `process_one_invoice()`, you get partial state that your crash recovery function may or may not fix correctly.
