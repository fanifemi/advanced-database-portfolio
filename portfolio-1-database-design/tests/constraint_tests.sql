-- =====================================================================
-- File: tests/constraint_tests.sql
-- Proves each key/constraint/trigger rejects bad data and accepts good data.
-- Every test runs in its own sub-transaction and is rolled back, so the
-- seed data is never changed. Output: one PASS/FAIL line per test.
-- =====================================================================
SET search_path TO payhaven;
SET client_min_messages TO notice;

CREATE TEMP TABLE test_results (n SERIAL, test_name TEXT, expected TEXT, got TEXT, result TEXT);

-- expect_error: the statement must fail with the given SQLSTATE
CREATE FUNCTION pg_temp.expect_error(p_name TEXT, p_sql TEXT, p_state TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        SET CONSTRAINTS ALL IMMEDIATE;          -- fire deferred triggers now
        EXECUTE p_sql;
        INSERT INTO test_results (test_name, expected, got, result)
        VALUES (p_name, p_state, 'no error', 'FAIL');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO test_results (test_name, expected, got, result)
        VALUES (p_name, p_state, SQLSTATE || ' ' || left(SQLERRM, 70),
                CASE WHEN SQLSTATE = p_state THEN 'PASS' ELSE 'FAIL' END);
    END;
END $$;

-- expect_ok: the statement must succeed (then it is rolled back)
CREATE FUNCTION pg_temp.expect_ok(p_name TEXT, p_sql TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        SET CONSTRAINTS ALL IMMEDIATE;
        EXECUTE p_sql;
        RAISE EXCEPTION 'rollback' USING ERRCODE = 'P0001', HINT = 'ok';
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO test_results (test_name, expected, got, result)
        VALUES (p_name, 'success', CASE WHEN SQLERRM = 'rollback' THEN 'success' ELSE SQLSTATE || ' ' || left(SQLERRM, 70) END,
                CASE WHEN SQLERRM = 'rollback' THEN 'PASS' ELSE 'FAIL' END);
    END;
END $$;

-- ---------------- Entity integrity (PK / UNIQUE) ----------------
SELECT pg_temp.expect_error('Duplicate BVN rejected',
 $$INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth)
   VALUES ('22100000001','Dup','User','dup@mail.example','+2348099999999','1990-01-01')$$, '23505');

SELECT pg_temp.expect_error('Duplicate email rejected (case-insensitive)',
 $$INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth)
   VALUES ('22199999999','Dup','User','ADAEZE.OKAFOR@mail.example','+2348099999999','1990-01-01')$$, '23505');

SELECT pg_temp.expect_error('Duplicate account number rejected',
 $$INSERT INTO accounts (account_number, customer_id, product_code, account_name)
   VALUES ('1000000011', 2, 'PH_TIER2', 'X')$$, '23505');

SELECT pg_temp.expect_error('Duplicate transaction reference rejected (idempotency)',
 $$INSERT INTO transactions (reference, transaction_type, amount, channel)
   VALUES ('PH-DEP-0001','DEPOSIT', 100, 'WEB')$$, '23505');

SELECT pg_temp.expect_error('Same KYC document cannot be used twice',
 $$INSERT INTO kyc_documents (customer_id, document_type, document_number)
   VALUES (2, 'NIN', '70000000001')$$, '23505');

-- Two reversals of the same transaction in one statement: the UNIQUE
-- constraint on reversal_of stops the second one.
SELECT pg_temp.expect_error('A transaction can only be reversed once (UNIQUE reversal_of)',
 $$INSERT INTO transactions (reference, transaction_type, status, amount, channel, reversal_of, completed_at)
   SELECT r.ref, 'REVERSAL', 'SUCCESSFUL', 120053.75, 'SYSTEM', t.transaction_id, now()
   FROM transactions t, (VALUES ('PH-REV-9998'), ('PH-REV-9999')) AS r(ref)
   WHERE t.reference = 'PH-EXT-0001'$$, '23505');

