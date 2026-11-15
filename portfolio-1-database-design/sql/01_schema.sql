-- =====================================================================
-- MIT 8103 Advanced Database Systems — Portfolio 1
-- Case study: PayHaven (simulated Nigerian digital banking / fintech)
-- File: 01_schema.sql — tables, keys and declarative constraints
-- Target: PostgreSQL 16
-- =====================================================================

DROP SCHEMA IF EXISTS payhaven CASCADE;
CREATE SCHEMA payhaven;
SET search_path TO payhaven;

-- ---------------------------------------------------------------------
-- 1. Reference / lookup tables
-- ---------------------------------------------------------------------

-- Nigerian banks reachable through NIP (NIBSS Instant Payments).
CREATE TABLE banks (
    bank_code    VARCHAR(6)   PRIMARY KEY,               -- natural key (CBN/NIBSS code)
    bank_name    VARCHAR(100) NOT NULL UNIQUE,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_bank_code_digits CHECK (bank_code ~ '^[0-9]{3,6}$')
);

-- Account products. Limits belong to the PRODUCT, not to each account (3NF).
CREATE TABLE account_products (
    product_code       VARCHAR(12)   PRIMARY KEY,
    product_name       VARCHAR(60)   NOT NULL UNIQUE,
    min_kyc_tier       SMALLINT      NOT NULL,
    daily_debit_limit  NUMERIC(18,2) NOT NULL,
    max_balance        NUMERIC(18,2),                    -- NULL = no cap
    interest_rate_pa   NUMERIC(5,2)  NOT NULL DEFAULT 0,
    CONSTRAINT chk_product_tier      CHECK (min_kyc_tier BETWEEN 1 AND 3),
    CONSTRAINT chk_product_limit     CHECK (daily_debit_limit > 0),
    CONSTRAINT chk_product_max_bal   CHECK (max_balance IS NULL OR max_balance > 0),
    CONSTRAINT chk_product_interest  CHECK (interest_rate_pa BETWEEN 0 AND 100)
);

-- ---------------------------------------------------------------------
-- 2. People
-- ---------------------------------------------------------------------

CREATE TABLE staff (
    staff_id      INTEGER      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_number  VARCHAR(10)  NOT NULL UNIQUE,          -- alternate key, e.g. PH-0001
    full_name     VARCHAR(120) NOT NULL,
    email         VARCHAR(150) NOT NULL,
    role          VARCHAR(20)  NOT NULL,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_staff_number CHECK (staff_number ~ '^PH-[0-9]{4}$'),
    CONSTRAINT chk_staff_role   CHECK (role IN ('KYC_OFFICER','SUPPORT','COMPLIANCE','ADMIN'))
);
CREATE UNIQUE INDEX uq_staff_email_ci ON staff (lower(email));

CREATE TABLE customers (
    customer_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- surrogate key
    bvn            CHAR(11)     NOT NULL UNIQUE,                           -- candidate key
    first_name     VARCHAR(60)  NOT NULL,
    middle_name    VARCHAR(60),
    last_name      VARCHAR(60)  NOT NULL,
    email          VARCHAR(150) NOT NULL,
    phone          VARCHAR(14)  NOT NULL UNIQUE,                           -- candidate key
    date_of_birth  DATE         NOT NULL,
    kyc_tier       SMALLINT     NOT NULL DEFAULT 1,
    status         VARCHAR(12)  NOT NULL DEFAULT 'PENDING',
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_customer_bvn    CHECK (bvn ~ '^[0-9]{11}$'),
    CONSTRAINT chk_customer_phone  CHECK (phone ~ '^\+234[0-9]{10}$'),
    CONSTRAINT chk_customer_email  CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT chk_customer_tier   CHECK (kyc_tier BETWEEN 1 AND 3),
    CONSTRAINT chk_customer_status CHECK (status IN ('PENDING','ACTIVE','SUSPENDED','CLOSED')),
    -- Customers must be 18+ at onboarding (deterministic: compares two columns, not now()).
    CONSTRAINT chk_customer_adult  CHECK (date_of_birth <= (created_at::date - INTERVAL '18 years'))
);
CREATE UNIQUE INDEX uq_customer_email_ci ON customers (lower(email));

-- Multi-valued attribute (a customer can have several addresses) -> own table (1NF).
CREATE TABLE customer_addresses (
    address_id    BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   BIGINT       NOT NULL REFERENCES customers (customer_id) ON DELETE CASCADE,
    address_type  VARCHAR(12)  NOT NULL,
    line1         VARCHAR(150) NOT NULL,
    line2         VARCHAR(150),
    city          VARCHAR(60)  NOT NULL,
    state         VARCHAR(40)  NOT NULL,
    CONSTRAINT chk_address_type CHECK (address_type IN ('RESIDENTIAL','MAILING','WORK')),
    CONSTRAINT uq_customer_address_type UNIQUE (customer_id, address_type)
);

