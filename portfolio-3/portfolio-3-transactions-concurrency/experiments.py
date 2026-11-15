"""
Portfolio 3 — concurrency experiments on the PayHaven database.

E1  Lost update: 16 threads make 200 cash-outs of N1,000 from a N150,000 wallet, using
    six different concurrency-control strategies.
E2  Deadlock: opposite-direction transfers with naive lock order vs ordered locking.
E3  Isolation anomalies (deterministic two-session interleavings):
      a dirty read · b non-repeatable read · c phantom · d write skew
E4  Idempotency storm: 20 simultaneous requests with the same reference.
E5  Daily-limit race (check-then-act): naive check vs lock-then-check.
E6  Hot-spot contention: internal transfers vs NIP transfers that all lock the same GL rows.

Every experiment prints a report; run with   python experiments.py | tee evidence/02_concurrency_experiments.txt
Prerequisites: Portfolio 1 schema, Portfolio 3 sql/01 and sql/00 scripts.
"""
import random
import statistics
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg import errors

DSN = ""  # uses PGHOST / PGUSER / PGPASSWORD / PGDATABASE environment variables
APP_LATENCY = 0.002  # 2 ms "application think time" between a read and the write that depends on it


def connect(isolation=None, autocommit=False):
    c = psycopg.connect(DSN, autocommit=autocommit)
    c.execute("SET search_path TO payhaven")
    c.commit() if not autocommit else None
    if isolation:
        c.isolation_level = isolation
    return c


admin = connect(autocommit=True)


def q1(sql, *args):
    return admin.execute(sql, args).fetchone()[0]


def new_account(bvn, product, opening):
    return q1("SELECT lab_new_account(%s, %s, %s)", bvn, product, opening)


def balance(acct):
    return q1("SELECT balance FROM accounts WHERE account_number = %s", acct)


def ledger_balance(acct):
    return q1("""SELECT COALESCE(sum(CASE direction WHEN 'CREDIT' THEN amount ELSE -amount END), 0)
                 FROM ledger_entries le JOIN accounts a USING (account_id) WHERE a.account_number = %s""", acct)


def header(title):
    print("\n" + "=" * 100 + f"\n{title}\n" + "=" * 100, flush=True)


def ref():
    return "X-" + uuid.uuid4().hex[:20]


# ======================================================================================
# E1 — Lost update
# ======================================================================================
class Insufficient(Exception):
    pass


def _insert_movement(cur, customer_acct, agent_acct, amount, new_cust_bal, new_agent_bal):
    """Header + two ledger lines with the balances the application *believes* are correct."""
    txn = cur.execute("""INSERT INTO transactions (reference, transaction_type, status, amount, channel, completed_at)
                         VALUES (%s, 'INTERNAL_TRANSFER', 'SUCCESSFUL', %s, 'USSD', now()) RETURNING transaction_id""",
                      (ref(), amount)).fetchone()[0]
    cur.execute("""INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
                   SELECT %s, account_id, 'DEBIT', %s, %s FROM accounts WHERE account_number = %s""",
                (txn, amount, new_cust_bal, customer_acct))
    cur.execute("""INSERT INTO ledger_entries (transaction_id, account_id, direction, amount, balance_after)
                   SELECT %s, account_id, 'CREDIT', %s, %s FROM accounts WHERE account_number = %s""",
                (txn, amount, new_agent_bal, agent_acct))


def w_naive(conn, cust, agent, amt, lock=False):
    """Read balance, think, write absolute new balance (read-modify-write)."""
    with conn.transaction():
        cur = conn.cursor()
        suffix = " FOR UPDATE" if lock else ""
        # lock in account_number order (both accounts are lab accounts, so number order = id order)
        rows = cur.execute(f"SELECT account_number, balance FROM accounts WHERE account_number IN (%s, %s) "
                           f"ORDER BY account_id{suffix}", (cust, agent)).fetchall()
        bal = dict(rows)
        if bal[cust] < amt:
            raise Insufficient()
        time.sleep(APP_LATENCY)
        nc, na = bal[cust] - amt, bal[agent] + amt
        cur.execute("UPDATE accounts SET balance = %s WHERE account_number = %s", (nc, cust))
        cur.execute("UPDATE accounts SET balance = %s WHERE account_number = %s", (na, agent))
        _insert_movement(cur, cust, agent, amt, nc, na)


def w_pessimistic(conn, cust, agent, amt):
    w_naive(conn, cust, agent, amt, lock=True)


