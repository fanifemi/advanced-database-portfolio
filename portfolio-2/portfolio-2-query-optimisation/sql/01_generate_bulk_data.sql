-- =====================================================================
-- Portfolio 2 — File 01_generate_bulk_data.sql
-- Adds a realistic, skewed data volume on top of the Portfolio 1 schema:
--   100,000 customers · ~115,000 accounts · 100,000 beneficiaries
--   ~1,070,000 transactions · ~2,400,000 ledger lines (12 months)
-- Prerequisite: Portfolio 1 scripts 01–04 have been run.
-- Runtime: ~1–3 minutes on a laptop.
--
-- Bulk-load technique:
--   * Secondary indexes are dropped before loading and rebuilt later
--     (02_optimise.sql) — much faster than maintaining them row by row.
--   * Row-level triggers are switched off with session_replication_role
--     because every row is generated already-valid (balanced double entry,
--     non-negative running balances). Integrity is re-verified at the end.
--   * setseed() makes the data identical on every run (reproducible results).
-- =====================================================================
SET search_path TO payhaven;
SET TimeZone = 'Africa/Lagos';          -- makes date boundaries identical on any server
SELECT setseed(0.8103);

-- Start from the "baseline": only indexes that back PK/UNIQUE constraints.
DROP INDEX IF EXISTS ix_accounts_customer, ix_txn_initiated_by, ix_ledger_txn, ix_ledger_account;

BEGIN;
SET LOCAL session_replication_role = replica;   -- disables triggers for this transaction only
SET LOCAL work_mem = '256MB';

-- ---------------------------------------------------------------------
-- 1. Customers: tiers assigned by position so that a small group of
--    high-tier customers generates most of the activity (realistic skew).
--    customer n:  1–20,000 = Tier 3 · 20,001–50,000 = Tier 2 · rest = Tier 1
-- ---------------------------------------------------------------------
CREATE TEMP TABLE first_names(i int, name text);
INSERT INTO first_names SELECT row_number() OVER (), x FROM unnest(ARRAY[
 'Adaeze','Tunde','Fatima','Chinedu','Ngozi','Ibrahim','Bisi','Emeka','Halima','Kemi','Obinna','Aisha',
 'Segun','Chioma','Musa','Funke','Ikenna','Zainab','Yusuf','Amaka','Dayo','Nkechi','Sani','Temitope',
 'Uche','Hauwa','Femi','Ifeoma','Bello','Ronke','Kelechi','Maryam','Tobi','Ebere','Abdul','Yetunde']) x;
CREATE TEMP TABLE last_names(i int, name text);
INSERT INTO last_names SELECT row_number() OVER (), x FROM unnest(ARRAY[
 'Okafor','Bakare','Bello','Eze','Adeyemi','Musa','Ogunleye','Nwosu','Abubakar','Adebayo','Okonkwo',
 'Balogun','Ibrahim','Olawale','Danjuma','Nnamdi','Usman','Afolabi','Chukwu','Lawal','Obi','Yakubu',
 'Ogundipe','Ekwueme','Garba','Oyelaran','Ude','Shehu','Akinola','Mohammed']) x;

INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, status, created_at)
SELECT '23' || lpad(n::text, 9, '0'),
       f.name, l.name,
       lower(f.name || '.' || l.name || n || '@mail.example'),
       '+23481' || lpad(n::text, 8, '0'),
       DATE '1960-01-01' + (random() * 15000)::int,                 -- born 1960–2001
       CASE WHEN n <= 20000 THEN 3 WHEN n <= 50000 THEN 2 ELSE 1 END,
       CASE WHEN n % 97 = 0 THEN 'SUSPENDED' ELSE 'ACTIVE' END,
       TIMESTAMPTZ '2025-01-01' + random() * INTERVAL '170 days'
FROM generate_series(1, 100000) n
JOIN first_names f ON f.i = 1 + (n % 36)
JOIN last_names  l ON l.i = 1 + ((n / 36) % 30);

-- Map generated n -> customer_id (identity values continue after the seed rows)
CREATE TEMP TABLE cust_map AS
SELECT customer_id, substr(bvn, 3)::int AS n, kyc_tier, created_at
FROM customers WHERE bvn LIKE '23%';
CREATE INDEX ON cust_map (n);
ANALYZE cust_map;

