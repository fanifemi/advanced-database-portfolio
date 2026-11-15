-- =====================================================================
-- Portfolio 2 — 02_optimise.sql
-- Physical-design changes, each justified by a query in queries.sql.
-- =====================================================================
SET search_path TO payhaven;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Q1, Q2, Q3: statements, pagination and the daily-limit check all filter on
-- one account and order/range on time. Composite B-tree in that column order;
-- INCLUDE makes Q3 answerable from the index alone (index-only scan).
CREATE INDEX ix_ledger_account_time
    ON ledger_entries (account_id, created_at, entry_id) INCLUDE (direction, amount);

-- Join support: ledger -> transactions (also used by the double-entry trigger R4),
-- accounts -> customers, transactions -> customers.
CREATE INDEX ix_ledger_txn        ON ledger_entries (transaction_id);
CREATE INDEX ix_accounts_customer ON accounts (customer_id);
CREATE INDEX ix_txn_initiated_by  ON transactions (initiated_by, created_at);

-- Q5: support agents search by the last digits of a phone number
-- (LIKE '%…'). A normal B-tree cannot serve a leading wildcard; a trigram GIN can.
CREATE INDEX ix_customers_phone_trgm ON customers USING gin (phone gin_trgm_ops);

-- Q6: support dashboard only ever looks at PENDING/FAILED items (~0.5% of rows).
-- A partial index stores just those rows, so it stays tiny.
CREATE INDEX ix_txn_open_items ON transactions (created_at)
    WHERE status IN ('PENDING', 'FAILED');

-- Q7, Q8: reporting over date ranges. Rows are inserted in time order, so
-- created_at is physically correlated with the table — ideal for BRIN, which
-- stores only min/max per block range (kilobytes instead of tens of MB).
CREATE INDEX brin_txn_created ON transactions USING brin (created_at) WITH (pages_per_range = 32);

-- Q7 (variant): pre-aggregated monthly figures for dashboards.
CREATE MATERIALIZED VIEW mv_monthly_volume AS
SELECT date_trunc('month', created_at) AS month,
       transaction_type, channel,
       count(*)              AS txn_count,
       sum(amount)           AS total_amount,
       sum(fee)              AS total_fees
FROM transactions
WHERE status = 'SUCCESSFUL'
GROUP BY 1, 2, 3;
CREATE UNIQUE INDEX ux_mv_monthly_volume ON mv_monthly_volume (month, transaction_type, channel);
-- refresh nightly without blocking readers:
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_monthly_volume;

-- Fresh statistics + visibility map (needed for index-only scans)
VACUUM (ANALYZE) customers, accounts, transactions, ledger_entries;
