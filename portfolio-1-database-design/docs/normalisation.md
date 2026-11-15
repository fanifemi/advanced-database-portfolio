# Normalisation — from the Operations Spreadsheet to 3NF/BCNF

## 0. Starting point: the unnormalised "transfers report" (UNF)

Before the platform existed, a typical operations team would track transfers in one spreadsheet like this:

| txn_ref | date | sender_name | sender_bvn | sender_phone | sender_acct_no | sender_tier | product_name | daily_limit | kyc_docs | recipient_bank_code | recipient_bank_name | recipient_acct_no | recipient_name | amount | fee | status |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PH-EXT-0001 | 2026-03-05 | Chinedu Eze | 22100000004 | +2348031000004 | 1000000041 | 3 | Premium Wallet | 5,000,000 | NIN:70000000004; PASSPORT:B01234567 | 057 | Zenith Bank | 2087654321 | EZE AMARACHI | 120,000 | 53.75 | SUCCESSFUL |
| PH-EXT-0003 | 2026-03-08 | Adaeze Okafor | 22100000001 | +2348031000001 | 1000000011 | 3 | Premium Wallet | 5,000,000 | NIN:70000000001; UTILITY_BILL:IKEDC-558201 | 058 | Guaranty Trust Bank | 0123456789 | OBINNA OKAFOR | 60,000 | 53.75 | REVERSED |

### Problems (anomalies)

| Anomaly | Example |
|---|---|
| **Update** | If Adaeze changes her phone number, every row she ever sent must be updated. Miss one and the data contradicts itself. |
| **Insertion** | A customer who has not made a transfer yet cannot be recorded at all, and neither can a new bank. |
| **Deletion** | Deleting Chinedu's only transfer also deletes the only record that Zenith Bank's code is 057. |
| **Redundancy** | "Premium Wallet, 5,000,000" is repeated for every transfer by every Tier-3 customer. |
| **Non-atomic values** | `kyc_docs` holds a list ("NIN:…; PASSPORT:…"), so you can't query "all unverified passports". |

---

## 1. First Normal Form (1NF)

