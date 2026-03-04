-- Scenario Test: Order Processing with Variables
-- Based on USER_GUIDE.md Example 4: With Variables
-- Tests variable substitution in a realistic order processing flow

-- Reset orders for test
UPDATE playground.orders SET status = 'pending', processed_at = NULL WHERE id = 1;

CREATE TEMP TABLE _test_state (instance_id TEXT);

-- Order Processing: get pending order, mark processing, complete
INSERT INTO _test_state SELECT df.start(
    'SELECT id FROM playground.orders 
     WHERE status = ''pending'' LIMIT 1' |=> 'order_id'               -- get order id
    ~> 'UPDATE playground.orders 
        SET status = ''processing'' WHERE id = $order_id'             -- mark processing
    ~> df.sleep(1)                                               -- simulate work
    ~> 'UPDATE playground.orders 
        SET status = ''completed'', processed_at = now() 
        WHERE id = $order_id',                                        -- complete
    'scenario-process-order'
);

DO $$
DECLARE
    inst_id TEXT;
    inst_status TEXT;
    processed_count INT;
BEGIN
    SELECT instance_id INTO inst_id FROM _test_state;
    RAISE NOTICE 'Testing order processing: %', inst_id;

    SELECT df.wait_for_completion(inst_id, 50) INTO inst_status;

    IF inst_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: order processing status = %', inst_status;
    END IF;
    
    -- Verify at least one order was completed
    SELECT COUNT(*) INTO processed_count 
    FROM playground.orders o
    WHERE o.status = 'completed' AND o.processed_at IS NOT NULL;
    
    IF processed_count < 1 THEN
        RAISE EXCEPTION 'TEST FAILED: expected at least 1 completed order, got %', processed_count;
    END IF;
    
    RAISE NOTICE 'TEST PASSED: scenario_order_processing (% orders completed)', processed_count;
END $$;

DROP TABLE _test_state;
SELECT 'TEST PASSED' AS result;
