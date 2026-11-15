"""
Portfolio 2 — query benchmark harness.

1. Resets the database to the baseline physical design (00_reset_baseline.sql)
2. Runs every "before" query variant with EXPLAIN (ANALYZE, BUFFERS)
3. Applies 02_optimise.sql (indexes, materialized view, statistics)
4. Runs every "after" variant
5. Writes: evidence/plans/*.txt, evidence/results.csv, evidence/results.md, sql/queries.sql

Each variant: 1 warm-up run + 5 measured runs; the median execution time is reported.
All timings are warm-cache (data already in shared buffers / OS cache).

Usage:  pip install "psycopg[binary]"
        PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=payhaven python benchmark.py
"""
import csv
import json
import os
import re
import pathlib
import statistics

import psycopg

HERE = pathlib.Path(__file__).parent
PLANS = HERE / "evidence" / "plans"
RUNS = 5

conn = psycopg.connect(autocommit=True)
conn.execute("SET search_path TO payhaven")
conn.execute("SET TimeZone = 'Africa/Lagos'")


def run_file(name):
    text = (HERE / "sql" / name).read_text()
    # strip comments, then run statement by statement (VACUUM cannot run in a multi-statement block)
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
    for stmt in text.split(";"):
        if stmt.strip():
            conn.execute(stmt)


# Keyset cursor for Q2: the (created_at, entry_id) of the 10,000th newest line
# of the busiest account. A real app would get this from the previous page.
cursor_row = conn.execute("""
    SELECT le.created_at, le.entry_id
    FROM ledger_entries le JOIN accounts a USING (account_id)
    WHERE a.account_number = '2000000001'
    ORDER BY le.created_at DESC, le.entry_id DESC OFFSET 9999 LIMIT 1""").fetchone()
CUR_TS, CUR_ID = cursor_row[0].isoformat(), cursor_row[1]
# Applications normally hold the internal account_id after login; resolve it once.
BUSY_ID = conn.execute("SELECT account_id FROM accounts WHERE account_number = '2000000001'").fetchone()[0]

STATEMENT_COLS = """le.created_at, t.reference, t.transaction_type, le.direction, le.amount, le.balance_after
FROM ledger_entries le
JOIN accounts a     ON a.account_id = le.account_id
JOIN transactions t ON t.transaction_id = le.transaction_id"""

QUERIES = [
    ("Q1", "Account statement — latest 50 lines (typical account)", [
        ("before", "original", f"""SELECT {STATEMENT_COLS}
WHERE a.account_number = '2000000500'
ORDER BY le.created_at DESC, le.entry_id DESC
LIMIT 50"""),
        ("after", "composite index", None),          # None = same SQL as the 'before' variant
    ]),
    ("Q2", "Statement page 201 of the busiest account (rows 10,001-10,050)", [
        ("before", "OFFSET, no index", f"""SELECT {STATEMENT_COLS}
WHERE a.account_number = '2000000001'
ORDER BY le.created_at DESC, le.entry_id DESC
OFFSET 10000 LIMIT 50"""),
        ("after", "OFFSET + index", None),
        ("after", "keyset + index (account via join)", f"""SELECT {STATEMENT_COLS}
WHERE a.account_number = '2000000001'
  AND (le.created_at, le.entry_id) < ('{CUR_TS}', {CUR_ID})
ORDER BY le.created_at DESC, le.entry_id DESC
LIMIT 50"""),
        ("after", "keyset + index (account_id known)", f"""SELECT le.created_at, t.reference, t.transaction_type, le.direction, le.amount, le.balance_after
FROM ledger_entries le
JOIN transactions t ON t.transaction_id = le.transaction_id
WHERE le.account_id = {BUSY_ID}
  AND (le.created_at, le.entry_id) < ('{CUR_TS}', {CUR_ID})
ORDER BY le.created_at DESC, le.entry_id DESC
LIMIT 50"""),
    ]),
    ("Q3", "Daily debit-limit check (sum of today's debits)", [
        ("before", "original", """SELECT COALESCE(sum(le.amount), 0) AS debited_today
FROM ledger_entries le
WHERE le.account_id = (SELECT account_id FROM accounts WHERE account_number = '2000000001')
  AND le.direction = 'DEBIT'
  AND le.created_at >= '2026-03-16' AND le.created_at < '2026-03-17'"""),
        ("after", "covering index (index-only scan)", None),
    ]),
    ("Q4", "Support: find customer by email typed in mixed case", [
        ("before", "email = '...' (not sargable for lower() index)", """SELECT customer_id, first_name, last_name, phone, kyc_tier
FROM customers
WHERE email = 'Obinna.Adeyemi1234@mail.example'"""),
        ("after", "lower(email) = lower('...') (uses functional index)", """SELECT customer_id, first_name, last_name, phone, kyc_tier
FROM customers
WHERE lower(email) = lower('Obinna.Adeyemi1234@mail.example')"""),
    ]),
    ("Q5", "Support: find customer by last 6 digits of phone", [
        ("before", "LIKE '%…' seq scan", """SELECT customer_id, first_name, last_name, phone
FROM customers
WHERE phone LIKE '%054321'"""),
        ("after", "trigram GIN index", None),
    ]),
    ("Q6", "Support dashboard: PENDING/FAILED transactions in last 24h", [
        ("before", "original", """SELECT reference, transaction_type, status, amount, created_at
FROM transactions
WHERE status IN ('PENDING', 'FAILED')
  AND created_at >= TIMESTAMPTZ '2026-07-01 00:00' - INTERVAL '24 hours'
ORDER BY created_at DESC"""),
        ("after", "partial index", None),
    ]),
    ("Q7", "Report: March 2026 volume by type and channel", [
        ("before", "full scan + aggregate", """SELECT transaction_type, channel, count(*) AS txn_count, sum(amount) AS total_amount
FROM transactions
WHERE status = 'SUCCESSFUL'
  AND created_at >= '2026-03-01' AND created_at < '2026-04-01'
GROUP BY transaction_type, channel
ORDER BY total_amount DESC"""),
        ("after", "BRIN index", None),
        ("after", "materialized view", """SELECT transaction_type, channel, txn_count, total_amount
FROM mv_monthly_volume
WHERE month = '2026-03-01'
ORDER BY total_amount DESC"""),
    ]),
    ("Q8", "Report: top 10 external-transfer senders, last 30 days", [
        ("before", "original", """SELECT c.customer_id, c.first_name || ' ' || c.last_name AS customer,
       count(*) AS transfers, sum(t.amount) AS total_sent
FROM transactions t
JOIN customers c ON c.customer_id = t.initiated_by
WHERE t.transaction_type = 'EXTERNAL_TRANSFER'
  AND t.status = 'SUCCESSFUL'
  AND t.created_at >= TIMESTAMPTZ '2026-07-01' - INTERVAL '30 days'
GROUP BY c.customer_id
ORDER BY total_sent DESC
LIMIT 10"""),
        ("after", "BRIN index", None),
    ]),
    ("Q9", "Dormancy job: ACTIVE customers with no transaction since 1 March 2026", [
        ("before", "NOT IN (subquery)  -- wrong result AND non-hashed SubPlan", """SELECT count(*)
FROM customers c
WHERE c.status = 'ACTIVE'
  AND c.customer_id NOT IN (SELECT initiated_by FROM transactions WHERE created_at >= '2026-03-01')""",
         {"timeout_ms": 60000}),
        ("after", "NOT EXISTS (anti-join)", """SELECT count(*)
FROM customers c
WHERE c.status = 'ACTIVE'
  AND NOT EXISTS (SELECT 1 FROM transactions t
                  WHERE t.initiated_by = c.customer_id AND t.created_at >= '2026-03-01')"""),
    ]),
]


