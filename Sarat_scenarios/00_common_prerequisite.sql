-- =============================================================================
-- COMMON PREREQUISITE – IDENTIFY AUTOVACUUM BLOCKERS
-- =============================================================================
-- Before taking any manual vacuum action, always identify the oldest xmin
-- holder, as it can prevent vacuum, freeze, and catalog cleanup.
--
-- Run this query FIRST before any of the other scenarios.
-- =============================================================================

WITH xmins AS (
    SELECT
        'pg_stat_activity' AS source,
        backend_xid AS xmin,
        age(backend_xid) AS xmin_age,
        format('pid=%s, db=%s, app=%s, user=%s, query=%s',
               pid, datname, application_name, usename, query) AS details
    FROM pg_stat_activity
    WHERE backend_xid IS NOT NULL

    UNION ALL

    SELECT
        'pg_replication_slots (catalog_xmin)',
        catalog_xmin,
        age(catalog_xmin),
        format('slot=%s, type=%s, active=%s, plugin=%s',
               slot_name, slot_type, active, plugin)
    FROM pg_replication_slots
    WHERE catalog_xmin IS NOT NULL

    UNION ALL

    SELECT
        'pg_replication_slots (xmin)',
        xmin,
        age(xmin),
        format('slot=%s, type=%s, active=%s',
               slot_name, slot_type, active)
    FROM pg_replication_slots
    WHERE xmin IS NOT NULL

    UNION ALL

    SELECT
        'pg_prepared_xacts',
        transaction::xid,
        age(transaction::xid),
        format('gid=%s, db=%s, owner=%s',
               gid, database, owner)
    FROM pg_prepared_xacts
    WHERE transaction IS NOT NULL

    UNION ALL

    SELECT
        'pg_stat_replication',
        backend_xmin,
        age(backend_xmin),
        format('pid=%s, app=%s',
               pid, application_name)
    FROM pg_stat_replication
    WHERE backend_xmin IS NOT NULL
)
SELECT
    source,
    xmin::text,
    xmin_age,
    details
FROM xmins
ORDER BY xmin_age DESC
LIMIT 1;

-- =============================================================================
-- INTERPRETATION GUIDE
-- =============================================================================
--
-- Source                                | What it means                                | Next steps
-- -------------------------------------|----------------------------------------------|-------------------------------------------
-- pg_stat_activity                     | A backend transaction is holding an old xmin | Terminate session if safe; review long-running transactions
-- pg_replication_slots (catalog_xmin)  | Logical replication slot blocking cleanup     | Drop unused slot or fix consumer lag
-- pg_replication_slots (xmin)          | Physical standby lagging/stuck               | Check replication health; redeploy if broken
-- pg_prepared_xacts                    | Orphaned two-phase commit transaction        | COMMIT or ROLLBACK the prepared transaction
-- pg_stat_replication                  | Streaming replica holding old xmin           | Check replica lag and health
-- =============================================================================
