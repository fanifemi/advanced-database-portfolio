-- =====================================================================
-- Portfolio 3 — 01_transfer_procedures.sql
-- Concurrency-safe money movement for PayHaven.
--
-- Design (each point is tested in experiments.py):
--   * Runs at READ COMMITTED, PostgreSQL's default, with explicit row locks
--     (SELECT … FOR UPDATE): pessimistic concurrency control on the balance rows.
--   * Locks are always taken in ascending account_id order, so two transfers
--     in opposite directions cannot deadlock.
--   * Lock first, then read: once the row lock is held, the next statement
--     sees every committed debit, so balance and daily-limit checks are exact.
--   * Idempotent: a client may retry with the same reference; the UNIQUE
--     constraint on transactions.reference guarantees money moves once.
--   * Atomic: a function runs inside the caller's transaction, so any error
--     rolls back every row it touched.
-- =====================================================================
SET search_path TO payhaven;

-- Custom SQLSTATEs so applications can react precisely
--   PH001 insufficient funds · PH002 daily limit exceeded · PH003 account not usable
--   PH004 currency mismatch  · PH005 invalid request

-- ---------------------------------------------------------------------
-- Internal helper: post one ledger line. Caller MUST already hold the row lock.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _post_line(p_txn BIGINT, p_account BIGINT, p_dir TEXT, p_amount NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_new NUMERIC(18,2);
BEGIN
    UPDATE accounts
       SET balance = balance + CASE p_dir WHEN 'CREDIT' THEN p_amount ELSE -p_amount END,
           version = version + 1
     WHERE account_id = p_account
     RETURNING balance INTO v_new;
    INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
    VALUES (p_txn, p_account, p_dir, p_amount, v_new);
    RETURN v_new;
END $$;

-- ---------------------------------------------------------------------
-- Internal helper: lock a set of accounts in a deterministic order.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _lock_accounts(p_ids BIGINT[])
RETURNS VOID LANGUAGE sql AS $$
    SELECT 1 FROM accounts
    WHERE account_id = ANY (p_ids)
    ORDER BY account_id
    FOR UPDATE;
$$;

-- ---------------------------------------------------------------------
-- Internal helper: today's debits on an account (served by Portfolio 2's
-- covering index ix_ledger_account_time -> index-only scan).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _debited_today(p_account BIGINT)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(amount), 0) FROM ledger_entries
    WHERE account_id = p_account AND direction = 'DEBIT'
      AND created_at >= date_trunc('day', now()) AND created_at < date_trunc('day', now()) + INTERVAL '1 day';
$$;

-- ---------------------------------------------------------------------
-- Internal helper: validate a debit on a locked account
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _check_debit(p_account BIGINT, p_total NUMERIC)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE a accounts%ROWTYPE; v_limit NUMERIC; v_today NUMERIC;
BEGIN
    SELECT * INTO a FROM accounts WHERE account_id = p_account;
    IF a.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is %', a.account_number, a.status USING ERRCODE = 'PH003';
    END IF;
    IF a.balance < p_total THEN
        RAISE EXCEPTION 'Insufficient funds on %: balance %, needed %', a.account_number, a.balance, p_total
            USING ERRCODE = 'PH001';
    END IF;
    SELECT daily_debit_limit INTO v_limit FROM account_products WHERE product_code = a.product_code;
    v_today := _debited_today(p_account);
    IF v_today + p_total > v_limit THEN
        RAISE EXCEPTION 'Daily limit on %: already % today, limit %, requested %', a.account_number, v_today, v_limit, p_total
            USING ERRCODE = 'PH002';
    END IF;
END $$;

-- ---------------------------------------------------------------------
-- Idempotency helper: insert the transaction header, or return the
-- existing id if this reference was already processed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _begin_txn(p_ref TEXT, p_type TEXT, p_amount NUMERIC, p_fee NUMERIC,
                                      p_channel TEXT, p_narration TEXT, p_customer BIGINT,
                                      OUT txn_id BIGINT, OUT is_new BOOLEAN)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO transactions (reference, transaction_type, status, amount, fee, channel, narration, initiated_by)
    VALUES (p_ref, p_type, 'PENDING', p_amount, p_fee, p_channel, p_narration, p_customer)
    ON CONFLICT (reference) DO NOTHING
    RETURNING transaction_id INTO txn_id;
    is_new := txn_id IS NOT NULL;
    IF NOT is_new THEN
        -- Another request with this reference already exists. If it is still in
        -- flight, ON CONFLICT waited for it to commit, so the row is visible now.
        SELECT transaction_id INTO txn_id FROM transactions WHERE reference = p_ref;
    END IF;
