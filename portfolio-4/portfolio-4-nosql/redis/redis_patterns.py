"""
Portfolio 4 — Redis (key-value) patterns for PayHaven.

Redis sits IN FRONT of PostgreSQL for data that is small, hot, short-lived or
needs sub-millisecond atomic counters. PostgreSQL stays the system of record
for money (Portfolios 1–3).

  R1  Idempotency fast-path        SET key value NX EX
  R2  Rate limiting (sliding window) sorted set + Lua script (atomic)
  R3  Cache-aside customer dashboard  GET / SETEX / DEL on write
  R4  Sessions with sliding expiry  HASH + EXPIRE
  R5  Savings-challenge leaderboard  sorted set ZINCRBY / ZREVRANGE / ZREVRANK
  R6  Notification feed             LIST LPUSH + LTRIM

Run:  pip install redis "psycopg[binary]"
      REDIS_URL=redis://localhost:6379/0 PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=payhaven \
      python redis_patterns.py | tee ../evidence/redis_output.txt
"""
import json
import os
import statistics
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg
import redis

r = redis.Redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"), decode_responses=True)
pg = psycopg.connect(autocommit=True)
pg.execute("SET search_path TO payhaven")

NS = "ph:"  # key namespace — every key is prefixed, e.g. ph:session:<token>


def header(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90, flush=True)


def show(cmd, result):
    print(f"  > {cmd:62} -> {result}")


# ----------------------------------------------------------------------------------
def r1_idempotency():
    header("R1  IDEMPOTENCY FAST-PATH — reject duplicate API requests before they reach PostgreSQL")
    print("  Key ph:idem:<reference>, value = request status, TTL 24h. SET … NX succeeds only for the first caller.\n")
    ref = "PH-API-" + uuid.uuid4().hex[:8]
    key = f"{NS}idem:{ref}"
    show(f"SET {key} PROCESSING NX EX 86400", r.set(key, "PROCESSING", nx=True, ex=86400))
    show(f"SET {key} PROCESSING NX EX 86400  (retry)", r.set(key, "PROCESSING", nx=True, ex=86400))
    r.set(key, json.dumps({"status": "SUCCESSFUL", "txn_id": 123456}), xx=True, keepttl=True)
    show(f"GET {key}", r.get(key))
    show(f"TTL {key}", r.ttl(key))

    # 50 simultaneous duplicates: exactly one wins
    ref2 = "PH-API-" + uuid.uuid4().hex[:8]
    barrier = threading.Barrier(50)
    wins = []

    def attempt(_):
        barrier.wait()
        if r.set(f"{NS}idem:{ref2}", "PROCESSING", nx=True, ex=86400):
            wins.append(1)

    with ThreadPoolExecutor(50) as ex:
        list(ex.map(attempt, range(50)))
    print(f"\n  50 concurrent duplicates of {ref2}: {len(wins)} accepted, {50 - len(wins)} rejected as duplicates")
    print("  Note: this is only a fast-path. The UNIQUE constraint on transactions.reference (Portfolio 3, E4) remains the")
    print("  guarantee, because Redis data can be lost on failover; the database cannot be bypassed for money.")


# ----------------------------------------------------------------------------------
SLIDING_WINDOW_LUA = """
-- KEYS[1] = limiter key, ARGV = now_ms, window_ms, limit, member
local now, window, limit = tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - window)          -- drop attempts outside the window
local count = redis.call('ZCARD', KEYS[1])
if count < limit then
  redis.call('ZADD', KEYS[1], now, ARGV[4])
  redis.call('PEXPIRE', KEYS[1], window)
  return {1, limit - count - 1}
end
local oldest = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
return {0, tonumber(oldest[2]) + window - now}                      -- blocked: ms until a slot frees up
"""
sliding_window = r.register_script(SLIDING_WINDOW_LUA)


def allow(key, limit, window_ms):
    ok, info = sliding_window(keys=[key], args=[int(time.time() * 1000), window_ms, limit, uuid.uuid4().hex])
    return bool(ok), info


