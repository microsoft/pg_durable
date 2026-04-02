-- Monitor the invoice approval pipeline.
-- Run this repeatedly to observe progress.

\pset pager off

\echo '\n=== INVOICES ==='
SELECT id, description, left(raw_amount, 12) AS raw_amount,
       status, vendor, category, amount, approved_by
FROM demo.invoices
ORDER BY id;

\echo '\n=== AUDIT TRAIL ==='
SELECT a.id, a.invoice_id, a.action,
       a.details::text AS details,
       to_char(a.created_at, 'HH24:MI:SS') AS at
FROM demo.invoice_audit a
ORDER BY a.id;
