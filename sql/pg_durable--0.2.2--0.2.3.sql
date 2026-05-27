-- pg_durable upgrade: 0.2.2 → 0.2.3
--
-- Fix: df.instance_nodes leaves race-loser nodes as 'running' or 'pending' after
-- a race completes.  The orchestrator now marks all non-terminal nodes in the
-- losing branch of a RACE as 'cancelled' once the winning branch finishes.
--
-- To support the new 'cancelled' node status, the nodes_status_chk constraint is
-- widened to include it.  The nodes_result_status_chk constraint is unchanged:
-- cancelled nodes carry no result, so result IS NULL already satisfies it.

ALTER TABLE df.nodes
    DROP CONSTRAINT IF EXISTS nodes_status_chk;

ALTER TABLE df.nodes
    ADD CONSTRAINT nodes_status_chk
        CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')) NOT VALID;
