-- =====================================================================
-- Portfolio 2 — 00_reset_baseline.sql
-- Returns the database to the "baseline" physical design: only the
-- indexes that back PRIMARY KEY / UNIQUE constraints. Data is untouched.
-- =====================================================================
SET search_path TO payhaven;

DROP MATERIALIZED VIEW IF EXISTS mv_monthly_volume;
DROP INDEX IF EXISTS
    ix_ledger_account_time, ix_ledger_txn, ix_ledger_account,
    ix_accounts_customer, ix_txn_initiated_by, ix_txn_open_items,
    brin_txn_created, ix_customers_phone_trgm;

VACUUM (ANALYZE) customers, accounts, transactions, ledger_entries;
