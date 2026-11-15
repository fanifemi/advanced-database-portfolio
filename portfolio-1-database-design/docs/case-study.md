# Case Study: PayHaven — Digital Banking & Payments Platform

> **Simulated organisation.** PayHaven is a fictional Nigerian fintech created for this portfolio. All customers, BVNs, phone numbers and document numbers in the data are invented. Bank codes for other banks are used only as reference data.

## 1. Organisation and nature of business

PayHaven is a mobile-first digital bank operating under a (simulated) microfinance banking licence in Nigeria. Customers open wallets with their BVN, fund them by card or bank transfer, and use them to:

- send money to other PayHaven users (instant, free internal transfers),
- send money to accounts at other Nigerian banks through **NIP** (NIBSS Instant Payments), with a fee,
- save into a **Target Savings Vault** that earns interest,
- cash out through agents (withdrawals).

Like every Nigerian financial institution, PayHaven must follow the CBN's **tiered KYC** rules: the more identity evidence a customer provides, the higher their transaction and balance limits.

## 2. Users of the database

| User / system | What they do with the data |
|---|---|
| **Customers** (via mobile app, web, USSD) | Onboard, view balances and statements, save beneficiaries, initiate transfers |
| **KYC officers** | Review identity documents and upgrade customers' KYC tiers |
| **Compliance team** | Freeze accounts, investigate suspicious activity, read the audit trail |
| **Customer support** | Look up customers, transactions and failed transfers to resolve complaints |
| **Finance / reconciliation** | Reconcile wallet balances against the ledger and against NIP settlement |
| **Payment engine** (application service) | Posts transactions and ledger entries, calls NIP, handles reversals |

## 3. Major data stored

- **Customers**: identity (BVN, name, date of birth), contact details, KYC tier and status
- **Addresses** and **KYC documents** (NIN, passport, utility bill …) with review outcome
- **Staff** who review documents
- **Account products**: tier-based limits (daily debit limit, maximum balance, interest rate)
- **Accounts**: customer wallets and savings vaults, plus internal **system (GL) accounts** for NIP settlement, fee income and funding
- **Banks** and saved **beneficiaries** at other banks
- **Transactions**: one row per business event (deposit, transfer, withdrawal, reversal)
- **Ledger entries**: the double-entry debit/credit lines that actually move money
- **External transfer details**: NIP session ID and response code
- **Audit log**: before/after images of every change to customers, accounts and transactions

## 4. Key operations the database supports

1. **Onboard a customer**: register them with a BVN, capture addresses, submit and review KYC documents, open a wallet that matches their tier.
2. **Fund a wallet** (deposit).
3. **Internal transfer** between two PayHaven accounts.
4. **External transfer** to another bank, with a fee, through NIP.
5. **Reverse a failed transfer**: refund amount plus fee when the receiving bank times out.
6. **Withdraw** cash through an agent.
7. **Freeze or close an account** (compliance).
8. **Generate a statement** and **reconcile balances** against the ledger.
9. **Audit**: answer who changed what, and when.

## 5. Why this case study fits the whole portfolio

| Portfolio | How PayHaven exercises it |
|---|---|
| 1. Design & modelling | Rich entities, many business rules, double-entry ledger, tiered limits |
| 2. Query optimisation | Statements, daily-limit checks and reporting over millions of ledger rows |
| 3. Transactions & concurrency | Transfers must be atomic. Concurrent debits on one wallet cause lost updates or overdrafts unless the database controls them |
| 4. NoSQL | Redis for idempotency keys, rate limits and session caching. MongoDB for flexible KYC payloads and device or event logs. A graph model for fraud rings (shared devices and beneficiaries) |
| 5. Distributed / cloud | Strong consistency for balances against eventual consistency for analytics. Read replicas for statements. Sharding by customer |