-- KYC evidence. Weak-ish entity owned by a customer, reviewed by a staff member.
CREATE TABLE kyc_documents (
    document_id       BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id       BIGINT       NOT NULL REFERENCES customers (customer_id) ON DELETE CASCADE,
    document_type     VARCHAR(20)  NOT NULL,
    document_number   VARCHAR(30)  NOT NULL,
    status            VARCHAR(10)  NOT NULL DEFAULT 'SUBMITTED',
    submitted_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    reviewed_by       INTEGER      REFERENCES staff (staff_id) ON DELETE RESTRICT,
    reviewed_at       TIMESTAMPTZ,
    rejection_reason  VARCHAR(200),
    CONSTRAINT chk_kyc_doc_type   CHECK (document_type IN ('NIN','PASSPORT','DRIVERS_LICENCE','VOTERS_CARD','UTILITY_BILL')),
    CONSTRAINT chk_kyc_status     CHECK (status IN ('SUBMITTED','VERIFIED','REJECTED')),
    -- A document number identifies one physical document nationally.
    CONSTRAINT uq_kyc_document    UNIQUE (document_type, document_number),
    -- Reviewed documents must say who reviewed them and when.
    CONSTRAINT chk_kyc_reviewed   CHECK (
        (status = 'SUBMITTED' AND reviewed_by IS NULL AND reviewed_at IS NULL)
     OR (status IN ('VERIFIED','REJECTED') AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)
    ),
    CONSTRAINT chk_kyc_rejection  CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL),
    CONSTRAINT chk_kyc_review_time CHECK (reviewed_at IS NULL OR reviewed_at >= submitted_at)
);

-- ---------------------------------------------------------------------
-- 3. Accounts and payees
-- ---------------------------------------------------------------------

-- CUSTOMER accounts belong to a customer; SYSTEM accounts are internal ledgers
-- (NIP settlement, fee income, cash suspense) needed for double-entry bookkeeping.
CREATE TABLE accounts (
    account_id        BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number    CHAR(10)      NOT NULL UNIQUE,     -- NUBAN-style 10 digits
    account_category  VARCHAR(8)    NOT NULL DEFAULT 'CUSTOMER',
    customer_id       BIGINT        REFERENCES customers (customer_id) ON DELETE RESTRICT,
    product_code      VARCHAR(12)   REFERENCES account_products (product_code) ON UPDATE CASCADE,
    account_name      VARCHAR(120)  NOT NULL,
    currency          CHAR(3)       NOT NULL DEFAULT 'NGN',
    balance           NUMERIC(18,2) NOT NULL DEFAULT 0,  -- controlled denormalisation, see docs
    status            VARCHAR(8)    NOT NULL DEFAULT 'ACTIVE',
    version           INTEGER       NOT NULL DEFAULT 0,  -- optimistic-locking counter (Portfolio 3)
    opened_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    closed_at         TIMESTAMPTZ,
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_acct_number    CHECK (account_number ~ '^[0-9]{10}$'),
    CONSTRAINT chk_acct_category  CHECK (account_category IN ('CUSTOMER','SYSTEM')),
    CONSTRAINT chk_acct_currency  CHECK (currency IN ('NGN','USD')),
    CONSTRAINT chk_acct_status    CHECK (status IN ('ACTIVE','FROZEN','DORMANT','CLOSED')),
    -- Customer accounts need an owner and a product; system accounts have neither.
    CONSTRAINT chk_acct_ownership CHECK (
        (account_category = 'CUSTOMER' AND customer_id IS NOT NULL AND product_code IS NOT NULL)
     OR (account_category = 'SYSTEM'   AND customer_id IS NULL)
    ),
    -- No overdrafts on customer wallets. System (settlement) accounts may go negative.
    CONSTRAINT chk_acct_no_overdraft CHECK (account_category = 'SYSTEM' OR balance >= 0),
    CONSTRAINT chk_acct_closed    CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL)),
    CONSTRAINT chk_acct_close_time CHECK (closed_at IS NULL OR closed_at >= opened_at)
);
CREATE INDEX ix_accounts_customer ON accounts (customer_id);

-- Saved external payees (accounts at other banks).
CREATE TABLE beneficiaries (
    beneficiary_id  BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     BIGINT       NOT NULL REFERENCES customers (customer_id) ON DELETE CASCADE,
    bank_code       VARCHAR(6)   NOT NULL REFERENCES banks (bank_code),
    account_number  CHAR(10)     NOT NULL,
    account_name    VARCHAR(120) NOT NULL,
    nickname        VARCHAR(40),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_benef_acct_number CHECK (account_number ~ '^[0-9]{10}$'),
    CONSTRAINT uq_beneficiary UNIQUE (customer_id, bank_code, account_number)
);

