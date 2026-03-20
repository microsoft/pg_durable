-- =============================================================================
-- Customer Support Triage Pipeline — built on pg_durable
-- =============================================================================
--
-- Demonstrates a pipeline with human-in-the-loop approval for support tickets:
--   1. Reads incoming support tickets from a source table
--   2. Extracts sentiment, urgency, and a recommended next action via LLM
--   3. Pauses for a support lead to review and approve the triage (up to 1 hr)
--   4. Generates a draft customer reply only after approval
--   5. Writes enriched tickets into a work-queue table for agents to pick up
--
-- Prerequisites:
--   CREATE EXTENSION pg_durable;
--   CREATE EXTENSION vector;
--   CREATE EXTENSION azure_ai;
--   \i sql/ai/ai_pipeline_functions.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Set up source and sink tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS support_tickets (
    id          SERIAL PRIMARY KEY,
    customer    TEXT NOT NULL,
    product     TEXT NOT NULL,
    subject     TEXT NOT NULL,
    body        TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ticket_work_queue (
    id              INT,
    customer        TEXT,
    product         TEXT,
    subject         TEXT,
    body            TEXT,
    extracted       JSONB,      -- {sentiment, urgency, next_action, category}
    generated       TEXT,       -- draft reply for the agent to send
    embedding       vector,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Step 2: Create the pipeline with triage + approval gate
-- ---------------------------------------------------------------------------

SELECT ai.create_pipeline(
    name   => 'support_triage',
    source => ai.table_source('support_tickets'),
    steps  => ARRAY[
        -- Analyse the ticket: sentiment, urgency, suggested next action
        ai.extract(
            model        => 'gpt-4.1',
            input_column => 'body',
            data         => ARRAY[
                'sentiment: string - customer sentiment (positive, neutral, negative)',
                'urgency: string - urgency level (low, medium, high, critical)',
                'category: string - issue category (billing, product_defect, shipping, general_inquiry, feature_request)',
                'next_action: string - recommended next action for the support agent'
            ]
        ),
        -- Pause until a support lead approves the triage before drafting a reply
        ai.request_approval(
            content => 'body',
            notify  => 'support-leads',
            timeout => 3600
        ),
        -- After approval, draft a customer-facing reply
        ai.generate(
            model           => 'gpt-4.1',
            prompt_template => 'You are a helpful customer support agent for an online store. '
                               'Write a concise, empathetic reply to the following support ticket. '
                               'Address the customer by name and reference their product.\n\n'
                               'Customer: {{customer}}\n'
                               'Product: {{product}}\n'
                               'Subject: {{subject}}\n'
                               'Message: {{body}}\n',
            input_column    => 'body',
            max_tokens      => 512
        ),
        -- Embed the ticket for similarity search / deduplication
        ai.embed(
            model        => 'text-embedding-3-small',
            input_column => 'body',
            dimensions   => 1536
        )
    ],
    sink    => ai.table_sink('ticket_work_queue'),
    trigger => 'on_change'
);

-- ---------------------------------------------------------------------------
-- Step 3: Insert sample support tickets
-- ---------------------------------------------------------------------------

INSERT INTO support_tickets (customer, product, subject, body) VALUES
    ('Maria Chen',
     'AcmePro Wireless Headphones',
     'Left earcup stopped working after 2 weeks',
     'Hi, I purchased the AcmePro Wireless Headphones two weeks ago and the '
     'left earcup has completely stopped producing sound. I have tried '
     'resetting and re-pairing but nothing works. This is really frustrating '
     'because I rely on them for work calls every day. I would like a '
     'replacement or a refund. Order #AP-90421.'),

    ('James Okonkwo',
     'AcmePro Smart Scale',
     'App sync issue — data not showing',
     'Hello, I love the scale itself, but the companion app has not synced '
     'my weight data for the past five days. I have reinstalled the app and '
     'checked Bluetooth permissions. Could you look into this?'),

    ('Priya Sharma',
     'AcmePro Running Shoes (Size 8)',
     'Wrong size shipped',
     'I ordered size 8 but received size 10. I need the correct size for a '
     'marathon next month. Please send the right pair ASAP and arrange a '
     'return for the wrong ones. Order #AP-61887.');

-- ---------------------------------------------------------------------------
-- Step 4: Run the pipeline — it will pause at the approval step
-- ---------------------------------------------------------------------------

SELECT ai.run('support_triage');

-- The pipeline will:
--   1. Load new tickets into a staging batch
--   2. Extract sentiment, urgency, category, and next_action via LLM
--   3. PAUSE — waiting for a support lead to review the AI triage
--   4. (after approval) Generate a draft customer reply
--   5. Embed the ticket text for similarity search
--   6. Write enriched tickets to ticket_work_queue

-- ---------------------------------------------------------------------------
-- Step 5: Check status — should show "pending" at the approval step
-- ---------------------------------------------------------------------------

SELECT * FROM ai.status('support_triage');

-- ---------------------------------------------------------------------------
-- Step 6: Approve — a support lead reviews and sends the signal
-- ---------------------------------------------------------------------------

-- Get the instance ID for the current run:
-- SELECT instance_id FROM ai.pipeline_runs
--     WHERE pipeline_name = 'support_triage'
--     ORDER BY started_at DESC LIMIT 1;

-- After reviewing the extraction results, approve to continue:
-- SELECT df.signal('<instance_id>', 'pipeline_support_triage_approval');

-- ---------------------------------------------------------------------------
-- Step 7: Verify the work queue is populated
-- ---------------------------------------------------------------------------

-- SELECT * FROM ai.status('support_triage');
-- SELECT ticket_id, customer, product,
--        extracted->>'sentiment'   AS sentiment,
--        extracted->>'urgency'     AS urgency,
--        extracted->>'category'    AS category,
--        extracted->>'next_action' AS next_action,
--        left(generated, 80)       AS draft_reply_preview
--   FROM ticket_work_queue;