def w_atomic(conn, cust, agent, amt):
    """Let the database do the arithmetic; the WHERE clause is the balance check."""
    with conn.transaction():
        cur = conn.cursor()
        time.sleep(APP_LATENCY)
        r = cur.execute("UPDATE accounts SET balance = balance - %s WHERE account_number = %s AND balance >= %s "
                        "RETURNING balance", (amt, cust, amt)).fetchone()
        if r is None:
            raise Insufficient()
        na = cur.execute("UPDATE accounts SET balance = balance + %s WHERE account_number = %s RETURNING balance",
                         (amt, agent)).fetchone()[0]
        _insert_movement(cur, cust, agent, amt, r[0], na)


class VersionConflict(Exception):
    pass


def w_optimistic(conn, cust, agent, amt):
    """No locks while 'thinking'; the write succeeds only if nobody changed the row (version check)."""
    with conn.transaction():
        cur = conn.cursor()
        rows = cur.execute("SELECT account_number, balance, version FROM accounts WHERE account_number IN (%s, %s)",
                           (cust, agent)).fetchall()
        st = {r[0]: (r[1], r[2]) for r in rows}
        if st[cust][0] < amt:
            raise Insufficient()
        time.sleep(APP_LATENCY)
        nc, na = st[cust][0] - amt, st[agent][0] + amt
        for acct, newbal in sorted([(cust, nc), (agent, na)]):
            n = cur.execute("UPDATE accounts SET balance = %s, version = version + 1 "
                            "WHERE account_number = %s AND version = %s", (newbal, acct, st[acct][1])).rowcount
            if n == 0:
                raise VersionConflict()      # rolls back this attempt; caller retries
        _insert_movement(cur, cust, agent, amt, nc, na)


def w_procedure(conn, cust, agent, amt):
    with conn.transaction():
        try:
            conn.execute("SELECT transfer(%s, %s, %s, %s, 'USSD', 'cash-out')", (ref(), cust, agent, amt))
        except errors.RaiseException as e:  # custom SQLSTATE PH001
            raise Insufficient() from e
        except psycopg.Error as e:
            if e.sqlstate == "PH001":
                raise Insufficient() from e
            raise


def run_e1_variant(name, fn, isolation=None, threads=16, requests=200, amt=1000, opening=150000):
    cust = new_account("24000000001", "PH_TIER3", opening)
    agent = new_account("24000000002", "PH_TIER3", 0)
    stats = {"ok": 0, "insufficient": 0, "retries": 0, "failed": 0}  # failed = gave up after 100 attempts
    lock = threading.Lock()
    local = threading.local()

    def worker(_):
        if not hasattr(local, "conn"):
            local.conn = connect(isolation)
        for attempt in range(100):
            try:
                fn(local.conn, cust, agent, amt)
                with lock:
                    stats["ok"] += 1
                return
            except Insufficient:
                with lock:
                    stats["insufficient"] += 1
                return
            except (VersionConflict, errors.SerializationFailure, errors.DeadlockDetected):
                with lock:
                    stats["retries"] += 1
                time.sleep(random.uniform(0, 0.003))  # jittered back-off
        with lock:
            stats["failed"] += 1

    t0 = time.perf_counter()
    with ThreadPoolExecutor(threads) as ex:
        list(ex.map(worker, range(requests)))
    elapsed = time.perf_counter() - t0

    final, led = balance(cust), ledger_balance(cust)
    agent_final, agent_led = balance(agent), ledger_balance(agent)
    expected = opening - stats["ok"] * amt
    correct = (final == expected == led) and (agent_final == agent_led == stats["ok"] * amt)
    row = dict(variant=name, ok=stats["ok"], insufficient=stats["insufficient"], retries=stats["retries"],
               gave_up=stats["failed"], final=final, ledger=led, agent=agent_final, agent_ledger=agent_led,
               overpaid=max(0, stats["ok"] * amt - opening), secs=elapsed, tps=requests / elapsed,
               verdict="CORRECT" if correct else "CORRUPTED")
    # tidy up corrupted lab accounts so the database reconciles again
    if not correct:
        # The ledger itself may show the wallet overdrawn (money was paid out that never existed).
        # Book that loss as a write-off from the funding GL, then rebuild stored balances from the ledger.
        for a in (cust, agent):
            led = ledger_balance(a)
            if led < 0:
                admin.execute("SELECT deposit(%s, %s, %s, 'WEB')", (f"LAB-WRITEOFF-{a}", a, -led))
            admin.execute("SELECT repair_balance_from_ledger(account_id) FROM accounts WHERE account_number = %s", (a,))
    return row