-- ---------------------------------------------------------------------
-- 4. Money movement — double-entry ledger
-- ---------------------------------------------------------------------

-- One row per business event (a transfer, a deposit, a reversal ...).
CREATE TABLE transactions (
    transaction_id    BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference         VARCHAR(30)   NOT NULL UNIQUE,     -- idempotency key from the client app
    transaction_type  VARCHAR(20)   NOT NULL,
    status            VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    amount            NUMERIC(18,2) NOT NULL,
    fee               NUMERIC(18,2) NOT NULL DEFAULT 0,
    currency          CHAR(3)       NOT NULL DEFAULT 'NGN',
    channel           VARCHAR(8)    NOT NULL,
    narration         VARCHAR(140),
    initiated_by      BIGINT        REFERENCES customers (customer_id) ON DELETE RESTRICT,
    reversal_of       BIGINT        UNIQUE REFERENCES transactions (transaction_id),  -- reversed at most once
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    completed_at      TIMESTAMPTZ,
    CONSTRAINT chk_txn_type     CHECK (transaction_type IN
        ('DEPOSIT','WITHDRAWAL','INTERNAL_TRANSFER','EXTERNAL_TRANSFER','REVERSAL')),
    CONSTRAINT chk_txn_status   CHECK (status IN ('PENDING','SUCCESSFUL','FAILED','REVERSED')),
    CONSTRAINT chk_txn_amount   CHECK (amount > 0),
    CONSTRAINT chk_txn_fee      CHECK (fee >= 0),
    CONSTRAINT chk_txn_currency CHECK (currency IN ('NGN','USD')),
    CONSTRAINT chk_txn_channel  CHECK (channel IN ('MOBILE','WEB','USSD','API','SYSTEM')),
    -- Only REVERSAL rows point at another transaction, and they must.
    CONSTRAINT chk_txn_reversal CHECK ((transaction_type = 'REVERSAL') = (reversal_of IS NOT NULL)),
    CONSTRAINT chk_txn_no_self_reversal CHECK (reversal_of IS NULL OR reversal_of <> transaction_id),
    -- Pending transactions are not completed; finished ones are.
    CONSTRAINT chk_txn_completed CHECK ((status = 'PENDING') = (completed_at IS NULL)),
    CONSTRAINT chk_txn_time     CHECK (completed_at IS NULL OR completed_at >= created_at)
);
CREATE INDEX ix_txn_initiated_by ON transactions (initiated_by, created_at);

-- Every transaction produces >= 2 ledger lines whose debits equal credits
-- (enforced by a deferred constraint trigger in 02_functions_triggers.sql).
CREATE TABLE ledger_entries (
    entry_id        BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  BIGINT        NOT NULL REFERENCES transactions (transaction_id) ON DELETE RESTRICT,
    account_id      BIGINT        NOT NULL REFERENCES accounts (account_id) ON DELETE RESTRICT,
    direction       CHAR(6)       NOT NULL,
    amount          NUMERIC(18,2) NOT NULL,
    balance_after   NUMERIC(18,2) NOT NULL,             -- running balance snapshot (statements)
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_entry_direction CHECK (direction IN ('DEBIT','CREDIT')),
    CONSTRAINT chk_entry_amount    CHECK (amount > 0)
);
CREATE INDEX ix_ledger_txn     ON ledger_entries (transaction_id);
CREATE INDEX ix_ledger_account ON ledger_entries (account_id, created_at);

-- Subtype of transactions (1:1) holding NIP details only external transfers have.
-- Keeping these columns here avoids NULL-heavy columns on every transaction row.
CREATE TABLE external_transfers (
    transaction_id   BIGINT       PRIMARY KEY REFERENCES transactions (transaction_id) ON DELETE CASCADE,
    beneficiary_id   BIGINT       NOT NULL REFERENCES beneficiaries (beneficiary_id) ON DELETE RESTRICT,
    nip_session_id   VARCHAR(30)  UNIQUE,                -- assigned by NIBSS once sent
    response_code    CHAR(2),                            -- NIP response, '00' = approved
    CONSTRAINT chk_nip_response CHECK (response_code IS NULL OR response_code ~ '^[0-9]{2}$')
);

-- ---------------------------------------------------------------------
-- 5. Audit trail (populated by triggers)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name   TEXT         NOT NULL,
    record_pk    TEXT         NOT NULL,
    action       CHAR(6)      NOT NULL,
    old_row      JSONB,
    new_row      JSONB,
    changed_by   TEXT         NOT NULL DEFAULT current_user,
    changed_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_audit_action CHECK (action IN ('INSERT','UPDATE','DELETE'))
);
CREATE INDEX ix_audit_table_pk ON audit_log (table_name, record_pk);
