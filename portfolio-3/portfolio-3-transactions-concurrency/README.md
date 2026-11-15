# Portfolio 3 — Transactions and Concurrency

**Case study:** PayHaven (see Portfolio 1). **DBMS:** PostgreSQL 16, default isolation READ COMMITTED.

Moving money is the core operation of a bank, so it has to be **atomic** (all or nothing), **isolated** (correct while thousands run at once), **consistent** (balances always match the ledger) and **durable**. This portfolio builds PayHaven's transfer functions, then tries to break them with real concurrent workloads, comparing them against the naive designs a developer might write first.

## 1. What was built — `sql/01_transfer_procedures.sql`

| Function | Purpose |
|---|---|
| `deposit(ref, account, amount)` | Fund a wallet (Funding GL → customer) |
| `transfer(ref, from, to, amount)` | Internal transfer |
| `nip_transfer(ref, from, beneficiary, amount)` | External transfer with NIP fee (customer → settlement GL + fee GL) |
| `reverse_transaction(ref, reason)` | Refund by mirroring every ledger line |
| `repair_balance_from_ledger(account_id)` | Operations tool that rebuilds a corrupted stored balance from the ledger |

**Concurrency design of `transfer()`:**
1. **Idempotency first.** `INSERT … ON CONFLICT (reference) DO NOTHING`. If a request with the same reference is already in flight, the insert *waits* for it, and the retry then returns the existing transaction id without moving money.
2. **Pessimistic locking with a fixed order.** `SELECT … FOR UPDATE` on both accounts, always in ascending `account_id` order. That makes a deadlock between two transfers impossible.
3. **Lock, then read.** Balance and daily-limit checks run *after* the locks are taken. Under READ COMMITTED each statement sees the latest committed data, so the checks are exact.
4. **Atomicity.** The function runs inside the caller's transaction, so any `RAISE` (insufficient funds `PH001`, daily limit `PH002`, frozen account `PH003`, and so on) undoes everything, including the transaction header that was already inserted.
5. **Integrity backstop.** The Portfolio 1 constraints still apply: the deferred double-entry trigger (R4), the no-overdraft CHECK, the frozen-account trigger (R3) and the reversal rules (R6).

**Why READ COMMITTED with explicit locks, rather than SERIALIZABLE for everything?** The conflicts in a transfer are known in advance: two specific balance rows. Locking exactly those rows gives correctness *without retries*. E1 shows this is about 3× the throughput of SERIALIZABLE-with-retry under contention. SERIALIZABLE is kept for rules that span rows nobody writes in common (E3d).

## 2. Atomicity demo — `sql/02_atomicity_demo.sql`

Output: [evidence/01_atomicity_demo.txt](evidence/01_atomicity_demo.txt)

| Part | Scenario | Outcome |
|---|---|---|
| A | COMMIT a ₦30,000 transfer | Balances 70,000 / 30,000. Two ledger lines, debit = credit |
| B | ₦500,000 transfer fails with insufficient funds *after* the header row was inserted | `ROLLBACK`. **0 header rows left behind**, balances unchanged |
| C | Transfer succeeds, then the app issues `ROLLBACK` | Inside the transaction the balances showed 60,000 / 40,000. After rollback they're back to 70,000 / 30,000 |
| D | Payroll to 4 staff, #3 has a FROZEN account | `ROLLBACK TO SAVEPOINT pay3` undoes only #3. **3 paid, 1 skipped, batch committed** |
| E | Client retries the same request 3 times, then it's reversed twice | Same transaction id each time, **1 debit**. Reversal refunds the money. The second reversal is rejected by trigger R6 |

Every account reconciles afterwards (stored balance = ledger balance).

## 3. Concurrency experiments — `experiments.py`

Real parallel threads, each with its own database connection. Output: [evidence/02_concurrency_experiments.txt](evidence/02_concurrency_experiments.txt)

### E1 — Lost update: 16 threads, 200 cash-outs of ₦1,000 from a ₦150,000 wallet
The correct outcome is 150 succeed, 50 are rejected, and the wallet ends at ₦0.

| Strategy | OK | Rejected | Retries | Gave up | Wallet (stored / ledger) | Overpaid | tx/s | Verdict |
|---|---:|---:|---:|---:|---|---:|---:|---|
| 1. Naive read-modify-write | **200** | 0 | 0 | 0 | **137,000 / −50,000** | **₦50,000** | 438 | ❌ CORRUPTED |
| 2. Pessimistic `FOR UPDATE` | 150 | 50 | 0 | 0 | 0 / 0 | 0 | 286 | ✅ |
| 3. Atomic conditional `UPDATE … WHERE balance >= x` | 150 | 50 | 0 | 0 | 0 / 0 | 0 | 571 | ✅ |
| 4. Optimistic (version column + retry) | 150 | 45 | 2,173 | 5 | 0 / 0 | 0 | 188 | ✅ but 5 requests abandoned |
| 5. Naive code under SERIALIZABLE + retry | 150 | 44 | 2,202 | 6 | 0 / 0 | 0 | 174 | ✅ but 6 requests abandoned |
| 6. **Production `transfer()`** | 150 | 50 | 0 | 0 | 0 / 0 | 0 | **563** | ✅ |

**The anomaly.** In the naive version each thread reads the balance, waits 2 ms (a normal app round-trip), then writes `balance = old − 1000`. Two threads that read the same old value both write the same new value, so one withdrawal is **lost** from the stored balance. All 200 cash-outs were approved and ₦200,000 was paid out of a ₦150,000 wallet. The stored balance (₦137,000) no longer matches the ledger (−₦50,000). The Portfolio 1 reconciliation view catches exactly this kind of incident.