def e1():
    header("E1  LOST UPDATE — 16 threads, 200 cash-outs of N1,000 from a N150,000 wallet "
           "(correct outcome: 150 succeed, 50 rejected, final balance N0)")
    variants = [
        ("1 naive read-modify-write (READ COMMITTED)", w_naive, None),
        ("2 pessimistic: SELECT ... FOR UPDATE", w_pessimistic, None),
        ("3 atomic conditional UPDATE", w_atomic, None),
        ("4 optimistic: version column + retry", w_optimistic, None),
        ("5 naive code under SERIALIZABLE + retry", w_naive, psycopg.IsolationLevel.SERIALIZABLE),
        ("6 production transfer() function", w_procedure, None),
    ]
    rows = [run_e1_variant(n, f, iso) for n, f, iso in variants]
    print(f"{'variant':44} {'ok':>4} {'rej':>4} {'retry':>6} {'gave up':>7} {'wallet stored':>13} {'wallet ledger':>13} "
          f"{'agent stored':>12} {'agent ledger':>12} {'overpaid':>9} {'tps':>5}  verdict")
    for r in rows:
        print(f"{r['variant']:44} {r['ok']:>4} {r['insufficient']:>4} {r['retries']:>6} {r['gave_up']:>7} {r['final']:>13,.0f} "
              f"{r['ledger']:>13,.0f} {r['agent']:>12,.0f} {r['agent_ledger']:>12,.0f} {r['overpaid']:>9,.0f} {r['tps']:>5.0f}  {r['verdict']}")
    print("\nstored = accounts.balance; ledger = sum of ledger lines. They must be equal. "
          "'overpaid' = cash handed out beyond the N150,000 that existed. 'gave up' = request abandoned after 100 retries.")
    return rows


# ======================================================================================
# E2 — Deadlock
# ======================================================================================
def naive_lock_transfer(conn, src, dst, amt):
    """Locks the SOURCE first, then the destination — order depends on direction."""
    with conn.transaction():
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM accounts WHERE account_number = %s FOR UPDATE", (src,))
        time.sleep(0.005)
        cur.execute("SELECT 1 FROM accounts WHERE account_number = %s FOR UPDATE", (dst,))
        nc = cur.execute("UPDATE accounts SET balance = balance - %s WHERE account_number = %s RETURNING balance",
                         (amt, src)).fetchone()[0]
        na = cur.execute("UPDATE accounts SET balance = balance + %s WHERE account_number = %s RETURNING balance",
                         (amt, dst)).fetchone()[0]
        _insert_movement(cur, src, dst, amt, nc, na)


def ordered_transfer(conn, src, dst, amt):
    with conn.transaction():
        conn.execute("SELECT transfer(%s, %s, %s, %s)", (ref(), src, dst, amt))


def run_e2(name, fn, threads=8, per_dir=20):
    x = new_account("24000000001", "PH_TIER3", 1_000_000)
    y = new_account("24000000002", "PH_TIER3", 1_000_000)
    jobs = [(x, y)] * per_dir + [(y, x)] * per_dir
    random.shuffle(jobs)
    stats = {"ok": 0, "deadlocks": 0}
    lock = threading.Lock()
    local = threading.local()

    def worker(job):
        if not hasattr(local, "conn"):
            local.conn = connect()
        while True:
            try:
                fn(local.conn, job[0], job[1], 100)
                with lock:
                    stats["ok"] += 1
                return
            except errors.DeadlockDetected:
                with lock:
                    stats["deadlocks"] += 1      # the victim is rolled back; retry it

    t0 = time.perf_counter()
    with ThreadPoolExecutor(threads) as ex:
        list(ex.map(worker, jobs))
    el = time.perf_counter() - t0
    ok = balance(x) + balance(y) == 2_000_000 and balance(x) == ledger_balance(x)
    return dict(variant=name, ok=stats["ok"], deadlocks=stats["deadlocks"], secs=el, consistent=ok)