-- ---------------- Referential integrity (FK) ----------------
SELECT pg_temp.expect_error('Account for non-existent customer rejected',
 $$INSERT INTO accounts (account_number, customer_id, product_code, account_name)
   VALUES ('1000009999', 9999, 'PH_TIER1', 'Ghost')$$, '23503');

SELECT pg_temp.expect_error('Beneficiary at unknown bank rejected',
 $$INSERT INTO beneficiaries (customer_id, bank_code, account_number, account_name)
   VALUES (1, '123', '0000000001', 'Nobody')$$, '23503');

SELECT pg_temp.expect_error('Cannot delete a customer who still has accounts (RESTRICT)',
 $$DELETE FROM customers WHERE customer_id = 1$$, '23503');

-- ---------------- Domain / CHECK constraints ----------------
SELECT pg_temp.expect_error('BVN must be 11 digits',
 $$INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth)
   VALUES ('12345','A','B','a@b.example','+2348099999999','1990-01-01')$$, '23514');

SELECT pg_temp.expect_error('Phone must be +234 format',
 $$INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth)
   VALUES ('22199999999','A','B','a@b.example','08031234567','1990-01-01')$$, '23514');

SELECT pg_temp.expect_error('Under-18 customer rejected',
 $$INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth)
   VALUES ('22199999999','Teen','User','t@b.example','+2348099999999', current_date - 3000)$$, '23514');

SELECT pg_temp.expect_error('Customer wallet cannot go negative (no overdraft)',
 $$UPDATE accounts SET balance = -1 WHERE account_number = '1000000031'$$, '23514');

SELECT pg_temp.expect_error('SYSTEM account cannot have an owner',
 $$INSERT INTO accounts (account_number, account_category, customer_id, account_name)
   VALUES ('9000000099','SYSTEM', 1, 'Bad GL')$$, '23514');

SELECT pg_temp.expect_error('Transaction amount must be positive',
 $$INSERT INTO transactions (reference, transaction_type, amount, channel)
   VALUES ('PH-T-0001','DEPOSIT', 0, 'WEB')$$, '23514');

SELECT pg_temp.expect_error('Non-reversal cannot reference another transaction',
 $$INSERT INTO transactions (reference, transaction_type, amount, channel, reversal_of)
   VALUES ('PH-T-0002','DEPOSIT', 10, 'WEB', 1)$$, '23514');

SELECT pg_temp.expect_error('Verified KYC document must name a reviewer',
 $$INSERT INTO kyc_documents (customer_id, document_type, document_number, status)
   VALUES (2, 'PASSPORT', 'A99999999', 'VERIFIED')$$, '23514');

SELECT pg_temp.expect_error('Closed account must have closed_at',
 $$UPDATE accounts SET status = 'CLOSED' WHERE account_number = '1000000051'$$, '23514');

-- ---------------- Trigger-enforced business rules ----------------
SELECT pg_temp.expect_error('R2: Tier-1 customer cannot open a Tier-3 product',
 $$INSERT INTO accounts (account_number, customer_id, product_code, account_name)
   VALUES ('1000000032', 3, 'PH_TIER3', 'FATIMA PREMIUM')$$, '23514');

SELECT pg_temp.expect_error('R2: Tier-1 wallet cannot exceed N300,000 balance',
 $$UPDATE accounts SET balance = 300000.01 WHERE account_number = '1000000031'$$, '23514');

SELECT pg_temp.expect_error('R3: Cannot post to a FROZEN account',
 $$WITH t AS (INSERT INTO transactions (reference, transaction_type, status, amount, channel, completed_at)
              VALUES ('PH-T-0003','DEPOSIT','SUCCESSFUL', 500, 'SYSTEM', now()) RETURNING transaction_id)
   INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
   SELECT transaction_id, (SELECT account_id FROM accounts WHERE account_number='1000000061'), 'CREDIT', 500, 80500 FROM t$$, '23514');

SELECT pg_temp.expect_error('R3: USD transaction cannot post to NGN account',
 $$WITH t AS (INSERT INTO transactions (reference, transaction_type, status, amount, currency, channel, completed_at)
              VALUES ('PH-T-0004','DEPOSIT','SUCCESSFUL', 10, 'USD', 'SYSTEM', now()) RETURNING transaction_id)
   INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
   SELECT transaction_id, 4, 'CREDIT', 10, 0 FROM t$$, '23514');