-- ---------------------------------------------------------------------
-- 2. Accounts: one wallet per customer + savings vault for ~30% of tier 2/3
-- ---------------------------------------------------------------------
INSERT INTO accounts (account_number, customer_id, product_code, account_name, opened_at, status)
SELECT '2' || lpad(c.n::text, 9, '0'), c.customer_id,
       'PH_TIER' || c.kyc_tier,
       'WALLET ' || c.n,
       c.created_at + INTERVAL '1 hour',
       CASE WHEN c.n % 97 = 0 THEN 'FROZEN' ELSE 'ACTIVE' END
FROM cust_map c;

INSERT INTO accounts (account_number, customer_id, product_code, account_name, opened_at)
SELECT '3' || lpad(c.n::text, 9, '0'), c.customer_id, 'PH_SAVE', 'VAULT ' || c.n,
       c.created_at + INTERVAL '2 days'
FROM cust_map c
WHERE c.kyc_tier >= 2 AND c.n % 10 < 3;

-- Active accounts eligible to transact, indexed 1..N with high tiers first.
CREATE TEMP TABLE acct_idx AS
SELECT row_number() OVER (ORDER BY c.n, a.account_number) AS idx,
       a.account_id, c.customer_id, c.kyc_tier,
       CASE c.kyc_tier WHEN 3 THEN 2000000 WHEN 2 THEN 40000 ELSE 20000 END AS max_amt
FROM accounts a JOIN cust_map c ON c.customer_id = a.customer_id
WHERE a.status = 'ACTIVE' AND a.product_code <> 'PH_SAVE';
CREATE UNIQUE INDEX ON acct_idx (idx);
ANALYZE acct_idx;
CREATE TEMP TABLE acct_count AS SELECT count(*)::int AS n FROM acct_idx;

-- ---------------------------------------------------------------------
-- 3. One saved beneficiary per customer (needed for external transfers)
-- ---------------------------------------------------------------------
INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name)
SELECT c.customer_id,
       (ARRAY['044','058','011','033','057'])[1 + (c.n % 5)],
       lpad((c.n * 7919 % 1000000000)::text, 10, '0'),
       'PAYEE OF ' || c.n
FROM cust_map c;

-- ---------------------------------------------------------------------
-- 4. Staging: 1,000,000 transactions over 2025-07-01 .. 2026-06-30
--    Sender chosen with idx = 1 + floor(N * random()^3)  -> heavy skew
-- ---------------------------------------------------------------------
CREATE TEMP TABLE stg_txn AS
WITH g AS (
    SELECT n,
           random() AS r_type,
           1 + floor((SELECT n FROM acct_count) * power(random(), 3))::int AS s_idx,
           1 + floor((SELECT n FROM acct_count) * random())::int            AS r_idx,
           random() AS r_amt, random() AS r_chan,
           TIMESTAMPTZ '2025-07-01' + random() * INTERVAL '364 days 23 hours' AS ts
    FROM generate_series(1, 1000000) n
)
SELECT g.n,
       CASE WHEN g.r_type < 0.30 THEN 'DEPOSIT'
            WHEN g.r_type < 0.65 THEN 'INTERNAL_TRANSFER'
            WHEN g.r_type < 0.92 THEN 'EXTERNAL_TRANSFER'
            ELSE 'WITHDRAWAL' END                                 AS txn_type,
       s.account_id AS sender_acct, s.customer_id AS sender_cust,
       CASE WHEN r.account_id = s.account_id THEN NULL ELSE r.account_id END AS receiver_acct,
       -- log-uniform amount between N100 and the smaller of sender/receiver caps
       round((100 * exp(g.r_amt * ln(least(s.max_amt, CASE WHEN g.r_type >= 0.30 AND g.r_type < 0.65
                                                            THEN r.max_amt ELSE s.max_amt END) / 100.0)))::numeric, 2) AS amount,
       CASE WHEN g.r_chan < 0.65 THEN 'MOBILE' WHEN g.r_chan < 0.80 THEN 'WEB'
            WHEN g.r_chan < 0.95 THEN 'USSD' ELSE 'API' END       AS channel,
       g.ts AS created_at
FROM g
JOIN acct_idx s ON s.idx = g.s_idx
JOIN acct_idx r ON r.idx = g.r_idx;

-- self-transfers (sender = receiver) become deposits
ANALYZE stg_txn;
UPDATE stg_txn SET txn_type = 'DEPOSIT' WHERE txn_type = 'INTERNAL_TRANSFER' AND receiver_acct IS NULL;

ALTER TABLE stg_txn ADD COLUMN fee NUMERIC(18,2) NOT NULL DEFAULT 0,
                    ADD COLUMN status TEXT NOT NULL DEFAULT 'SUCCESSFUL';