END $$;

-- =====================================================================
-- PUBLIC API
-- =====================================================================

-- Deposit (card/bank funding): Funding Suspense GL -> customer
CREATE OR REPLACE FUNCTION deposit(p_ref TEXT, p_account CHAR(10), p_amount NUMERIC, p_channel TEXT DEFAULT 'WEB')
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_acct accounts%ROWTYPE; v_gl BIGINT; t RECORD;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'PH005'; END IF;
    SELECT * INTO v_acct FROM accounts WHERE account_number = p_account;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown account %', p_account USING ERRCODE = 'PH005'; END IF;
    SELECT account_id INTO v_gl FROM accounts WHERE account_number = '9000000003';

    t := _begin_txn(p_ref, 'DEPOSIT', p_amount, 0, p_channel, 'Wallet funding', v_acct.customer_id);
    IF NOT t.is_new THEN RETURN t.txn_id; END IF;

    PERFORM _lock_accounts(ARRAY[v_acct.account_id, v_gl]);
    IF (SELECT status FROM accounts WHERE account_id = v_acct.account_id) <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Account % is not active', p_account USING ERRCODE = 'PH003';
    END IF;
    PERFORM _post_line(t.txn_id, v_gl, 'DEBIT', p_amount);
    PERFORM _post_line(t.txn_id, v_acct.account_id, 'CREDIT', p_amount);
    UPDATE transactions SET status = 'SUCCESSFUL', completed_at = now() WHERE transaction_id = t.txn_id;
    RETURN t.txn_id;
END $$;