**The fixes compared:**
- **Pessimistic locking** (2, 6) blocks competing writers, so it's correct with no retries. `transfer()` is twice as fast as variant 2 because variant 2 holds its locks during the 2 ms application round-trip, while `transfer()` holds them only for the work done inside the database. *Keep transactions that hold locks short.*
- **Atomic UPDATE** (3) is the fastest pattern for a single row, because the check and the write are one statement.
- **Optimistic** (4) and **SERIALIZABLE** (5) are correct but do worst under *high contention on one row*. Over 2,000 retries were needed and some requests ran out of retries. Optimistic concurrency suits low-contention data, such as editing a customer profile, not a busy wallet.

### E2 — Deadlock: 8 threads, 40 transfers between X and Y in both directions
| Variant | Deadlocks | Elapsed |
|---|---:|---:|
| Naive: lock source, then destination | **295** | 111.7 s |
| `transfer()`: lock in account_id order | **0** | 0.11 s |

X→Y locks X then Y. Y→X locks Y then X. Each holds one lock and waits for the other, which is a **cycle**. PostgreSQL detects it after `deadlock_timeout` (1 s), aborts one victim (SQLSTATE `40P01`) and the app retries. The result was still correct, but 1,000× slower. A **global lock order** removes the cycle entirely.

### E3 — Isolation levels and anomalies
| Anomaly | READ COMMITTED | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| a. Dirty read | Prevented (PostgreSQL never allows it, even at READ UNCOMMITTED) | Prevented | Prevented |
| b. Non-repeatable read | **Occurred** (50,000 → 55,000 within one transaction) | Prevented (snapshot) | Prevented |
| c. Phantom read | **Occurred** (3 → 4 ledger lines) | Prevented (snapshot) | Prevented |
| d. **Write skew** | — | **Occurred** | **Prevented** (`40001`, one session aborted) |

**d. Write skew, a real fintech example.** The rule is that a Tier-2 customer's *combined* debits across all their accounts must not exceed ₦200,000 a day. The wallet sends ₦150,000 and the savings vault sends ₦90,000 at the same moment. Each session checks the combined total, sees ₦0, and debits a *different* account. Under REPEATABLE READ both snapshots are internally consistent and no row is written by both, so **both commit and ₦240,000 leaves**. SERIALIZABLE (Serializable Snapshot Isolation) detects the read/write dependency cycle and aborts one session. The alternative fix at READ COMMITTED is to **materialise the conflict**: both sessions lock the *customer* row first, so they queue, and the second one sees the first's debit and rejects itself.

### E4 — Idempotency storm
20 threads submit the *same* transfer, with the same reference, at the same instant (synchronised with a barrier). Result: 1 transaction id, **1 debit**, 0 errors, balances exactly right. The UNIQUE constraint on `reference` together with `ON CONFLICT` makes "exactly once" a database guarantee, not just application logic.

### E5 — Daily-limit race (check-then-act)
10 concurrent ₦30,000 transfers from a wallet with a ₦200,000 daily limit.

| Variant | Succeeded | Debited | Result |
|---|---:|---:|---|
| Naive: `SELECT` today's total, then debit | 10 | ₦300,000 | ❌ **limit breached** |
| `transfer()`: lock account, then check | 6 | ₦180,000 | ✅ |

This is a classic **TOCTOU** (time-of-check to time-of-use) bug. All ten naive requests checked before any of them wrote. Taking the account row lock before the check serialises them.

### E6 — Hot-spot contention
| Workload (8 threads × 40) | Throughput | p50 | p95 |
|---|---:|---:|---:|
| Internal transfers, independent accounts | 1,267 tx/s | 4.9 ms | 9.9 ms |
| NIP transfers, all locking the same settlement and fee GL rows | 569 tx/s | 8.8 ms | 37.6 ms |

Every external transfer credits the *same* two GL accounts, so their row locks serialise the whole workload, and the p95 latency is about 4× worse. This is the main scalability limit of the design. Real banks use one of three fixes: **split the GL row into N sub-accounts** (pick one at random and sum them for reporting), **post GL entries asynchronously** in batches, or keep GL balances out of the hot path entirely and derive them from the ledger. Portfolio 5 looks at the distributed version of this problem.

## 4. Summary: choosing a concurrency-control mechanism

| Situation in PayHaven | Mechanism | Evidence |
|---|---|---|
| Debit/credit specific accounts | Pessimistic row locks in a global order, at READ COMMITTED | E1, E2, E5 |
| Single-row counter or balance change | Atomic conditional UPDATE | E1 (3) |
| Low-contention edits (profile, settings) | Optimistic version column | E1 (4) |
| Rules across rows that aren't written in common | SERIALIZABLE + retry, or lock a common parent row | E3d |
| Client retries / duplicate submissions | Idempotency key (UNIQUE + ON CONFLICT) | E4, Part E |
| Partial failure in a batch | Savepoints | Part D |

## 5. How to reproduce

```bash
# Prerequisite: Portfolio 1 (and optionally Portfolio 2's indexes) loaded
cd portfolio-3-transactions-concurrency
psql -h localhost -U postgres -d payhaven -f sql/01_transfer_procedures.sql
psql -h localhost -U postgres -d payhaven -f sql/00_setup_lab.sql
psql -h localhost -U postgres -d payhaven -f sql/02_atomicity_demo.sql > evidence/01_atomicity_demo.txt 2>&1
pip install "psycopg[binary]"
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=payhaven python experiments.py | tee evidence/02_concurrency_experiments.txt
```
The run takes about 2–3 minutes; most of that is E2's naive deadlocks, each waiting about 1 s. Exact numbers vary between runs and machines because thread scheduling isn't deterministic, but the verdicts are the same every time.