**Rule:** every column holds one atomic value, there are no repeating groups, and every row is unique (there's a key).

- `kyc_docs` is a repeating group. Split it into rows: **KYC_DOCUMENT(document_type, document_number, …)**, one row per document.
- `sender_name` is composite. Split it into `first_name`, `middle_name` and `last_name`.
- Addresses (one customer can have several) move into their own relation, **CUSTOMER_ADDRESSES**.
- Key of the remaining transfer relation: **txn_ref**.

Result (still one wide table, but atomic):
`TRANSFER(txn_ref, date, sender_bvn, first_name, last_name, sender_phone, sender_acct_no, sender_tier, product_name, daily_limit, recipient_bank_code, recipient_bank_name, recipient_acct_no, recipient_name, amount, fee, status)`

## 2. Second Normal Form (2NF)

**Rule:** 1NF, and no non-key attribute depends on only *part* of a composite key.

- `TRANSFER` has a single-column key (`txn_ref`), so it can't have partial dependencies.
- The split-out KYC relation is where 2NF matters. If its key is the composite **(customer_bvn, document_type, document_number)**, then `customer_name` depends only on `customer_bvn`, which is part of the key. That's a partial dependency.
  Fix: keep only the BVN reference (a FK to the customer) in the document relation, and keep the name in **CUSTOMERS**.
- PayHaven then gives KYC documents a surrogate key (`document_id`) and keeps `(document_type, document_number)` as a UNIQUE alternate key.

## 3. Third Normal Form (3NF)

**Rule:** 2NF, and no **transitive dependency** (non-key → non-key).

Functional dependencies found in `TRANSFER`:

| Dependency | Why it's transitive | New relation |
|---|---|---|
| `txn_ref → sender_acct_no → sender_bvn → first_name, last_name, phone, tier` | Customer facts depend on the customer, not on the transfer | **CUSTOMERS**(customer_id PK, bvn UK, …) |
| `sender_acct_no → product_name → daily_limit, max_balance` | Limits depend on the product, not on the account | **ACCOUNT_PRODUCTS**(product_code PK, …), **ACCOUNTS**(…, product_code FK) |
| `recipient_bank_code → recipient_bank_name` | Bank name depends on bank code | **BANKS**(bank_code PK, bank_name UK) |
| `(customer, recipient_bank_code, recipient_acct_no) → recipient_name` | The payee's name depends on the payee, not on each transfer | **BENEFICIARIES**(beneficiary_id PK, customer_id FK, bank_code FK, account_number, account_name) |
| `txn_ref → nip_session_id, response_code` (only for external transfers) | Fine as an FD, but applies to only one subtype. Storing it on every row creates NULL-heavy columns | **EXTERNAL_TRANSFERS**(transaction_id PK/FK, …), a 1:1 subtype |

### Splitting the money movement itself

"Amount moved from account A to account B" sounds like one fact, but a transfer with a fee touches three accounts (sender, settlement, fee income), and a reversal touches them again in reverse. Storing `from_account`, `to_account` and `fee_account` columns on the transaction would be a repeating group in disguise. PayHaven uses the standard **double-entry** decomposition instead:

- **TRANSACTIONS**: one row per business event (`reference`, type, status, amount, fee, …)
- **LEDGER_ENTRIES**: one row per account affected (`transaction_id`, `account_id`, DEBIT/CREDIT, amount)

Every non-key column of `ledger_entries` depends only on `entry_id`, and the rule "debits = credits per transaction" is enforced by a deferred constraint trigger (R4).

## 4. Boyce–Codd Normal Form (BCNF) check

**Rule:** for every non-trivial FD `X → Y`, X is a superkey.

| Relation | Determinants | Superkey? |
|---|---|---|
| customers | customer_id, bvn, phone, lower(email) | All are candidate keys (PK or UNIQUE) ✔ |
| accounts | account_id, account_number | Both keys ✔ |
| account_products | product_code, product_name | Both keys ✔ |
| banks | bank_code, bank_name | Both keys ✔ |
| kyc_documents | document_id, (document_type, document_number) | Both keys ✔ |
| beneficiaries | beneficiary_id, (customer_id, bank_code, account_number) | Both keys ✔ |
| transactions | transaction_id, reference | Both keys ✔ |
| external_transfers | transaction_id, nip_session_id | Both keys ✔ |
| customer_addresses | address_id, (customer_id, address_type) | Both keys ✔ |

Every determinant is a candidate key, so the schema is in **BCNF**.

## 5. Deliberate, controlled denormalisation

Normalisation is the default. These three exceptions are deliberate, each with a safeguard:

| Denormalised column | Derivable from | Why we keep it | How consistency is protected |
|---|---|---|---|
| `accounts.balance` | `SUM(credits) − SUM(debits)` in `ledger_entries` | Every transfer must check the balance quickly. Summing millions of ledger rows under a lock would be too slow (Portfolio 2/3) | Updated in the same DB transaction as the ledger lines. `v_balance_reconciliation` must always return difference = 0 |
| `ledger_entries.balance_after` | Running sum of the ledger | Statements and dispute resolution need "balance after each line" without a window function over full history | Ledger is append-only (trigger R5), so the snapshot can never drift after it's written |
| `accounts.account_name` | Customer name | It's the *registered* account name used for NIP name-enquiry. It legally may differ from the current profile name (e.g., a business name or a name changed after opening) | Treated as its own attribute, not a copy |

## 6. Final relational schema (summary)

```
BANKS(bank_code PK, bank_name UK, is_active)
ACCOUNT_PRODUCTS(product_code PK, product_name UK, min_kyc_tier, daily_debit_limit, max_balance, interest_rate_pa)
STAFF(staff_id PK, staff_number UK, full_name, email UK, role, is_active, created_at)
CUSTOMERS(customer_id PK, bvn UK, first_name, middle_name, last_name, email UK, phone UK,
          date_of_birth, kyc_tier, status, created_at, updated_at)
CUSTOMER_ADDRESSES(address_id PK, customer_id FK→CUSTOMERS, address_type, line1, line2, city, state,
          UK(customer_id, address_type))
KYC_DOCUMENTS(document_id PK, customer_id FK→CUSTOMERS, document_type, document_number, status,
          submitted_at, reviewed_by FK→STAFF, reviewed_at, rejection_reason, UK(document_type, document_number))
ACCOUNTS(account_id PK, account_number UK, account_category, customer_id FK→CUSTOMERS,
          product_code FK→ACCOUNT_PRODUCTS, account_name, currency, balance, status, version,
          opened_at, closed_at, updated_at)
BENEFICIARIES(beneficiary_id PK, customer_id FK→CUSTOMERS, bank_code FK→BANKS, account_number,
          account_name, nickname, created_at, UK(customer_id, bank_code, account_number))
TRANSACTIONS(transaction_id PK, reference UK, transaction_type, status, amount, fee, currency, channel,
          narration, initiated_by FK→CUSTOMERS, reversal_of FK→TRANSACTIONS UK, created_at, completed_at)
LEDGER_ENTRIES(entry_id PK, transaction_id FK→TRANSACTIONS, account_id FK→ACCOUNTS, direction,
          amount, balance_after, created_at)
EXTERNAL_TRANSFERS(transaction_id PK FK→TRANSACTIONS, beneficiary_id FK→BENEFICIARIES,
          nip_session_id UK, response_code)
AUDIT_LOG(audit_id PK, table_name, record_pk, action, old_row, new_row, changed_by, changed_at)
```
