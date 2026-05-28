-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Invoice Approval Pipeline — main durable function
--
-- This starts an infinite-loop workflow that:
--   1. Polls for pending invoices
--   2. Calls Azure Function to classify each one
--   3. Auto-approves low-value invoices (≤ $10,000)
--   4. Pauses for human approval on high-value invoices (> $10,000)
--   5. Loops back to check for more work
--
-- The loop runs until cancelled. Insert new invoices any time and they
-- will be picked up on the next iteration.

-- ── Preview the graph structure (dry-run, nothing executes) ──

SELECT df.explain(

    @> (
        -- Poll: fetch one pending invoice
        ($$SELECT id, description, raw_amount
            FROM demo.invoices
            WHERE status = 'pending'
            ORDER BY id LIMIT 1$$ |=> 'inv')

        ~> df.if_rows('inv',

            -- ═══ PROCESS INVOICE ═══

            -- Mark as processing
            $$UPDATE demo.invoices SET status = 'processing' WHERE id = $inv.id$$

            -- Build HTTP request body
            ~> ($$SELECT jsonb_build_object(
                    'invoice_id', $inv.id::int,
                    'description', $inv.description,
                    'raw_amount',  $inv.raw_amount
                )::text$$ |=> 'req_body')

            -- Call Azure Function to classify
            ~> (df.http(
                    '{classify_url}/api/classify_invoice',
                    'POST',
                    '$req_body',
                    '{"Content-Type":"application/json","x-functions-key":"{function_key}"}'::jsonb,
                    30
                ) |=> 'resp')

            -- Parse HTTP envelope
            ~> ($$SELECT ($resp::jsonb->>'ok')::boolean AS ok,
                         $resp::jsonb->>'body' AS body$$ |=> 'r')

            -- Branch on classification success
            ~> df.if(
                $$SELECT $r.ok$$,

                -- ── Classification succeeded ──
                ($$UPDATE demo.invoices SET
                    vendor   = ($r.body)::jsonb->>'vendor',
                    category = ($r.body)::jsonb->>'category',
                    amount   = (($r.body)::jsonb->>'amount')::numeric
                    WHERE id = $inv.id$$

                ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                    VALUES ($inv.id, 'classified',
                        jsonb_build_object(
                            'vendor',   ($r.body)::jsonb->>'vendor',
                            'category', ($r.body)::jsonb->>'category',
                            'amount',   ($r.body)::jsonb->>'amount'))$$

                -- Branch on amount threshold
                ~> df.if(
                    $$SELECT (($r.body)::jsonb->>'amount')::numeric > 10000$$,

                    -- ── HIGH VALUE: human approval required ──
                    ($$UPDATE demo.invoices
                        SET status = 'awaiting_approval'
                        WHERE id = $inv.id$$

                    ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                        VALUES ($inv.id, 'awaiting_approval',
                            jsonb_build_object(
                                'amount', ($r.body)::jsonb->>'amount',
                                'vendor', ($r.body)::jsonb->>'vendor',
                                'reason', 'Amount exceeds $10,000'))$$

                    -- Wait for human signal (5 minute timeout)
                    ~> (df.wait_for_signal('approval', 300) |=> 'sig')

                    ~> df.if(
                        $$SELECT NOT ($sig::jsonb->>'timed_out')::boolean
                            AND ($sig::jsonb->'data'->>'approved')::boolean$$,

                        -- Approved by human
                        $$UPDATE demo.invoices SET
                            status = 'approved',
                            approved_by = $sig::jsonb->'data'->>'approver',
                            processed_at = now()
                            WHERE id = $inv.id$$
                        ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                            VALUES ($inv.id, 'approved', $sig::jsonb->'data')$$,

                        -- Rejected or timed out
                        $$UPDATE demo.invoices SET
                            status = 'rejected',
                            processed_at = now()
                            WHERE id = $inv.id$$
                        ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                            VALUES ($inv.id, 'rejected',
                                jsonb_build_object(
                                    'timed_out', ($sig::jsonb->>'timed_out')::boolean))$$
                    )),

                    -- ── LOW VALUE: auto-approve ──
                    $$UPDATE demo.invoices SET
                        status = 'approved',
                        processed_at = now()
                        WHERE id = $inv.id$$
                    ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                        VALUES ($inv.id, 'auto_approved',
                            jsonb_build_object(
                                'amount', ($r.body)::jsonb->>'amount',
                                'vendor', ($r.body)::jsonb->>'vendor'))$$
                )),

                -- ── Classification failed ──
                $$UPDATE demo.invoices SET
                    status = 'failed',
                    processed_at = now()
                    WHERE id = $inv.id$$
                ~> $$INSERT INTO demo.invoice_audit (invoice_id, action, details)
                    VALUES ($inv.id, 'classification_failed',
                        jsonb_build_object(
                            'http_status', $resp::jsonb->>'status'))$$
            )

            -- Pause between processing iterations
            ~> df.sleep(2),

            -- ═══ NO WORK: wait before polling again ═══
            df.sleep(5)
        )
    )

);
