-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

-- Cancel the running pipeline instance.
--
-- Usage: replace <instance-id> with your actual instance ID.
--   SELECT df.cancel('<instance-id>', 'Demo complete');

-- Show running instances
SELECT * FROM df.list_instances('Running') LIMIT 5;

-- Cancel the pipeline
SELECT df.cancel(i.id, 'Demo complete')
FROM df.instances i
JOIN df.list_instances() li ON li.instance_id = i.id
WHERE li.label = 'invoice-approval-pipeline'
  AND li.status = 'Running'
ORDER BY i.created_at DESC
LIMIT 1;