-- Internal transfer between two PayHaven accounts
CREATE OR REPLACE FUNCTION transfer(p_ref TEXT, p_from CHAR(10), p_to CHAR(10), p_amount NUMERIC,
                                    p_channel TEXT DEFAULT 'MOBILE', p_narration TEXT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_from accounts%ROWTYPE; v_to accounts%ROWTYPE; t RECORD;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'PH005'; END IF;
    IF p_from = p_to THEN RAISE EXCEPTION 'Cannot transfer to the same account' USING ERRCODE = 'PH005'; END IF;
    SELECT * INTO v_from FROM accounts WHERE account_number = p_from;
    SELECT * INTO v_to   FROM accounts WHERE account_number = p_to;
    IF v_from.account_id IS NULL OR v_to.account_id IS NULL THEN
        RAISE EXCEPTION 'Unknown account' USING ERRCODE = 'PH005';
    END IF;
    IF v_from.currency <> v_to.currency THEN
        RAISE EXCEPTION 'Currency mismatch % -> %', v_from.currency, v_to.currency USING ERRCODE = 'PH004';
    END IF;

    t := _begin_txn(p_ref, 'INTERNAL_TRANSFER', p_amount, 0, p_channel, p_narration, v_from.customer_id);
    IF NOT t.is_new THEN RETURN t.txn_id; END IF;          -- duplicate request: no second debit

    PERFORM _lock_accounts(ARRAY[v_from.account_id, v_to.account_id]);   -- ordered locks
    PERFORM _check_debit(v_from.account_id, p_amount);                   -- read AFTER locking
    IF (SELECT status FROM accounts WHERE account_id = v_to.account_id) <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Beneficiary account % is not active', p_to USING ERRCODE = 'PH003';
    END IF;

    PERFORM _post_line(t.txn_id, v_from.account_id, 'DEBIT',  p_amount);
    PERFORM _post_line(t.txn_id, v_to.account_id,   'CREDIT', p_amount);
    UPDATE transactions SET status = 'SUCCESSFUL', completed_at = now() WHERE transaction_id = t.txn_id;
    RETURN t.txn_id;
END $$;

-- External (NIP) transfer: sender DR amount+fee, settlement CR amount, fee income CR fee
CREATE OR REPLACE FUNCTION nip_transfer(p_ref TEXT, p_from CHAR(10), p_beneficiary BIGINT, p_amount NUMERIC,
                                        p_channel TEXT DEFAULT 'MOBILE', p_narration TEXT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_from accounts%ROWTYPE; v_settle BIGINT; v_fees BIGINT; v_fee NUMERIC; t RECORD;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'Amount must be positive' USING ERRCODE = 'PH005'; END IF;
    SELECT * INTO v_from FROM accounts WHERE account_number = p_from;
    IF NOT EXISTS (SELECT 1 FROM beneficiaries WHERE beneficiary_id = p_beneficiary
                                                 AND customer_id = v_from.customer_id) THEN
        RAISE EXCEPTION 'Beneficiary % does not belong to this customer', p_beneficiary USING ERRCODE = 'PH005';
    END IF;
    SELECT account_id INTO v_settle FROM accounts WHERE account_number = '9000000001';
    SELECT account_id INTO v_fees   FROM accounts WHERE account_number = '9000000002';
    v_fee := CASE WHEN p_amount <= 5000 THEN 10.75 WHEN p_amount <= 50000 THEN 26.88 ELSE 53.75 END;

    t := _begin_txn(p_ref, 'EXTERNAL_TRANSFER', p_amount, v_fee, p_channel, p_narration, v_from.customer_id);
    IF NOT t.is_new THEN RETURN t.txn_id; END IF;

    PERFORM _lock_accounts(ARRAY[v_from.account_id, v_settle, v_fees]);
    PERFORM _check_debit(v_from.account_id, p_amount + v_fee);
    PERFORM _post_line(t.txn_id, v_from.account_id, 'DEBIT',  p_amount + v_fee);
    PERFORM _post_line(t.txn_id, v_settle,           'CREDIT', p_amount);
    PERFORM _post_line(t.txn_id, v_fees,             'CREDIT', v_fee);
    INSERT INTO external_transfers (transaction_id, beneficiary_id, nip_session_id, response_code)
    VALUES (t.txn_id, p_beneficiary, '999' || lpad(t.txn_id::text, 21, '0'), '00');
    UPDATE transactions SET status = 'SUCCESSFUL', completed_at = now() WHERE transaction_id = t.txn_id;
    RETURN t.txn_id;
END $$;

-- Reverse a SUCCESSFUL transaction: mirror every ledger line, refund amount + fee.
CREATE OR REPLACE FUNCTION reverse_transaction(p_original_ref TEXT, p_reason TEXT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE o transactions%ROWTYPE; v_rev BIGINT; l RECORD;
BEGIN
    -- Lock the original first so two reversal attempts cannot both proceed.
    SELECT * INTO o FROM transactions WHERE reference = p_original_ref FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown transaction %', p_original_ref USING ERRCODE = 'PH005'; END IF;

    INSERT INTO transactions (reference, transaction_type, status, amount, fee, channel, narration, reversal_of)
    VALUES (p_original_ref || '-R', 'REVERSAL', 'PENDING', o.amount + o.fee, 0, 'SYSTEM', p_reason, o.transaction_id)
    RETURNING transaction_id INTO v_rev;            -- trigger R6 validates status/amount

    PERFORM _lock_accounts(ARRAY(SELECT account_id FROM ledger_entries WHERE transaction_id = o.transaction_id));
    FOR l IN SELECT account_id, direction, amount FROM ledger_entries
             WHERE transaction_id = o.transaction_id ORDER BY entry_id LOOP
        PERFORM _post_line(v_rev, l.account_id,
                           CASE l.direction WHEN 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END, l.amount);
    END LOOP;
    UPDATE transactions SET status = 'SUCCESSFUL', completed_at = now() WHERE transaction_id = v_rev;
    UPDATE transactions SET status = 'REVERSED' WHERE transaction_id = o.transaction_id;
    RETURN v_rev;
END $$;

-- Operations tool: rebuild a stored balance from the ledger (used after the
-- deliberately broken "naive" experiments; never needed with the functions above).
CREATE OR REPLACE FUNCTION repair_balance_from_ledger(p_account BIGINT)
RETURNS NUMERIC LANGUAGE sql AS $$
    UPDATE accounts a
       SET balance = (SELECT COALESCE(sum(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END), 0)
                      FROM ledger_entries WHERE account_id = p_account)
     WHERE a.account_id = p_account
    RETURNING balance;
$$;
