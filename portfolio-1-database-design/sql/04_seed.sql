-- =====================================================================
-- File: 04_seed.sql — small, realistic sample data for PayHaven
-- All people, BVNs, phone numbers and documents are FICTIONAL.
-- Bulk data for performance testing is generated in Portfolio 2.
-- =====================================================================
SET search_path TO payhaven;

BEGIN;

-- ---------------- Reference data ----------------
INSERT INTO banks (bank_code, bank_name) VALUES
    ('044', 'Access Bank'),
    ('058', 'Guaranty Trust Bank'),
    ('011', 'First Bank of Nigeria'),
    ('033', 'United Bank for Africa'),
    ('057', 'Zenith Bank'),
    ('999', 'PayHaven Microfinance Bank');   -- our own (simulated) bank code

-- Limits modelled on CBN tiered-KYC rules (daily debit / maximum balance).
INSERT INTO account_products (product_code, product_name, min_kyc_tier, daily_debit_limit, max_balance, interest_rate_pa) VALUES
    ('PH_TIER1', 'Starter Wallet',       1,    50000.00,  300000.00,  0.00),
    ('PH_TIER2', 'Standard Wallet',      2,   200000.00,  500000.00,  0.00),
    ('PH_TIER3', 'Premium Wallet',       3,  5000000.00,       NULL,  0.00),
    ('PH_SAVE',  'Target Savings Vault', 2,   100000.00,       NULL, 12.00);

INSERT INTO staff (staff_number, full_name, email, role) VALUES
    ('PH-0001', 'Kemi Adebayo',    'kemi.adebayo@payhaven.example',  'KYC_OFFICER'),
    ('PH-0002', 'Emeka Nwosu',     'emeka.nwosu@payhaven.example',   'COMPLIANCE'),
    ('PH-0003', 'Halima Abubakar', 'halima.a@payhaven.example',      'SUPPORT');

-- ---------------- Customers ----------------
INSERT INTO customers (bvn, first_name, middle_name, last_name, email, phone, date_of_birth, kyc_tier, status, created_at) VALUES
    ('22100000001', 'Adaeze',  'Chioma', 'Okafor',  'adaeze.okafor@mail.example',  '+2348031000001', '1990-04-12', 3, 'ACTIVE',    '2026-01-05 09:12+01'),
    ('22100000002', 'Tunde',   NULL,     'Bakare',  'tunde.bakare@mail.example',   '+2348031000002', '1995-09-30', 2, 'ACTIVE',    '2026-01-18 14:40+01'),
    ('22100000003', 'Fatima',  'Zainab', 'Bello',   'fatima.bello@mail.example',   '+2348031000003', '2001-02-17', 1, 'ACTIVE',    '2026-02-02 11:05+01'),
    ('22100000004', 'Chinedu', NULL,     'Eze',     'chinedu.eze@mail.example',    '+2348031000004', '1987-11-03', 3, 'ACTIVE',    '2026-02-20 16:22+01'),
    ('22100000005', 'Ngozi',   NULL,     'Adeyemi', 'ngozi.adeyemi@mail.example',  '+2348031000005', '1999-06-21', 1, 'PENDING',   '2026-03-11 08:47+01'),
    ('22100000006', 'Ibrahim', 'Sani',   'Musa',    'ibrahim.musa@mail.example',   '+2348031000006', '1993-12-08', 2, 'SUSPENDED', '2026-03-25 19:30+01');

INSERT INTO customer_addresses (customer_id, address_type, line1, city, state) VALUES
    (1, 'RESIDENTIAL', '14 Admiralty Way, Lekki Phase 1', 'Lekki',       'Lagos'),
    (1, 'WORK',        '3 Idowu Taylor Street',           'Victoria Island', 'Lagos'),
    (2, 'RESIDENTIAL', '22 Ring Road',                    'Ibadan',      'Oyo'),
    (3, 'RESIDENTIAL', '7 Ahmadu Bello Way',              'Kaduna',      'Kaduna'),
    (4, 'RESIDENTIAL', '41 Ogui Road',                    'Enugu',       'Enugu'),
    (5, 'RESIDENTIAL', '9 Oke-Fia Street',                'Osogbo',      'Osun'),
    (6, 'RESIDENTIAL', '18 Zoo Road',                     'Kano',        'Kano');

