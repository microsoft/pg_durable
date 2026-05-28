-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Approve a high-value invoice that is waiting for a signal.
--
-- Automatically finds the running pipeline instance and sends the approval signal.
-- Just run:  psql -f sql/07_approve.sql

-- Show which invoices are waiting for approval
SELECT id, description, amount, status
FROM demo.invoices
WHERE status = 'awaiting_approval'
ORDER BY id;

-- Send approval signal to the most recent active pipeline instance
SELECT df.signal(i.id, 'approval', '{"approved": true, "approver": "demo-user"}')
FROM df.instances i
JOIN df.list_instances() li ON li.instance_id = i.id
WHERE li.label = 'invoice-approval-pipeline'
  AND li.status = 'Running'
ORDER BY i.created_at DESC
LIMIT 1;
