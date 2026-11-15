-- =====================================================================
-- Portfolio 3 — 02_atomicity_demo.sql   (run with psql; output = evidence)
-- Part A  COMMIT        — a successful transfer is durable and balanced
-- Part B  ROLLBACK      — a failure part-way through leaves NO trace
-- Part C  Explicit ROLLBACK by the application
-- Part D  SAVEPOINTs    — a payroll batch where one payment fails
-- Part E  Idempotent retry and reversal
-- =====================================================================
SET search_path TO payhaven;
\set ON_ERROR_STOP 0
\pset footer off

SELECT lab_new_account('24000000001', 'PH_TIER3', 100000) AS a \gset
SELECT lab_new_account('24000000002', 'PH_TIER3', 0)      AS b \gset
\echo
\echo Accounts for this demo: :a (opened with N100,000) and :b (empty)

CREATE TEMP VIEW demo_balances AS
SELECT account_number, balance, version FROM accounts
WHERE account_number IN (:'a', :'b') ORDER BY account_number;

-- ---------------------------------------------------------------- A
\echo
\echo ===== A. COMMIT: transfer N30,000 from :a to :b =====
BEGIN;
SELECT transfer('DEMO-A-' || :'a', :'a', :'b', 30000, 'MOBILE', 'Part A');
COMMIT;
SELECT * FROM demo_balances;
SELECT t.reference, t.status, le.direction, le.amount, le.balance_after
FROM transactions t JOIN ledger_entries le USING (transaction_id)
WHERE t.reference = 'DEMO-A-' || :'a' ORDER BY le.entry_id;

-- ---------------------------------------------------------------- B
\echo
\echo ===== B. Automatic ROLLBACK: N500,000 transfer fails (insufficient funds) =====
\echo The transaction header row is inserted BEFORE the balance check fails.
\echo Afterwards it must not exist, and no balance may have changed.
BEGIN;
SELECT transfer('DEMO-B-' || :'a', :'a', :'b', 500000, 'MOBILE', 'Part B');
ROLLBACK;
SELECT * FROM demo_balances;
SELECT count(*) AS header_rows_left_behind FROM transactions WHERE reference = 'DEMO-B-' || :'a';

-- ---------------------------------------------------------------- C
\echo
\echo ===== C. Explicit ROLLBACK: the transfer succeeds, then the app cancels =====
BEGIN;
SELECT transfer('DEMO-C-' || :'a', :'a', :'b', 10000, 'MOBILE', 'Part C');
\echo Inside the transaction (uncommitted):
SELECT * FROM demo_balances;
ROLLBACK;
\echo After ROLLBACK:
SELECT * FROM demo_balances;

-- ---------------------------------------------------------------- D
\echo
\echo ===== D. SAVEPOINTs: pay 4 staff from :a; staff #3 has a FROZEN account =====
SELECT lab_new_account('24000000002', 'PH_TIER3', 0) AS s1 \gset
SELECT lab_new_account('24000000002', 'PH_TIER3', 0) AS s2 \gset
SELECT lab_new_account('24000000002', 'PH_TIER3', 0) AS s3 \gset
SELECT lab_new_account('24000000002', 'PH_TIER3', 0) AS s4 \gset
UPDATE accounts SET status = 'FROZEN' WHERE account_number = :'s3';

BEGIN;
SAVEPOINT pay1;
SELECT transfer('DEMO-D1-' || :'s1', :'a', :'s1', 5000, 'API', 'Salary');
RELEASE SAVEPOINT pay1;
SAVEPOINT pay2;
SELECT transfer('DEMO-D2-' || :'s2', :'a', :'s2', 5000, 'API', 'Salary');
RELEASE SAVEPOINT pay2;
SAVEPOINT pay3;
SELECT transfer('DEMO-D3-' || :'s3', :'a', :'s3', 5000, 'API', 'Salary');   -- fails: frozen
ROLLBACK TO SAVEPOINT pay3;                                                  -- undo only #3
SAVEPOINT pay4;
SELECT transfer('DEMO-D4-' || :'s4', :'a', :'s4', 5000, 'API', 'Salary');
RELEASE SAVEPOINT pay4;
COMMIT;
\echo Payroll result: 3 paid, 1 skipped, batch committed
SELECT account_number, status, balance FROM accounts
WHERE account_number IN (:'a', :'s1', :'s2', :'s3', :'s4') ORDER BY account_number;

-- ---------------------------------------------------------------- E
\echo
\echo ===== E. Idempotent retry, then reversal =====
\echo The client times out and retries the same request (same reference) twice:
SELECT transfer('DEMO-E-' || :'a', :'a', :'b', 2000, 'MOBILE', 'Part E') AS txn_id_attempt_1;
SELECT transfer('DEMO-E-' || :'a', :'a', :'b', 2000, 'MOBILE', 'Part E') AS txn_id_attempt_2;
SELECT transfer('DEMO-E-' || :'a', :'a', :'b', 2000, 'MOBILE', 'Part E') AS txn_id_attempt_3;
SELECT count(*) AS debits_for_reference FROM ledger_entries le JOIN transactions t USING (transaction_id)
WHERE t.reference = 'DEMO-E-' || :'a' AND le.direction = 'DEBIT';
\echo Reverse it (refund), then try to reverse it a second time:
SELECT reverse_transaction('DEMO-E-' || :'a', 'Customer dispute upheld') AS reversal_txn_id;
SELECT reverse_transaction('DEMO-E-' || :'a', 'Duplicate reversal attempt');
SELECT reference, transaction_type, status, amount FROM transactions
WHERE reference LIKE 'DEMO-E-' || :'a' || '%' ORDER BY transaction_id;
SELECT * FROM demo_balances;

\echo
\echo ===== Integrity after all parts: stored balance = ledger balance =====
SELECT account_number, stored_balance, ledger_balance, difference
FROM v_balance_reconciliation WHERE account_number IN (:'a', :'b', :'s1', :'s2', :'s3', :'s4')
ORDER BY account_number;