def e2():
    header("E2  DEADLOCK — 8 threads, 40 transfers of N100 between accounts X and Y in BOTH directions")
    rows = [run_e2("naive: lock source first, then destination", naive_lock_transfer),
            run_e2("transfer(): lock both in account_id order", ordered_transfer)]
    print(f"{'variant':46} {'completed':>9} {'deadlocks detected':>19} {'elapsed s':>10}  balances consistent")
    for r in rows:
        print(f"{r['variant']:46} {r['ok']:>9} {r['deadlocks']:>19} {r['secs']:>10.2f}  {r['consistent']}")
    print("\nEach deadlock costs ~deadlock_timeout (1 s) before PostgreSQL detects the cycle and aborts one victim (SQLSTATE 40P01).")
    return rows


# ======================================================================================
# E3 — Isolation anomalies (two sessions, deterministic interleaving)
# ======================================================================================
L = psycopg.IsolationLevel


def e3():
    header("E3  ISOLATION ANOMALIES — two sessions, scripted interleaving")
    acct = new_account("24000000001", "PH_TIER3", 50000)
    other = new_account("24000000002", "PH_TIER3", 0)
    out = []

    # ---- a. dirty read
    t1, t2 = connect(), connect(L.READ_UNCOMMITTED)
    t1.execute("UPDATE accounts SET balance = balance + 999999 WHERE account_number = %s", (acct,))  # uncommitted
    seen = t2.execute("SELECT balance FROM accounts WHERE account_number = %s", (acct,)).fetchone()[0]
    t1.rollback(); t2.rollback()
    out.append(("a. Dirty read", "READ UNCOMMITTED", f"T2 saw {seen:,.2f} while T1 had an uncommitted +999,999",
                "PREVENTED (PostgreSQL treats READ UNCOMMITTED as READ COMMITTED)" if seen == 50000 else "OCCURRED"))

    # ---- b. non-repeatable read
    for level in (L.READ_COMMITTED, L.REPEATABLE_READ):
        t1, t2 = connect(level), connect()
        r1 = t1.execute("SELECT balance FROM accounts WHERE account_number = %s", (acct,)).fetchone()[0]
        with t2.transaction():
            t2.execute("SELECT deposit(%s, %s, 5000)", (ref(), acct))
        r2 = t1.execute("SELECT balance FROM accounts WHERE account_number = %s", (acct,)).fetchone()[0]
        t1.commit()
        out.append(("b. Non-repeatable read", level.name, f"T1 read {r1:,.2f}, T2 committed a N5,000 deposit, T1 re-read {r2:,.2f}",
                    "OCCURRED" if r1 != r2 else "PREVENTED (snapshot)"))

    # ---- c. phantom
    sql = ("SELECT count(*) FROM ledger_entries le JOIN accounts a USING (account_id) "
           "WHERE a.account_number = %s AND le.created_at >= date_trunc('day', now())")
    for level in (L.READ_COMMITTED, L.REPEATABLE_READ):
        t1, t2 = connect(level), connect()
        c1 = t1.execute(sql, (acct,)).fetchone()[0]
        with t2.transaction():
            t2.execute("SELECT transfer(%s, %s, %s, 1000)", (ref(), acct, other))
        c2 = t1.execute(sql, (acct,)).fetchone()[0]
        t1.commit()
        out.append(("c. Phantom read", level.name, f"T1 counted {c1} ledger lines today, T2 inserted one, T1 recounted {c2}",
                    "OCCURRED" if c1 != c2 else "PREVENTED (snapshot)"))

    for r in out:
        print(f"{r[0]:24} {r[1]:18} {r[2]:80} {r[3]}")

    # ---- d. write skew
    print("\nd. WRITE SKEW — rule: a Tier-2 customer's COMBINED debits today across all accounts must not exceed N200,000.")
    print("   Wallet sends N150,000 and savings vault sends N90,000 at the same moment (combined N240,000).")
    print("   Each session checks the combined total, sees room, then debits a DIFFERENT row — no row is written by both.\n")
    check_sql = """SELECT COALESCE(sum(le.amount), 0) FROM ledger_entries le JOIN accounts a USING (account_id)
                   WHERE a.customer_id = %s AND le.direction = 'DEBIT' AND le.created_at >= date_trunc('day', now())"""
    for label, level, lock_customer in [("REPEATABLE READ", L.REPEATABLE_READ, False),
                                        ("SERIALIZABLE", L.SERIALIZABLE, False),
                                        ("READ COMMITTED + lock customer row", L.READ_COMMITTED, True)]:
        bvn = "25" + str(random.randint(10**8, 10**9 - 1))
        cid = q1("""INSERT INTO customers (bvn, first_name, last_name, email, phone, date_of_birth, kyc_tier, status)
                    VALUES (%s, 'Skew', 'Test', %s, %s, '1990-01-01', 2, 'ACTIVE') RETURNING customer_id""",
                 bvn, f"skew{bvn}@payhaven.example", "+2348" + bvn[2:11])
        wallet = new_account(bvn, "PH_TIER2", 200000)
        vault = new_account(bvn, "PH_SAVE", 200000)
        dst1 = new_account("24000000002", "PH_TIER3", 0)
        dst2 = new_account("24000000002", "PH_TIER3", 0)
        sessions = [(connect(level), wallet, dst1, 150000), (connect(level), vault, dst2, 90000)]
        result = []
        # step 1: both sessions run the check (optionally locking the customer row)
        checks = []
        for i, (c, src, dst, amt) in enumerate(sessions):
            if lock_customer:
                if i == 1:
                    # session 2 would block here until session 1 commits; run it after
                    checks.append(None)
                    continue
                c.execute("SELECT 1 FROM customers WHERE customer_id = %s FOR UPDATE", (cid,))
            checks.append(c.execute(check_sql, (cid,)).fetchone()[0])
        # step 2: each session debits if the check passed, then commits
        for i, (c, src, dst, amt) in enumerate(sessions):
            try:
                if checks[i] is None:   # locked variant: session 2 now acquires the lock and checks
                    c.execute("SELECT 1 FROM customers WHERE customer_id = %s FOR UPDATE", (cid,))
                    checks[i] = c.execute(check_sql, (cid,)).fetchone()[0]
                if checks[i] + amt > 200000:
                    c.rollback()
                    result.append(f"S{i+1} saw N{checks[i]:,.0f} already debited -> REJECTED by check")
                    continue
                c.execute("SELECT transfer(%s, %s, %s, %s)", (ref(), src, dst, amt))
                c.commit()
                result.append(f"S{i+1} saw N{checks[i]:,.0f} -> debited N{amt:,} COMMITTED")
            except errors.SerializationFailure as e:
                c.rollback()
                result.append(f"S{i+1} ABORTED by database: {e.sqlstate} {str(e).splitlines()[0][:60]}")
        total = q1(check_sql, cid)
        verdict = "RULE VIOLATED (write skew)" if total > 200000 else "rule held"
        print(f"   {label:36} | " + " | ".join(result) + f" | combined debited N{total:,.0f} -> {verdict}")
    return out


