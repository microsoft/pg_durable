-- Final verification: show all invoices and their audit trail.

SELECT '=== INVOICES ===' AS section;
SELECT id, description, raw_amount, status, vendor, category,
       amount, approved_by,
       to_char(processed_at, 'HH24:MI:SS') AS processed_at
FROM demo.invoices
ORDER BY id;

SELECT '=== AUDIT TRAIL ===' AS section;
SELECT a.invoice_id, a.action, a.details::text,
       to_char(a.created_at, 'HH24:MI:SS') AS at
FROM demo.invoice_audit a
ORDER BY a.id;

SELECT '=== PIPELINE STATUS ===' AS section;
SELECT * FROM df.list_instances() LIMIT 10;