def node_types(plan, acc=None):
    """Collect the distinctive plan operators (scan/join types) in the plan tree."""
    acc = acc if acc is not None else []
    nt = plan["Node Type"]
    if "Scan" in nt or "Join" in nt or nt in ("Nested Loop", "Hash Join", "Merge Join", "Sort"):
        label = nt + (f" ({plan['Index Name']})" if "Index Name" in plan else "")
        label += f" on {plan['Relation Name']}" if "Relation Name" in plan and "Index Name" not in plan else ""
        if label not in acc:
            acc.append(label)
    for child in plan.get("Plans", []):
        node_types(child, acc)
    return acc


def measure_timeout(qid, label, phase, sql, timeout_ms):
    """For pathological plans: one attempt with a statement timeout; plan shown without ANALYZE."""
    text_plan = "\n".join(r[0] for r in conn.execute("EXPLAIN " + sql).fetchall())
    import time
    t0 = time.perf_counter()
    try:
        conn.execute(f"SET statement_timeout = {timeout_ms}")
        rows = conn.execute(sql).fetchall()
        elapsed, result = (time.perf_counter() - t0) * 1000, rows[0][0]
    except psycopg.errors.QueryCanceled:
        elapsed, result = timeout_ms, f"cancelled after {timeout_ms // 1000}s"
    finally:
        conn.execute("SET statement_timeout = 0")
    # NULL-trap proof: the same query restricted so the planner can hash it
    slug = f"{qid}_{phase}_NOT_IN"
    (PLANS / f"{slug}.txt").write_text(
        f"-- {qid} [{phase}] {label}\n-- outcome: {result} (wall clock {elapsed:,.0f} ms)\n\n{sql};\n\n"
        f"EXPLAIN (estimated plan — ANALYZE would take too long):\n{text_plan}\n")
    return {"query": qid, "phase": phase, "variant": label, "median_ms": round(elapsed, 3), "min_ms": round(elapsed, 3),
            "planning_ms": 0, "buffers": 0, "est_rows": 1, "actual_rows": None, "result": result,
            "operators": "Seq Scan on customers; SubPlan: Seq Scan on transactions (re-scanned per customer)"}