SELECT pg_temp.expect_error('R4: Unbalanced transaction (debit 1000, credit 900) rejected',
 $$WITH t AS (INSERT INTO transactions (reference, transaction_type, status, amount, channel, completed_at)
              VALUES ('PH-T-0005','INTERNAL_TRANSFER','SUCCESSFUL', 1000, 'MOBILE', now()) RETURNING transaction_id)
   INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
   SELECT transaction_id, 4, 'DEBIT', 1000, 1154000 FROM t
   UNION ALL SELECT transaction_id, 6, 'CREDIT', 900, 295900 FROM t$$, '23514');

SELECT pg_temp.expect_ok('R4: Balanced transaction (debit 1000, credit 1000) accepted',
 $$WITH t AS (INSERT INTO transactions (reference, transaction_type, status, amount, channel, completed_at)
              VALUES ('PH-T-0006','INTERNAL_TRANSFER','SUCCESSFUL', 1000, 'MOBILE', now()) RETURNING transaction_id)
   INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
   SELECT transaction_id, 4, 'DEBIT', 1000, 1154000 FROM t
   UNION ALL SELECT transaction_id, 6, 'CREDIT', 1000, 296000 FROM t$$);

SELECT pg_temp.expect_error('R5: Ledger lines cannot be edited',
 $$UPDATE ledger_entries SET amount = 1 WHERE entry_id = 1$$, '42501');

SELECT pg_temp.expect_error('R5: Ledger lines cannot be deleted',
 $$DELETE FROM ledger_entries WHERE entry_id = 1$$, '42501');

SELECT pg_temp.expect_error('R6: FAILED transaction cannot be reversed',
 $$INSERT INTO transactions (reference, transaction_type, status, amount, channel, reversal_of, completed_at)
   VALUES ('PH-REV-0002','REVERSAL','SUCCESSFUL', 15026.88, 'SYSTEM',
           (SELECT transaction_id FROM transactions WHERE reference='PH-EXT-0002'), now())$$, '23514');

SELECT pg_temp.expect_error('R6: Reversal must refund amount + fee exactly',
 $$INSERT INTO transactions (reference, transaction_type, status, amount, channel, reversal_of, completed_at)
   VALUES ('PH-REV-0003','REVERSAL','SUCCESSFUL', 120000.00, 'SYSTEM',
           (SELECT transaction_id FROM transactions WHERE reference='PH-EXT-0001'), now())$$, '23514');

SELECT pg_temp.expect_ok('Valid new Tier-2 customer and wallet accepted',
 $$WITH c AS (INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, status)
              VALUES ('22100000007','Bisi','Ogunleye','bisi@mail.example','+2348031000007','1998-05-05', 2, 'ACTIVE')
              RETURNING customer_id)
   INSERT INTO accounts (account_number, customer_id, product_code, account_name)
   SELECT '1000000071', customer_id, 'PH_TIER2', 'BISI OGUNLEYE' FROM c$$);

SELECT pg_temp.expect_ok('R7: Audit trigger records account updates',
 $t$DO $do$ DECLARE n_before INT; n_after INT; BEGIN
     SELECT count(*) INTO n_before FROM audit_log WHERE table_name='accounts';
     UPDATE accounts SET status='DORMANT' WHERE account_number='1000000051';
     SELECT count(*) INTO n_after FROM audit_log WHERE table_name='accounts';
     IF n_after <> n_before + 1 THEN RAISE EXCEPTION 'audit row missing'; END IF;
   END $do$$t$);

-- ---------------- Report ----------------
\echo
\echo '==================== CONSTRAINT TEST RESULTS ===================='
SELECT n AS "#", result, test_name, got AS "error raised" FROM test_results ORDER BY n;
SELECT count(*) FILTER (WHERE result='PASS') AS passed,
       count(*) FILTER (WHERE result='FAIL') AS failed,
       count(*) AS total
FROM test_results;