# ======================================================================================
# E4 — Idempotency storm
# ======================================================================================
def e4():
    header("E4  IDEMPOTENCY — 20 threads submit the SAME transfer (same reference) at the same instant")
    src = new_account("24000000001", "PH_TIER3", 100000)
    dst = new_account("24000000002", "PH_TIER3", 0)
    r = ref()
    barrier = threading.Barrier(20)
    ids, errs = [], []

    def worker(_):
        c = connect()
        barrier.wait()
        try:
            with c.transaction():
                ids.append(c.execute("SELECT transfer(%s, %s, %s, 25000)", (r, src, dst)).fetchone()[0])
        except psycopg.Error as e:
            errs.append(e.sqlstate)
        c.close()

    with ThreadPoolExecutor(20) as ex:
        list(ex.map(worker, range(20)))
    debits = q1("""SELECT count(*) FROM ledger_entries le JOIN transactions t USING (transaction_id)
                   WHERE t.reference = %s AND le.direction = 'DEBIT'""", r)
    print(f"requests: 20 · distinct transaction ids returned: {len(set(ids))} · errors: {len(errs)} {set(errs) or ''}")
    print(f"debit lines for the reference: {debits} · source balance: {balance(src):,.2f} (expected 75,000.00) "
          f"· destination: {balance(dst):,.2f} (expected 25,000.00)")
    print("VERDICT:", "CORRECT — money moved exactly once" if debits == 1 and balance(src) == 75000 else "WRONG")


