-- Show the live graph with execution status.
--
-- Usage: set the instance_id psql variable before running:
--   \set instance_id '''<your-instance-id>'''
--   \i sql/08_explain_live.sql
--
-- Or run directly:
--   SELECT df.explain('<instance-id>');

-- Show running instances so you can pick one
SELECT * FROM df.list_instances('Running') LIMIT 5;

-- Uncomment with your instance ID:
-- SELECT df.explain('<instance-id>');