INSERT INTO kyc_documents (customer_id, document_type, document_number, status, submitted_at, reviewed_by, reviewed_at, rejection_reason) VALUES
    (1, 'NIN',          '70000000001', 'VERIFIED',  '2026-01-05 09:20+01', 1, '2026-01-05 10:02+01', NULL),
    (1, 'UTILITY_BILL', 'IKEDC-558201','VERIFIED',  '2026-01-05 09:25+01', 1, '2026-01-05 10:05+01', NULL),
    (2, 'NIN',          '70000000002', 'VERIFIED',  '2026-01-18 14:45+01', 1, '2026-01-18 15:30+01', NULL),
    (3, 'NIN',          '70000000003', 'VERIFIED',  '2026-02-02 11:10+01', 1, '2026-02-02 12:00+01', NULL),
    (4, 'NIN',          '70000000004', 'VERIFIED',  '2026-02-20 16:30+01', 1, '2026-02-20 17:01+01', NULL),
    (4, 'PASSPORT',     'B01234567',   'VERIFIED',  '2026-02-20 16:31+01', 1, '2026-02-20 17:03+01', NULL),
    (5, 'VOTERS_CARD',  '90F5B1234567','REJECTED',  '2026-03-11 08:50+01', 1, '2026-03-11 09:40+01', 'Image blurred; name mismatch'),
    (5, 'NIN',          '70000000005', 'SUBMITTED', '2026-03-12 07:15+01', NULL, NULL, NULL),
    (6, 'NIN',          '70000000006', 'VERIFIED',  '2026-03-25 19:35+01', 1, '2026-03-26 09:00+01', NULL);

INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name, nickname) VALUES
    (1, '058', '0123456789', 'OBINNA OKAFOR',     'Brother'),
    (2, '044', '0698765432', 'BAKARE STORES LTD', 'Shop'),
    (4, '057', '2087654321', 'EZE AMARACHI',      'Mum');

-- ---------------- Accounts ----------------
INSERT INTO accounts (account_number, account_category, customer_id, product_code, account_name, opened_at) VALUES
    ('9000000001', 'SYSTEM', NULL, NULL, 'NIP Settlement (GL)',        '2026-01-01 00:00+01'),
    ('9000000002', 'SYSTEM', NULL, NULL, 'Fee Income (GL)',            '2026-01-01 00:00+01'),
    ('9000000003', 'SYSTEM', NULL, NULL, 'Funding Suspense (GL)',      '2026-01-01 00:00+01');

INSERT INTO accounts (account_number, customer_id, product_code, account_name, opened_at) VALUES
    ('1000000011', 1, 'PH_TIER3', 'ADAEZE CHIOMA OKAFOR', '2026-01-05 10:10+01'),
    ('1000000012', 1, 'PH_SAVE',  'ADAEZE OKAFOR - VAULT','2026-01-06 08:00+01'),
    ('1000000021', 2, 'PH_TIER2', 'TUNDE BAKARE',         '2026-01-18 15:35+01'),
    ('1000000031', 3, 'PH_TIER1', 'FATIMA ZAINAB BELLO',  '2026-02-02 12:05+01'),
    ('1000000041', 4, 'PH_TIER3', 'CHINEDU EZE',          '2026-02-20 17:10+01'),
    ('1000000051', 5, 'PH_TIER1', 'NGOZI ADEYEMI',        '2026-03-11 09:00+01'),
    ('1000000061', 6, 'PH_TIER2', 'IBRAHIM SANI MUSA',    '2026-03-26 09:10+01');

-- ---------------- Seed-only posting helper (temporary) ----------------
-- Posts one ledger line and updates the account balance.
-- The production-grade, concurrency-safe transfer procedure is built in Portfolio 3.
CREATE FUNCTION pg_temp.leg(p_ref TEXT, p_acct CHAR(10), p_dir TEXT, p_amt NUMERIC, p_at TIMESTAMPTZ)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_acct BIGINT; v_txn BIGINT; v_new NUMERIC(18,2);
BEGIN
    SELECT transaction_id INTO v_txn FROM payhaven.transactions WHERE reference = p_ref;
    UPDATE payhaven.accounts
       SET balance = balance + CASE p_dir WHEN 'CREDIT' THEN p_amt ELSE -p_amt END,
           version = version + 1
     WHERE account_number = p_acct
     RETURNING account_id, balance INTO v_acct, v_new;
    INSERT INTO payhaven.ledger_entries (transaction_id, account_id, direction, amount, balance_after, created_at)
    VALUES (v_txn, v_acct, p_dir, p_amt, v_new, p_at);