UPDATE stg_txn SET fee = CASE WHEN amount <= 5000 THEN 10.75 WHEN amount <= 50000 THEN 26.88 ELSE 53.75 END
WHERE txn_type = 'EXTERNAL_TRANSFER';
-- ~2% of external transfers fail at NIP; the last 300 transactions are still PENDING
UPDATE stg_txn SET status = 'FAILED'  WHERE txn_type = 'EXTERNAL_TRANSFER' AND n % 50 = 0;
UPDATE stg_txn SET status = 'PENDING', created_at = TIMESTAMPTZ '2026-06-30 23:00' + (n % 3600) * INTERVAL '1 second'
WHERE n > 999700;

-- ---------------------------------------------------------------------
-- 5. Staging ledger lines (only SUCCESSFUL transactions move money)
--    GL accounts: 9000000001 settlement, 9000000002 fees, 9000000003 funding
-- ---------------------------------------------------------------------
CREATE TEMP TABLE gl AS
SELECT max(account_id) FILTER (WHERE account_number='9000000001') AS settle,
       max(account_id) FILTER (WHERE account_number='9000000002') AS fees,
       max(account_id) FILTER (WHERE account_number='9000000003') AS funding
FROM accounts;

CREATE TEMP TABLE stg_lines (n int, account_id bigint, direction text, amount numeric(18,2), created_at timestamptz, seq int);

INSERT INTO stg_lines
SELECT t.n, x.account_id, x.direction, x.amount, t.created_at, x.seq
FROM stg_txn t CROSS JOIN gl
CROSS JOIN LATERAL (VALUES
    -- DEPOSIT: funding DR, customer CR
    (CASE WHEN t.txn_type='DEPOSIT' THEN gl.funding END,             'DEBIT',  t.amount, 1),
    (CASE WHEN t.txn_type='DEPOSIT' THEN t.sender_acct END,           'CREDIT', t.amount, 2),
    -- INTERNAL: sender DR, receiver CR
    (CASE WHEN t.txn_type='INTERNAL_TRANSFER' THEN t.sender_acct END,   'DEBIT',  t.amount, 1),
    (CASE WHEN t.txn_type='INTERNAL_TRANSFER' THEN t.receiver_acct END, 'CREDIT', t.amount, 2),
    -- EXTERNAL: sender DR amount+fee, settlement CR amount, fees CR fee
    (CASE WHEN t.txn_type='EXTERNAL_TRANSFER' THEN t.sender_acct END,   'DEBIT',  t.amount + t.fee, 1),
    (CASE WHEN t.txn_type='EXTERNAL_TRANSFER' THEN gl.settle END,       'CREDIT', t.amount, 2),
    (CASE WHEN t.txn_type='EXTERNAL_TRANSFER' THEN gl.fees END,         'CREDIT', t.fee, 3),
    -- WITHDRAWAL: sender DR, settlement CR
    (CASE WHEN t.txn_type='WITHDRAWAL' THEN t.sender_acct END,          'DEBIT',  t.amount, 1),
    (CASE WHEN t.txn_type='WITHDRAWAL' THEN gl.settle END,              'CREDIT', t.amount, 2)
) AS x(account_id, direction, amount, seq)
WHERE t.status = 'SUCCESSFUL' AND x.account_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 6. Opening deposits so no customer running balance ever goes below 0
-- ---------------------------------------------------------------------
ANALYZE stg_lines;
CREATE TEMP TABLE deficits AS
WITH running AS (
    SELECT l.account_id,
           sum(CASE l.direction WHEN 'CREDIT' THEN l.amount ELSE -l.amount END)
               OVER (PARTITION BY l.account_id ORDER BY l.created_at, l.n, l.seq) AS bal
    FROM stg_lines l
    JOIN accounts a ON a.account_id = l.account_id AND a.account_category = 'CUSTOMER'
)
SELECT account_id, ceil(-min(bal) / 1000) * 1000 + 1000 AS topup
FROM running GROUP BY account_id HAVING min(bal) < 0;

INSERT INTO stg_txn (n, txn_type, sender_acct, sender_cust, receiver_acct, amount, channel, created_at)
SELECT 1000000 + row_number() OVER (ORDER BY d.account_id), 'DEPOSIT', d.account_id, a.customer_id, NULL,
       d.topup, 'WEB', TIMESTAMPTZ '2025-06-30 12:00'
FROM deficits d JOIN accounts a USING (account_id);

