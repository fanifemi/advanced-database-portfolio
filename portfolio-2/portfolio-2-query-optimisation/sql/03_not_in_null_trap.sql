-- =====================================================================
-- Portfolio 2 — 03_not_in_null_trap.sql
-- Why Q9 must use NOT EXISTS: NOT IN returns NO rows if the subquery
-- yields even one NULL. transactions.initiated_by is NULL for
-- system-initiated rows (e.g. the reversal PH-REV-0001 on 2026-03-08).
-- A one-day window keeps the subquery small enough to finish quickly.
-- =====================================================================
SET search_path TO payhaven;
SET TimeZone = 'Africa/Lagos';

\echo '--- NULLs in the subquery for 2026-03-08 ---'
SELECT count(*) FILTER (WHERE initiated_by IS NULL) AS null_initiators, count(*) AS rows_in_window
FROM transactions WHERE created_at >= '2026-03-08' AND created_at < '2026-03-09';

\echo '--- NOT IN: customers who did NOT transact on 2026-03-08 ---'
SELECT count(*) AS not_in_result
FROM customers c
WHERE c.customer_id NOT IN (SELECT initiated_by FROM transactions
                            WHERE created_at >= '2026-03-08' AND created_at < '2026-03-09');

\echo '--- NOT EXISTS: same question ---'
SELECT count(*) AS not_exists_result
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM transactions t
                  WHERE t.initiated_by = c.customer_id
                    AND t.created_at >= '2026-03-08' AND t.created_at < '2026-03-09');

\echo '--- Why: x NOT IN (1, 2, NULL) is NULL (unknown), never TRUE ---'
SELECT 5 NOT IN (1, 2)       AS without_null,
       5 NOT IN (1, 2, NULL) AS with_null;