def r2_rate_limit():
    header("R2  RATE LIMITING — max 5 wrong-PIN attempts per customer per 10 minutes (sliding window)")
    key = f"{NS}rl:pin:customer:{uuid.uuid4().hex[:6]}"
    for i in range(1, 9):
        ok, info = allow(key, 5, 600_000)
        print(f"  attempt {i}: {'ALLOWED' if ok else 'BLOCKED'}  " +
              (f"(remaining {info})" if ok else f"(retry in {info / 1000:.0f} s)"))
    show(f"ZCARD {key}", r.zcard(key))
    show(f"PTTL {key}", r.pttl(key))

    print("\n  Atomicity check: 100 concurrent requests against a limit of 10 transfers/minute for one device")
    key2 = f"{NS}rl:transfer:device:{uuid.uuid4().hex[:6]}"
    res = []
    with ThreadPoolExecutor(50) as ex:
        res = list(ex.map(lambda _: allow(key2, 10, 60_000)[0], range(100)))
    print(f"  allowed: {sum(res)}  blocked: {len(res) - sum(res)}   (exactly 10 must be allowed)")

    # The same limiter written WITHOUT Lua (read, decide, write as separate commands) races:
    key3 = f"{NS}rl:naive:{uuid.uuid4().hex[:6]}"

    def naive_allow(_):
        now = int(time.time() * 1000)
        r.zremrangebyscore(key3, 0, now - 60_000)
        if r.zcard(key3) < 10:           # check …
            time.sleep(0.001)
            r.zadd(key3, {uuid.uuid4().hex: now})   # … then act (another client may have acted in between)
            return True
        return False

    with ThreadPoolExecutor(50) as ex:
        naive = list(ex.map(naive_allow, range(100)))
    print(f"  same limiter without Lua (separate commands): allowed {sum(naive)}  -> "
          f"{'LIMIT BYPASSED (race condition)' if sum(naive) > 10 else 'ok'}")


# ----------------------------------------------------------------------------------
DASHBOARD_SQL = """
SELECT json_build_object(
  'customer', (SELECT json_build_object('name', first_name || ' ' || last_name, 'tier', kyc_tier)
               FROM customers WHERE customer_id = %(cid)s),
  'accounts', (SELECT json_agg(json_build_object('number', account_number, 'balance', balance, 'product', product_code))
               FROM accounts WHERE customer_id = %(cid)s),
  'spent_last_30_days', (SELECT COALESCE(sum(le.amount), 0) FROM ledger_entries le
               JOIN accounts a ON a.account_id = le.account_id
               WHERE a.customer_id = %(cid)s AND le.direction = 'DEBIT'
                 AND le.created_at >= TIMESTAMPTZ '2026-07-01' - INTERVAL '30 days'),
  'recent',   (SELECT json_agg(x) FROM (
                 SELECT t.reference, t.transaction_type, t.amount, t.created_at
                 FROM transactions t WHERE t.initiated_by = %(cid)s
                 ORDER BY t.created_at DESC LIMIT 5) x))
"""


def get_dashboard(cid, use_cache=True):
    key = f"{NS}cache:dashboard:{cid}"
    if use_cache:
        hit = r.get(key)
        if hit:
            return json.loads(hit), "HIT"
    doc = pg.execute(DASHBOARD_SQL, {"cid": cid}).fetchone()[0]
    if use_cache:
        r.set(key, json.dumps(doc, default=str), ex=30)   # TTL bounds staleness to 30 s
    return doc, "MISS"


def r3_cache():
    header("R3  CACHE-ASIDE — the app home screen (profile, balances, 30-day spend, last 5 transactions)")
    cid = pg.execute("SELECT customer_id FROM customers WHERE bvn = '23000000001'").fetchone()[0]
    r.delete(f"{NS}cache:dashboard:{cid}")
    _, s1 = get_dashboard(cid)
    _, s2 = get_dashboard(cid)
    print(f"  first request: {s1} (read from PostgreSQL, stored with SETEX 30 s); second request: {s2}")

    def timeit(fn, n=500):
        t = []
        for _ in range(n):
            t0 = time.perf_counter()
            fn()
            t.append((time.perf_counter() - t0) * 1000)
        return statistics.median(t), sorted(t)[int(n * 0.95)]

    pg_p50, pg_p95 = timeit(lambda: get_dashboard(cid, use_cache=False))
    rc_p50, rc_p95 = timeit(lambda: get_dashboard(cid))
    print(f"  PostgreSQL every time : p50 {pg_p50:.3f} ms   p95 {pg_p95:.3f} ms")
    print(f"  Redis cache hit       : p50 {rc_p50:.3f} ms   p95 {rc_p95:.3f} ms   ({pg_p50 / rc_p50:.1f}x faster at p50)")
    print("  Invalidation: after a transfer commits, the app runs  DEL ph:cache:dashboard:<customer_id>  so the next read is fresh.")
    r.delete(f"{NS}cache:dashboard:{cid}")
    _, s3 = get_dashboard(cid)
    print(f"  after DEL: {s3}")


