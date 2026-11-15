-- =====================================================================
-- File: 03_views.sql — read models over the normalised schema
-- =====================================================================
SET search_path TO payhaven;

-- Reconciliation: the stored (denormalised) balance must equal the balance
-- derived from the ledger. Any row returned here is a data-integrity incident.
CREATE OR REPLACE VIEW v_balance_reconciliation AS
SELECT a.account_id,
       a.account_number,
       a.account_category,
       a.balance AS stored_balance,
       COALESCE(SUM(CASE le.direction WHEN 'CREDIT' THEN le.amount ELSE -le.amount END), 0)
           AS ledger_balance,
       a.balance - COALESCE(SUM(CASE le.direction WHEN 'CREDIT' THEN le.amount ELSE -le.amount END), 0)
           AS difference
FROM accounts a
LEFT JOIN ledger_entries le ON le.account_id = a.account_id
GROUP BY a.account_id;

-- Customer 360: one row per customer account.
CREATE OR REPLACE VIEW v_customer_accounts AS
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS customer_name,
       c.kyc_tier,
       c.status          AS customer_status,
       a.account_number,
       p.product_name,
       a.currency,
       a.balance,
       a.status          AS account_status,
       p.daily_debit_limit
FROM customers c
JOIN accounts a          ON a.customer_id = c.customer_id
JOIN account_products p  ON p.product_code = a.product_code;

-- Account statement: ledger lines with transaction context.
CREATE OR REPLACE VIEW v_account_statement AS
SELECT a.account_number,
       t.reference,
       t.transaction_type,
       t.status,
       le.direction,
       le.amount,
       le.balance_after,
       t.narration,
       le.created_at
FROM ledger_entries le
JOIN accounts a     ON a.account_id = le.account_id
JOIN transactions t ON t.transaction_id = le.transaction_id;
