-- =============================================================================
-- Bug Bash Prompt A: Process All Pending Orders
-- =============================================================================
-- Reads all pending orders from playground.orders, marks them as 'processing',
-- waits 3 seconds, then marks them as 'completed'.
-- Uses ~> for sequencing and |=> to capture the order count.
-- =============================================================================

-- Reset orders to pending (setup)
UPDATE playground.orders SET status = 'pending', processed_at = NULL;

-- Start the durable function
SELECT df.start(
    -- Step 1: Count and mark all pending orders as 'processing'
    'SELECT COUNT(*) FROM playground.orders WHERE status = ''pending''' |=> 'order_count'
    ~> 'UPDATE playground.orders SET status = ''processing'' WHERE status = ''pending'''

    -- Step 2: Wait 3 seconds (simulate work)
    ~> df.sleep(3)

    -- Step 3: Mark all processing orders as 'completed'
    ~> 'UPDATE playground.orders SET status = ''completed'', processed_at = now()
        WHERE status = ''processing''',
    'process-all-orders'
);

-- =============================================================================
-- Verification (run after ~5 seconds)
-- =============================================================================

-- Check status
SELECT df.status(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-all-orders' LIMIT 1)
);

-- See the captured order count
SELECT df.result(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-all-orders' LIMIT 1)
);

-- Confirm all orders are completed
SELECT id, status, processed_at FROM playground.orders ORDER BY id;

-- Visualize the execution graph
SELECT df.explain(
    (SELECT instance_id FROM df.list_instances() WHERE label = 'process-all-orders' LIMIT 1)
);
