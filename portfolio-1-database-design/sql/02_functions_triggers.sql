-- =====================================================================
-- File: 02_functions_triggers.sql
-- Business rules that CHECK / FOREIGN KEY constraints cannot express
-- because they span rows or tables.
-- =====================================================================
SET search_path TO payhaven;

-- ---------------------------------------------------------------------
-- R1. Keep updated_at current
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER customers_updated_at BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER accounts_updated_at BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- ---------------------------------------------------------------------
-- R2. Account must respect its product: customer KYC tier >= product
--     requirement, and balance <= product max_balance.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_account_product_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_required_tier SMALLINT;
    v_max_balance   NUMERIC(18,2);
    v_customer_tier SMALLINT;
BEGIN
    IF NEW.account_category = 'SYSTEM' THEN
        RETURN NEW;
    END IF;

    SELECT min_kyc_tier, max_balance INTO v_required_tier, v_max_balance
    FROM account_products WHERE product_code = NEW.product_code;

    SELECT kyc_tier INTO v_customer_tier
    FROM customers WHERE customer_id = NEW.customer_id;

    IF TG_OP = 'INSERT' OR NEW.product_code IS DISTINCT FROM OLD.product_code THEN
        IF v_customer_tier < v_required_tier THEN
            RAISE EXCEPTION 'Customer % is KYC tier %, product % needs tier %',
                NEW.customer_id, v_customer_tier, NEW.product_code, v_required_tier
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF v_max_balance IS NOT NULL AND NEW.balance > v_max_balance THEN
        RAISE EXCEPTION 'Balance % exceeds product % maximum of %',
            NEW.balance, NEW.product_code, v_max_balance
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER accounts_product_rules
    BEFORE INSERT OR UPDATE OF balance, product_code, customer_id ON accounts
    FOR EACH ROW EXECUTE FUNCTION trg_account_product_rules();

-- ---------------------------------------------------------------------
-- R3. Ledger line currency must match the transaction currency, and
--     money cannot move on a FROZEN or CLOSED account.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_ledger_entry_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_acct_currency CHAR(3);
    v_acct_status   VARCHAR(8);
    v_txn_currency  CHAR(3);
BEGIN
    SELECT currency, status INTO v_acct_currency, v_acct_status
    FROM accounts WHERE account_id = NEW.account_id;

    SELECT currency INTO v_txn_currency
    FROM transactions WHERE transaction_id = NEW.transaction_id;

    IF v_acct_currency <> v_txn_currency THEN
        RAISE EXCEPTION 'Currency mismatch: account % is %, transaction % is %',
            NEW.account_id, v_acct_currency, NEW.transaction_id, v_txn_currency
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_acct_status IN ('FROZEN','CLOSED') THEN
        RAISE EXCEPTION 'Account % is % and cannot be posted to', NEW.account_id, v_acct_status
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER ledger_entry_rules BEFORE INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_entry_rules();

-- ---------------------------------------------------------------------
-- R4. Double-entry rule: for each transaction, total DEBITS = total CREDITS.
--     DEFERRABLE INITIALLY DEFERRED so it is checked at COMMIT, after all
--     lines of the transaction have been inserted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_check_transaction_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_debits  NUMERIC(18,2);
    v_credits NUMERIC(18,2);
    v_lines   INTEGER;
BEGIN
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction = 'DEBIT'),  0),
           COALESCE(SUM(amount) FILTER (WHERE direction = 'CREDIT'), 0),
           COUNT(*)
      INTO v_debits, v_credits, v_lines
      FROM ledger_entries
     WHERE transaction_id = NEW.transaction_id;

    IF v_lines < 2 OR v_debits <> v_credits THEN
        RAISE EXCEPTION 'Transaction % is unbalanced: debits %, credits %, lines %',
            NEW.transaction_id, v_debits, v_credits, v_lines
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ledger_must_balance
    AFTER INSERT ON ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_check_transaction_balanced();

-- ---------------------------------------------------------------------
-- R5. The ledger is append-only. Mistakes are fixed with a REVERSAL
--     transaction, never by editing history.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_ledger_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ledger_entries is append-only (% not allowed); post a REVERSAL instead', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER ledger_no_update BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_immutable();

-- ---------------------------------------------------------------------
-- R6. A REVERSAL must point at a SUCCESSFUL, non-reversal transaction
--     of the same amount and currency.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_reversal_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_orig transactions%ROWTYPE;
BEGIN
    -- Non-REVERSAL rows are left to the chk_txn_reversal CHECK constraint.
    IF NEW.reversal_of IS NULL OR NEW.transaction_type <> 'REVERSAL' THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_orig FROM transactions WHERE transaction_id = NEW.reversal_of;

    IF v_orig.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION 'Cannot reverse a reversal (transaction %)', v_orig.transaction_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_orig.status <> 'SUCCESSFUL' THEN
        RAISE EXCEPTION 'Only SUCCESSFUL transactions can be reversed; % is %',
            v_orig.transaction_id, v_orig.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.amount <> v_orig.amount + v_orig.fee OR NEW.currency <> v_orig.currency THEN
        RAISE EXCEPTION 'Reversal must return amount + fee (% %)', v_orig.amount + v_orig.fee, v_orig.currency
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER transactions_reversal_rules BEFORE INSERT ON transactions
    FOR EACH ROW EXECUTE FUNCTION trg_reversal_rules();

-- ---------------------------------------------------------------------
-- R7. Generic audit trigger (who changed what, before and after)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_pk_col TEXT := TG_ARGV[0];
    v_pk     TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_pk := to_jsonb(OLD) ->> v_pk_col;
        INSERT INTO audit_log (table_name, record_pk, action, old_row)
        VALUES (TG_TABLE_NAME, v_pk, TG_OP, to_jsonb(OLD));
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        v_pk := to_jsonb(NEW) ->> v_pk_col;
        INSERT INTO audit_log (table_name, record_pk, action, old_row, new_row)
        VALUES (TG_TABLE_NAME, v_pk, TG_OP, to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;
    ELSE
        v_pk := to_jsonb(NEW) ->> v_pk_col;
        INSERT INTO audit_log (table_name, record_pk, action, new_row)
        VALUES (TG_TABLE_NAME, v_pk, TG_OP, to_jsonb(NEW));
        RETURN NEW;
    END IF;
END $$;

CREATE TRIGGER customers_audit AFTER INSERT OR UPDATE OR DELETE ON customers
    FOR EACH ROW EXECUTE FUNCTION trg_audit('customer_id');
CREATE TRIGGER accounts_audit AFTER INSERT OR UPDATE OR DELETE ON accounts
    FOR EACH ROW EXECUTE FUNCTION trg_audit('account_id');
CREATE TRIGGER transactions_audit AFTER UPDATE OR DELETE ON transactions
    FOR EACH ROW EXECUTE FUNCTION trg_audit('transaction_id');