# ----------------------------------------------------------------------------------
def r4_sessions():
    header("R4  SESSIONS — hash per session, 15-minute idle timeout refreshed on every request")
    token = uuid.uuid4().hex
    key = f"{NS}session:{token}"
    r.hset(key, mapping={"customer_id": 5000, "device_id": "dev-7f3a", "channel": "MOBILE",
                         "kyc_tier": 3, "login_at": int(time.time())})
    r.expire(key, 900)
    show(f"HGETALL {key[:24]}…", r.hgetall(key))
    show("TTL (after login)", r.ttl(key))
    time.sleep(1.1)
    show("TTL (1 s later)", r.ttl(key))
    r.expire(key, 900)   # sliding expiry on activity
    show("EXPIRE 900 on activity, TTL", r.ttl(key))
    r.delete(key)
    show("logout: DEL, EXISTS", r.exists(key))


# ----------------------------------------------------------------------------------
def r5_leaderboard():
    header("R5  LEADERBOARD — 'June 2026 savings challenge', customers ranked by total deposited")
    board = f"{NS}lb:savings:2026-06"
    r.delete(board)
    rows = pg.execute("""SELECT t.initiated_by, t.amount FROM transactions t
                         WHERE t.transaction_type = 'DEPOSIT' AND t.status = 'SUCCESSFUL'
                           AND t.created_at >= '2026-06-01' AND t.created_at < '2026-07-01'""").fetchall()
    t0 = time.perf_counter()
    pipe = r.pipeline(transaction=False)
    for cid, amt in rows:
        pipe.zincrby(board, float(amt), f"cust:{cid}")   # member = customer id (unique); score = running total
    pipe.execute()
    el = (time.perf_counter() - t0) * 1000
    print(f"  loaded {len(rows):,} June deposit events with ZINCRBY in {el:.0f} ms (pipelined); "
          f"{r.zcard(board):,} savers on the board")
    top = r.zrevrange(board, 0, 4, withscores=True)
    names = dict(pg.execute("SELECT 'cust:' || customer_id, first_name || ' ' || last_name FROM customers "
                            "WHERE customer_id = ANY(%s)", ([int(m.split(':')[1]) for m, _ in top],)).fetchall())
    print("  ZREVRANGE board 0 4 WITHSCORES  (top 5):")
    for i, (member, score) in enumerate(top, 1):
        print(f"     {i}. {member:12} {names[member]:22} N{score:,.2f}")
    someone = f"cust:{rows[len(rows) // 2][0]}"
    print(f"  ZREVRANK {someone}: position {r.zrevrank(board, someone) + 1:,} of {r.zcard(board):,}  (O(log N), no table scan)")
    print("  Live update when a deposit lands:  ZINCRBY ph:lb:savings:2026-06 <amount> cust:<id>")
    r.expireat(board, int(time.mktime(time.strptime("2026-07-31", "%Y-%m-%d"))))


# ----------------------------------------------------------------------------------
def r6_feed():
    header("R6  NOTIFICATION FEED — newest 20 notifications per customer (capped list)")
    key = f"{NS}feed:customer:5000"
    r.delete(key)
    for i in range(1, 31):
        r.lpush(key, json.dumps({"n": i, "msg": f"You received N{i * 1000:,} from Lab Bravo"}))
        r.ltrim(key, 0, 19)   # keep only 20 — memory per customer is bounded
    show(f"LLEN {key}", r.llen(key))
    show("LRANGE 0 2 (newest first)", [json.loads(x)["n"] for x in r.lrange(key, 0, 2)])


def footer():
    header("SERVER FACTS")
    info = r.info()
    print(f"  Redis {info['redis_version']}  used_memory {info['used_memory_human']}  keys {r.dbsize()}  "
          f"maxmemory-policy {r.config_get('maxmemory-policy')['maxmemory-policy']}  appendonly {r.config_get('appendonly')['appendonly']}")
    print(f"  keys in ph:* namespace: {sum(1 for _ in r.scan_iter(NS + '*'))}")


if __name__ == "__main__":
    r1_idempotency()
    r2_rate_limit()
    r3_cache()
    r4_sessions()
    r5_leaderboard()
    r6_feed()
    footer()