END $$;

-- ---------------- Transactions ----------------
INSERT INTO transactions (reference, transaction_type, status, amount, fee, channel, narration, initiated_by, created_at, completed_at) VALUES
    ('PH-DEP-0001', 'DEPOSIT',           'SUCCESSFUL', 1500000.00, 0,     'WEB',    'Wallet funding via card',      1, '2026-01-05 10:15+01', '2026-01-05 10:15+01'),
    ('PH-DEP-0002', 'DEPOSIT',           'SUCCESSFUL',  250000.00, 0,     'MOBILE', 'Wallet funding via transfer',  2, '2026-01-19 08:00+01', '2026-01-19 08:00+01'),
    ('PH-DEP-0003', 'DEPOSIT',           'SUCCESSFUL',   40000.00, 0,     'USSD',   'Wallet funding',               3, '2026-02-03 09:30+01', '2026-02-03 09:30+01'),
    ('PH-DEP-0004', 'DEPOSIT',           'SUCCESSFUL', 2000000.00, 0,     'WEB',    'Salary',                       4, '2026-02-28 12:00+01', '2026-02-28 12:00+01'),
    ('PH-DEP-0005', 'DEPOSIT',           'SUCCESSFUL',   80000.00, 0,     'MOBILE', 'Wallet funding',               6, '2026-03-27 10:00+01', '2026-03-27 10:00+01'),
    ('PH-INT-0001', 'INTERNAL_TRANSFER', 'SUCCESSFUL',  300000.00, 0,     'MOBILE', 'Move to savings vault',        1, '2026-03-01 07:45+01', '2026-03-01 07:45+01'),
    ('PH-INT-0002', 'INTERNAL_TRANSFER', 'SUCCESSFUL',   45000.00, 0,     'MOBILE', 'Rent contribution',            1, '2026-03-02 18:20+01', '2026-03-02 18:20+01'),
    ('PH-EXT-0001', 'EXTERNAL_TRANSFER', 'SUCCESSFUL',  120000.00, 53.75, 'MOBILE', 'Upkeep for Mum',               4, '2026-03-05 13:10+01', '2026-03-05 13:10+01'),
    ('PH-EXT-0002', 'EXTERNAL_TRANSFER', 'FAILED',       15000.00, 26.88, 'WEB',    'Stock purchase',               2, '2026-03-06 09:00+01', '2026-03-06 09:00+01'),
    ('PH-EXT-0003', 'EXTERNAL_TRANSFER', 'SUCCESSFUL',   60000.00, 53.75, 'MOBILE', 'School fees support',          1, '2026-03-08 15:00+01', '2026-03-08 15:00+01'),
    ('PH-WDL-0001', 'WITHDRAWAL',        'SUCCESSFUL',   10000.00, 0,     'USSD',   'Cash-out at agent',            3, '2026-03-09 17:40+01', '2026-03-09 17:40+01');

-- Deposits: Funding Suspense (DR) -> customer wallet (CR)
SELECT pg_temp.leg('PH-DEP-0001', '9000000003', 'DEBIT',  1500000.00, '2026-01-05 10:15+01');
SELECT pg_temp.leg('PH-DEP-0001', '1000000011', 'CREDIT', 1500000.00, '2026-01-05 10:15+01');
SELECT pg_temp.leg('PH-DEP-0002', '9000000003', 'DEBIT',   250000.00, '2026-01-19 08:00+01');
SELECT pg_temp.leg('PH-DEP-0002', '1000000021', 'CREDIT',  250000.00, '2026-01-19 08:00+01');
SELECT pg_temp.leg('PH-DEP-0003', '9000000003', 'DEBIT',    40000.00, '2026-02-03 09:30+01');
SELECT pg_temp.leg('PH-DEP-0003', '1000000031', 'CREDIT',   40000.00, '2026-02-03 09:30+01');
SELECT pg_temp.leg('PH-DEP-0004', '9000000003', 'DEBIT',  2000000.00, '2026-02-28 12:00+01');
SELECT pg_temp.leg('PH-DEP-0004', '1000000041', 'CREDIT', 2000000.00, '2026-02-28 12:00+01');
SELECT pg_temp.leg('PH-DEP-0005', '9000000003', 'DEBIT',    80000.00, '2026-03-27 10:00+01');
SELECT pg_temp.leg('PH-DEP-0005', '1000000061', 'CREDIT',   80000.00, '2026-03-27 10:00+01');