INSERT INTO stg_lines
SELECT t.n, x.account_id, x.direction, t.amount, t.created_at, x.seq
FROM stg_txn t CROSS JOIN gl
CROSS JOIN LATERAL (VALUES (gl.funding, 'DEBIT', 1), (t.sender_acct, 'CREDIT', 2)) AS x(account_id, direction, seq)
WHERE t.n > 1000000;

-- ---------------------------------------------------------------------
-- 7. Load transactions in time order (helps BRIN later), then ledger
-- ---------------------------------------------------------------------
INSERT INTO transactions (reference, transaction_type, status, amount, fee, channel, narration,
                          initiated_by, created_at, completed_at)
SELECT 'PH-B-' || lpad(n::text, 8, '0'), txn_type, status, amount, fee, channel,
       lower(replace(txn_type, '_', ' ')), sender_cust, created_at,
       CASE WHEN status = 'PENDING' THEN NULL ELSE created_at END
FROM stg_txn ORDER BY stg_txn.created_at, stg_txn.n;

CREATE TEMP TABLE txn_map AS
SELECT transaction_id, substr(reference, 6)::int AS n
FROM transactions WHERE reference LIKE 'PH-B-%';
CREATE INDEX ON txn_map (n);
ANALYZE txn_map; ANALYZE stg_txn; ANALYZE stg_lines;

INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after, created_at)
SELECT m.transaction_id, l.account_id, l.direction, l.amount,
       a.balance + sum(CASE l.direction WHEN 'CREDIT' THEN l.amount ELSE -l.amount END)
           OVER (PARTITION BY l.account_id ORDER BY l.created_at, l.n, l.seq),
       l.created_at
FROM stg_lines l
JOIN txn_map  m ON m.n = l.n
JOIN accounts a ON a.account_id = l.account_id       -- a.balance = pre-existing (seed) balance
ORDER BY l.created_at, l.n, l.seq;

INSERT INTO external_transfers (transaction_id, beneficiary_id, nip_session_id, response_code)
SELECT m.transaction_id, b.beneficiary_id,
       CASE WHEN t.status = 'SUCCESSFUL' THEN '999' || lpad(t.n::text, 21, '0') END,
       CASE t.status WHEN 'SUCCESSFUL' THEN '00' WHEN 'FAILED' THEN '91' END
FROM stg_txn t
JOIN txn_map m ON m.n = t.n
JOIN beneficiaries b ON b.customer_id = t.sender_cust
WHERE t.txn_type = 'EXTERNAL_TRANSFER';

-- ---------------------------------------------------------------------
-- 8. Stored balances = previous balance + net ledger movement
-- ---------------------------------------------------------------------
UPDATE accounts a
SET balance = a.balance + d.net, version = a.version + d.cnt
FROM (SELECT account_id,
             sum(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END) AS net,
             count(*) AS cnt
      FROM stg_lines GROUP BY account_id) d
WHERE d.account_id = a.account_id;

COMMIT;

-- ---------------------------------------------------------------------
-- 9. Verify integrity of everything that was loaded with triggers off
-- ---------------------------------------------------------------------
\echo '--- Integrity checks (all "violations" columns must be 0) ---'
SELECT
  (SELECT count(*) FROM (SELECT transaction_id FROM ledger_entries GROUP BY transaction_id
                         HAVING sum(amount) FILTER (WHERE direction='DEBIT')
                             <> sum(amount) FILTER (WHERE direction='CREDIT')) x) AS unbalanced_txn_violations,
  (SELECT count(*) FROM v_balance_reconciliation WHERE difference <> 0)          AS reconciliation_violations,
  (SELECT count(*) FROM ledger_entries le JOIN accounts a USING (account_id)
    WHERE a.account_category='CUSTOMER' AND le.balance_after < 0)              AS negative_running_balance_violations,
  (SELECT count(*) FROM accounts a JOIN account_products p USING (product_code)
    WHERE p.max_balance IS NOT NULL AND a.balance > p.max_balance)             AS max_balance_violations;

\echo '--- Volumes ---'
SELECT 'customers' AS table_name, count(*) FROM customers
UNION ALL SELECT 'accounts', count(*) FROM accounts
UNION ALL SELECT 'beneficiaries', count(*) FROM beneficiaries
UNION ALL SELECT 'transactions', count(*) FROM transactions
UNION ALL SELECT 'ledger_entries', count(*) FROM ledger_entries
UNION ALL SELECT 'external_transfers', count(*) FROM external_transfers;

VACUUM (ANALYZE) customers, accounts, beneficiaries, transactions, ledger_entries, external_transfers;