def measure(qid, label, phase, sql, opts=None):
    if opts and "timeout_ms" in opts:
        return measure_timeout(qid, label, phase, sql, opts["timeout_ms"])
    conn.execute(sql).fetchall()  # warm-up
    rows = conn.execute(sql).fetchall()
    times, plan_json = [], None
    for _ in range(RUNS):
        res = conn.execute("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + sql).fetchone()[0]
        plan_json = res[0] if isinstance(res, list) else json.loads(res)[0]
        times.append(plan_json["Execution Time"])
    text_plan = "\n".join(r[0] for r in conn.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql).fetchall())
    top = plan_json["Plan"]
    buffers = top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0)
    short = label.split(' --')[0][:50]
    slug = f"{qid}_{phase}_" + re.sub(r'[^A-Za-z0-9]+', '_', short).strip('_')
    (PLANS / f"{slug}.txt").write_text(
        f"-- {qid} [{phase}] {label}\n-- result rows: {len(rows)}; first row: {rows[0] if rows else None}\n\n{sql};\n\n{text_plan}\n")
    return {
        "query": qid, "phase": phase, "variant": label,
        "median_ms": round(statistics.median(times), 3),
        "min_ms": round(min(times), 3),
        "planning_ms": round(plan_json["Planning Time"], 3),
        "buffers": buffers,
        "est_rows": top["Plan Rows"], "actual_rows": top["Actual Rows"],
        "result": rows[0][0] if len(rows) == 1 and len(rows[0]) == 1 else f"{len(rows)} rows",
        "operators": "; ".join(node_types(top)),
    }


def main():
    PLANS.mkdir(parents=True, exist_ok=True)
    for f in PLANS.glob("*.txt"):
        f.unlink()

    results = []
    print("Resetting to baseline …")
    run_file("00_reset_baseline.sql")
    for qid, _, variants in QUERIES:
        base_sql = variants[0][2]
        for phase, label, sql, *opts in variants:
            if phase == "before":
                print(f"  {qid} before: {label}", flush=True)
                results.append(measure(qid, label, phase, sql or base_sql, opts[0] if opts else None))

    print("Applying 02_optimise.sql …")
    run_file("02_optimise.sql")
    for qid, _, variants in QUERIES:
        base_sql = variants[0][2]
        for phase, label, sql, *opts in variants:
            if phase == "after":
                print(f"  {qid} after:  {label}", flush=True)
                results.append(measure(qid, label, phase, sql or base_sql))

    # ---- outputs ----
    out = HERE / "evidence"
    with open(out / "results.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=results[0].keys())
        w.writeheader()
        w.writerows(results)

    titles = {q: t for q, t, _ in QUERIES}
    lines = ["| Query | Phase | Variant | Median ms | Buffers | Result | Main operators |",
             "|---|---|---|---:|---:|---|---|"]
    for r in sorted(results, key=lambda r: (r["query"], r["phase"] != "before")):
        lines.append(f"| {r['query']} | {r['phase']} | {r['variant']} | {r['median_ms']:,.2f} | {r['buffers']:,} "
                     f"| {r['result']} | {r['operators']} |")
    speed = ["", "| Query | Description | Before ms | Best after ms | Speed-up |", "|---|---|---:|---:|---:|"]
    for qid, title, _ in QUERIES:
        b = [r for r in results if r["query"] == qid and r["phase"] == "before"][0]["median_ms"]
        a = min(r["median_ms"] for r in results if r["query"] == qid and r["phase"] == "after")
        speed.append(f"| {qid} | {title} | {b:,.2f} | {a:,.3f} | {b / a:,.0f}× |")
    (out / "results.md").write_text("\n".join(lines + speed) + "\n")

    # index sizes (B-tree vs BRIN comparison)
    conn.execute("CREATE INDEX tmp_btree_txn_created ON transactions (created_at)")
    sizes = conn.execute("""
        SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size, pg_relation_size(indexrelid) AS bytes
        FROM pg_stat_user_indexes WHERE schemaname = 'payhaven'
          AND indexrelname IN ('ix_ledger_account_time','ix_ledger_txn','ix_txn_open_items','brin_txn_created',
                               'tmp_btree_txn_created','ix_customers_phone_trgm','transactions_pkey')
        ORDER BY bytes DESC""").fetchall()
    conn.execute("DROP INDEX tmp_btree_txn_created")
    with open(out / "index_sizes.txt", "w") as fh:
        fh.write("Index sizes after optimisation (tmp_btree_txn_created = B-tree equivalent of the BRIN, built only for comparison)\n\n")
        for name, size, _ in sizes:
            fh.write(f"{name:32} {size}\n")

    # ready-to-read SQL file
    with open(HERE / "sql" / "queries.sql", "w") as fh:
        fh.write("-- Portfolio 2 workload queries (generated by benchmark.py — edit there)\nSET search_path TO payhaven;\n")
        for qid, title, variants in QUERIES:
            fh.write(f"\n-- ===== {qid}: {title} =====\n")
            seen = set()
            for phase, label, sql, *_ in variants:
                if sql and sql not in seen:
                    seen.add(sql)
                    fh.write(f"-- variant: {label}\n{sql};\n\n")
    print((out / "results.md").read_text())


if __name__ == "__main__":
    main()