-- Internal transfers: sender (DR) -> receiver (CR)
SELECT pg_temp.leg('PH-INT-0001', '1000000011', 'DEBIT',   300000.00, '2026-03-01 07:45+01');
SELECT pg_temp.leg('PH-INT-0001', '1000000012', 'CREDIT',  300000.00, '2026-03-01 07:45+01');
SELECT pg_temp.leg('PH-INT-0002', '1000000011', 'DEBIT',    45000.00, '2026-03-02 18:20+01');
SELECT pg_temp.leg('PH-INT-0002', '1000000021', 'CREDIT',   45000.00, '2026-03-02 18:20+01');

-- External transfer: sender (DR amount+fee) -> NIP settlement (CR amount) + fee income (CR fee)
SELECT pg_temp.leg('PH-EXT-0001', '1000000041', 'DEBIT',   120053.75, '2026-03-05 13:10+01');
SELECT pg_temp.leg('PH-EXT-0001', '9000000001', 'CREDIT',  120000.00, '2026-03-05 13:10+01');
SELECT pg_temp.leg('PH-EXT-0001', '9000000002', 'CREDIT',      53.75, '2026-03-05 13:10+01');
-- PH-EXT-0002 FAILED at NIP name-enquiry: no money moved, so no ledger lines.
SELECT pg_temp.leg('PH-EXT-0003', '1000000011', 'DEBIT',    60053.75, '2026-03-08 15:00+01');
SELECT pg_temp.leg('PH-EXT-0003', '9000000001', 'CREDIT',   60000.00, '2026-03-08 15:00+01');
SELECT pg_temp.leg('PH-EXT-0003', '9000000002', 'CREDIT',      53.75, '2026-03-08 15:00+01');

-- Withdrawal: customer (DR) -> settlement (CR), paid out by agent
SELECT pg_temp.leg('PH-WDL-0001', '1000000031', 'DEBIT',    10000.00, '2026-03-09 17:40+01');
SELECT pg_temp.leg('PH-WDL-0001', '9000000001', 'CREDIT',   10000.00, '2026-03-09 17:40+01');

INSERT INTO external_transfers (transaction_id, beneficiary_id, nip_session_id, response_code)
SELECT t.transaction_id, b.beneficiary_id, s.session_id, s.code
FROM (VALUES ('PH-EXT-0001', 3, '999057260305131000000001', '00'),
             ('PH-EXT-0002', 2, NULL,                       '07'),
             ('PH-EXT-0003', 1, '999058260308150000000002', '91')) AS s(ref, benef, session_id, code)
JOIN transactions  t ON t.reference = s.ref
JOIN beneficiaries b ON b.beneficiary_id = s.benef;

-- PH-EXT-0003 timed out at the receiving bank (NIP '91'): reverse it, fee included.
INSERT INTO transactions (reference, transaction_type, status, amount, fee, channel, narration, reversal_of, created_at, completed_at)
SELECT 'PH-REV-0001', 'REVERSAL', 'SUCCESSFUL', 60053.75, 0, 'SYSTEM',
       'Reversal of PH-EXT-0003 (beneficiary bank timeout)', transaction_id,
       '2026-03-08 15:20+01', '2026-03-08 15:20+01'
FROM transactions WHERE reference = 'PH-EXT-0003';

SELECT pg_temp.leg('PH-REV-0001', '9000000001', 'DEBIT',    60000.00, '2026-03-08 15:20+01');
SELECT pg_temp.leg('PH-REV-0001', '9000000002', 'DEBIT',       53.75, '2026-03-08 15:20+01');
SELECT pg_temp.leg('PH-REV-0001', '1000000011', 'CREDIT',   60053.75, '2026-03-08 15:20+01');

UPDATE transactions SET status = 'REVERSED' WHERE reference = 'PH-EXT-0003';

-- Compliance freezes Ibrahim's wallet after his profile is suspended.
UPDATE accounts SET status = 'FROZEN' WHERE account_number = '1000000061';

COMMIT;   -- deferred double-entry checks run here