# ======================================================================================
# E5 — Daily limit race (check-then-act)
# ======================================================================================
def e5():
    header("E5  DAILY-LIMIT RACE — 10 concurrent N30,000 transfers from a Tier-2 wallet (limit N200,000/day)")
    print("Correct outcome: 6 succeed (N180,000), 4 rejected — the 7th would make N210,000.\n")

    def naive(conn, src, dst, amt):
        with conn.transaction():
            today = conn.execute("""SELECT COALESCE(sum(amount),0) FROM ledger_entries le JOIN accounts a USING (account_id)
                                    WHERE a.account_number = %s AND direction='DEBIT'
                                      AND le.created_at >= date_trunc('day', now())""", (src,)).fetchone()[0]
            if today + amt > 200000:
                raise Insufficient()
            time.sleep(APP_LATENCY)
            nc = conn.execute("UPDATE accounts SET balance = balance - %s WHERE account_number = %s RETURNING balance",
                              (amt, src)).fetchone()[0]
            na = conn.execute("UPDATE accounts SET balance = balance + %s WHERE account_number = %s RETURNING balance",
                              (amt, dst)).fetchone()[0]
            _insert_movement(conn.cursor(), src, dst, amt, nc, na)

    def proc(conn, src, dst, amt):
        with conn.transaction():
            try:
                conn.execute("SELECT transfer(%s, %s, %s, %s)", (ref(), src, dst, amt))
            except psycopg.Error as e:
                if e.sqlstate == "PH002":
                    raise Insufficient() from e
                raise

    for name, fn in [("naive: check today's total, then debit", naive),
                     ("transfer(): lock account, then check", proc)]:
        src = new_account("24000000003", "PH_TIER2", 400000)
        dst = new_account("24000000002", "PH_TIER3", 0)
        res = {"ok": 0, "rej": 0}
        lk = threading.Lock()
        barrier = threading.Barrier(10)

        def worker(_):
            c = connect()
            barrier.wait()
            try:
                fn(c, src, dst, 30000)
                with lk:
                    res["ok"] += 1
            except Insufficient:
                with lk:
                    res["rej"] += 1
            c.close()

        with ThreadPoolExecutor(10) as ex:
            list(ex.map(worker, range(10)))
        debited = 400000 - balance(src)
        print(f"{name:42} succeeded {res['ok']:>2} · rejected {res['rej']:>2} · debited today N{debited:,.0f} "
              f"-> {'LIMIT BREACHED' if debited > 200000 else 'limit respected'}")


# ======================================================================================
# E6 — Hot spot
# ======================================================================================
def e6():
    header("E6  HOT-SPOT CONTENTION — 8 threads x 40 transfers")
    bvn_a = "24000000001"
    ben = q1("SELECT beneficiary_id FROM beneficiaries b JOIN customers c USING (customer_id) WHERE c.bvn = %s", bvn_a)
    results = []
    for name in ("internal transfers (each thread uses its own accounts)",
                 "NIP transfers (all threads lock the SAME settlement + fee GL rows)"):
        pairs = [(new_account(bvn_a, "PH_TIER3", 1_000_000), new_account("24000000002", "PH_TIER3", 0)) for _ in range(8)]
        lat = []
        lk = threading.Lock()

        def worker(i):
            c = connect()
            src, dst = pairs[i]
            for _ in range(40):
                t0 = time.perf_counter()
                with c.transaction():
                    if name.startswith("internal"):
                        c.execute("SELECT transfer(%s, %s, %s, 500)", (ref(), src, dst))
                    else:
                        c.execute("SELECT nip_transfer(%s, %s, %s, 500)", (ref(), src, ben))
                with lk:
                    lat.append((time.perf_counter() - t0) * 1000)
            c.close()

        t0 = time.perf_counter()
        with ThreadPoolExecutor(8) as ex:
            list(ex.map(worker, range(8)))
        el = time.perf_counter() - t0
        lat.sort()
        results.append((name, 320 / el, statistics.median(lat), lat[int(len(lat) * 0.95)]))
    for n, tps, p50, p95 in results:
        print(f"{n:70} {tps:7.0f} tx/s   p50 {p50:6.1f} ms   p95 {p95:6.1f} ms")


if __name__ == "__main__":
    print(f"PayHaven concurrency experiments — PostgreSQL {q1('SHOW server_version')}, "
          f"default isolation {q1('SHOW default_transaction_isolation')}, deadlock_timeout {q1('SHOW deadlock_timeout')}")
    e1()
    e2()
    e3()
    e4()
    e5()
    e6()
    header("FINAL CHECK — every lab account reconciles (stored balance = ledger balance)")
    bad = q1("""SELECT count(*) FROM (SELECT a.account_id, a.balance,
                   COALESCE(sum(CASE le.direction WHEN 'CREDIT' THEN le.amount ELSE -le.amount END),0) AS l
                FROM accounts a LEFT JOIN ledger_entries le USING (account_id)
                WHERE a.account_number LIKE '4%%' GROUP BY a.account_id) x WHERE balance <> l""")
    print(f"lab accounts out of balance: {bad}")
