#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 — Sharding and distributed transactions lab
#
#   coordinator :5436  (postgres_fdw, hash-partitioned tables, no data)
#        ├── shard1 :5437   customers whose hash(customer_id) % 2 = 0
#        └── shard2 :5438   customers whose hash(customer_id) % 2 = 1
#
# Experiments S1–S6: data distribution, query routing (partition pruning),
# co-located joins, scatter-gather aggregation, a cross-shard transfer WITHOUT
# two-phase commit (atomicity breaks), and WITH two-phase commit.
#
#   PGBIN=/usr/lib/postgresql/16/bin ./sharding_lab.sh | tee ../evidence/sharding_lab.txt
# Run as a normal (non-root) user. Requires the postgres_fdw extension (contrib).
# =====================================================================
set -uo pipefail
PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
BASE=${BASE:-/tmp/payhaven-p5-sharding}
SOCK=/tmp
C=5436; S1=5437; S2=5438
export PATH="$PGBIN:$PATH"

q()  { psql -h $SOCK -p "$1" -U postgres -d payhaven -X -q "${@:2}"; }
qa() { psql -h $SOCK -p "$1" -U postgres -d payhaven -X -q -A -t "${@:2}"; }
section() { echo; echo "======================================================================================"; echo "$*"; echo "======================================================================================"; }

for d in coordinator shard1 shard2; do pg_ctl -D "$BASE/$d" stop -m immediate >/dev/null 2>&1 || true; done
rm -rf "$BASE"; mkdir -p "$BASE"

section "SETUP — 3 PostgreSQL nodes"
for node in coordinator:$C shard1:$S1 shard2:$S2; do
  name=${node%%:*}; port=${node##*:}
  initdb -D "$BASE/$name" -U postgres -A trust --no-sync >/dev/null
  cat >> "$BASE/$name/postgresql.conf" <<EOF
port = $port
listen_addresses = ''
unix_socket_directories = '$SOCK'
timezone = 'Africa/Lagos'
max_prepared_transactions = 10      # allow PREPARE TRANSACTION (two-phase commit)
EOF
  pg_ctl -D "$BASE/$name" -l "$BASE/$name.log" -w start >/dev/null
  createdb -h $SOCK -p $port -U postgres payhaven
  echo "$name :$port started"
done

# Physical tables live on the shards. The rule "balance may not exceed N150,000" is a
# DEFERRED constraint trigger, so it is checked at COMMIT / PREPARE time — this lets us
# make a shard fail at the very end of a distributed transaction.
for port in $S1 $S2; do
q $port <<'SQL'
CREATE TABLE wallets (
  account_number CHAR(10) PRIMARY KEY,
  customer_id    BIGINT NOT NULL,
  balance        NUMERIC(18,2) NOT NULL CHECK (balance >= 0));
CREATE INDEX ON wallets (customer_id);
CREATE TABLE wallet_ledger (
  entry_id       BIGSERIAL PRIMARY KEY,
  customer_id    BIGINT NOT NULL,
  account_number CHAR(10) NOT NULL REFERENCES wallets,
  direction      TEXT NOT NULL,
  amount         NUMERIC(18,2) NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE INDEX ON wallet_ledger (customer_id);
CREATE FUNCTION max_balance_rule() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.balance > 150000 THEN
    RAISE EXCEPTION 'wallet % would hold %, above the N150,000 tier limit', NEW.account_number, NEW.balance;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER max_balance AFTER INSERT OR UPDATE ON wallets
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION max_balance_rule();
SQL
done

# The coordinator holds only metadata: partitioned tables whose partitions are foreign tables.
q $C <<SQL
CREATE EXTENSION postgres_fdw;
CREATE SERVER shard1 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '$SOCK', port '$S1', dbname 'payhaven', async_capable 'true', batch_size '1000', use_remote_estimate 'true');
CREATE SERVER shard2 FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '$SOCK', port '$S2', dbname 'payhaven', async_capable 'true', batch_size '1000', use_remote_estimate 'true');
CREATE USER MAPPING FOR postgres SERVER shard1 OPTIONS (user 'postgres');
CREATE USER MAPPING FOR postgres SERVER shard2 OPTIONS (user 'postgres');

CREATE TABLE wallets (account_number CHAR(10) NOT NULL, customer_id BIGINT NOT NULL, balance NUMERIC(18,2) NOT NULL)
  PARTITION BY HASH (customer_id);
CREATE FOREIGN TABLE wallets_s1 PARTITION OF wallets FOR VALUES WITH (MODULUS 2, REMAINDER 0)
  SERVER shard1 OPTIONS (table_name 'wallets');
CREATE FOREIGN TABLE wallets_s2 PARTITION OF wallets FOR VALUES WITH (MODULUS 2, REMAINDER 1)
  SERVER shard2 OPTIONS (table_name 'wallets');

-- ledger sharded by the SAME key -> a customer's wallet and ledger live on the same shard (co-location)
CREATE TABLE wallet_ledger (customer_id BIGINT NOT NULL, account_number CHAR(10) NOT NULL,
                            direction TEXT NOT NULL, amount NUMERIC(18,2) NOT NULL, created_at TIMESTAMPTZ)
  PARTITION BY HASH (customer_id);
CREATE FOREIGN TABLE wallet_ledger_s1 PARTITION OF wallet_ledger FOR VALUES WITH (MODULUS 2, REMAINDER 0)
  SERVER shard1 OPTIONS (table_name 'wallet_ledger');
CREATE FOREIGN TABLE wallet_ledger_s2 PARTITION OF wallet_ledger FOR VALUES WITH (MODULUS 2, REMAINDER 1)
  SERVER shard2 OPTIONS (table_name 'wallet_ledger');
SQL
echo "coordinator: wallets and wallet_ledger hash-partitioned by customer_id into foreign tables on shard1/shard2"

echo "Loading 20,000 wallets and 100,000 ledger lines THROUGH the coordinator (it routes each row)..."
s=$(date +%s%3N)
q $C -c "INSERT INTO wallets SELECT '5' || lpad(g::text, 9, '0'), g, 100000 FROM generate_series(1, 20000) g;"
q $C -c "INSERT INTO wallet_ledger SELECT g % 20000 + 1, '5' || lpad((g % 20000 + 1)::text, 9, '0'),
                CASE WHEN g % 3 = 0 THEN 'DEBIT' ELSE 'CREDIT' END, (g % 997) + 100,
                TIMESTAMPTZ '2026-06-01' + g * INTERVAL '20 seconds'
         FROM generate_series(1, 100000) g;"
e=$(date +%s%3N); echo "loaded in $((e - s)) ms"
for p in $C $S1 $S2; do qa $p -c "ANALYZE" >/dev/null 2>&1 || true; done

# ---------------------------------------------------------------- S1
section "S1  DATA DISTRIBUTION — hash partitioning spreads customers evenly"
q $C -c "SELECT tableoid::regclass AS partition, count(*) AS wallets, sum(balance) AS total_balance FROM wallets GROUP BY 1 ORDER BY 1;"
echo "Counted directly on each shard:  shard1=$(qa $S1 -c 'SELECT count(*) FROM wallets')  shard2=$(qa $S2 -c 'SELECT count(*) FROM wallets')"

# ---------------------------------------------------------------- S2
section "S2  QUERY ROUTING — a single-customer query touches ONE shard (partition pruning)"
q $C -c "EXPLAIN (VERBOSE, COSTS OFF) SELECT account_number, balance FROM wallets WHERE customer_id = 42;"
q $C -c "SELECT tableoid::regclass AS served_by, account_number, balance FROM wallets WHERE customer_id = 42;"
echo "A query WITHOUT the shard key must ask every shard:"
q $C -c "EXPLAIN (COSTS OFF) SELECT customer_id FROM wallets WHERE account_number = '5000000042';"

# ---------------------------------------------------------------- S3
section "S3  CO-LOCATED JOIN — wallets JOIN ledger is executed INSIDE each shard (partition-wise join pushdown)"
echo "Because both tables are sharded by customer_id, matching rows are always on the same shard,"
echo "so each shard can join its own pieces and the coordinator only merges the results."
q $C -c "SET enable_partitionwise_join = on;" -c "EXPLAIN (VERBOSE, COSTS OFF)
SELECT w.customer_id, w.balance, sum(l.amount) AS volume
FROM wallets w JOIN wallet_ledger l ON l.customer_id = w.customer_id AND l.account_number = w.account_number
GROUP BY w.customer_id, w.balance ORDER BY volume DESC LIMIT 5;" | grep -E "QUERY PLAN|Limit|Sort|Append|Merge|Foreign Scan|Relations|Remote SQL" | cut -c1-170
q $C -c "SET enable_partitionwise_join = on;" -c "
SELECT w.customer_id, w.balance, sum(l.amount) AS volume
FROM wallets w JOIN wallet_ledger l ON l.customer_id = w.customer_id AND l.account_number = w.account_number
GROUP BY w.customer_id, w.balance ORDER BY volume DESC LIMIT 5;"
echo "'Relations: (wallets_sX w) INNER JOIN (wallet_ledger_sX l)' = the join was shipped to the shard as one remote query."

# ---------------------------------------------------------------- S4
section "S4  SCATTER-GATHER AGGREGATION — what can and cannot be pushed to the shards"
echo "(a) Grouped BY the shard key: every group lives on one shard, so each shard computes final results in parallel"
q $C -c "SET enable_partitionwise_aggregate = on;" -c "EXPLAIN (VERBOSE, COSTS OFF)
SELECT customer_id, count(*) AS lines, sum(amount) AS volume FROM wallet_ledger GROUP BY customer_id ORDER BY volume DESC LIMIT 5;" \
  | grep -E "QUERY PLAN|Limit|Sort|Append|Foreign Scan|Relations|Remote SQL" | cut -c1-150
echo
echo "(b) A bank-wide total (no shard key): here PostgreSQL 16's postgres_fdw does NOT push the partial aggregates,"
echo "    so every shard ships its rows and the coordinator aggregates — network traffic grows with data size."
q $C -c "SET enable_partitionwise_aggregate = on;" -c "EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*), sum(balance) FROM wallets;" \
  | grep -E "QUERY PLAN|Aggregate|Append|Foreign Scan|Remote SQL" | cut -c1-150
q $C -c "SELECT count(*) AS wallets, sum(balance) AS total_customer_balances FROM wallets;"

# ---------------------------------------------------------------- S5
pick() { qa $C -c "SELECT customer_id FROM wallets WHERE tableoid = 'wallets_$1'::regclass ORDER BY customer_id OFFSET $2 LIMIT 1"; }
A1=$(pick s1 0); B2=$(pick s2 0)      # A1 lives on shard1, B2 on shard2
A1b=$(pick s1 1); B2b=$(pick s2 1)
bal() { qa $C -c "SELECT balance FROM wallets WHERE customer_id = $1"; }

section "S5  CROSS-SHARD TRANSFER WITHOUT TWO-PHASE COMMIT — atomicity can break"
echo "postgres_fdw commits each shard's sub-transaction one after another when the coordinator commits."
echo "If a LATER shard fails at commit, the EARLIER shard has already committed and cannot be undone."
echo "Both directions are tried; N60,000 pushes the receiver to N160,000, which its shard rejects at COMMIT."
for pair in "$A1:$B2" "$B2b:$A1b"; do
  from=${pair%%:*}; to=${pair##*:}
  echo
  echo "Transfer N60,000: customer $from (on $(qa $C -c "SELECT tableoid::regclass FROM wallets WHERE customer_id=$from")) -> customer $to (on $(qa $C -c "SELECT tableoid::regclass FROM wallets WHERE customer_id=$to"))"
  echo "  before: sender $(bal $from)  receiver $(bal $to)  total $(echo "$(bal $from) + $(bal $to)" | bc)"
  q $C 2>&1 <<SQL | sed 's/^/  /' | grep -E "ERROR|CONTEXT" | head -2
BEGIN;
UPDATE wallets SET balance = balance - 60000 WHERE customer_id = $from;
UPDATE wallets SET balance = balance + 60000 WHERE customer_id = $to;
COMMIT;
SQL
  f=$(bal $from); t=$(bal $to); tot=$(echo "$f + $t" | bc)
  verdict=$([ "$tot" = "200000.00" ] && echo "consistent (both sides rolled back)" || echo "INCONSISTENT — N60,000 vanished: debit committed, credit rolled back")
  echo "  after:  sender $f  receiver $t  total $tot  -> $verdict"
done

# ---------------------------------------------------------------- S6
section "S6  TWO-PHASE COMMIT (2PC) — the coordinator makes every shard PREPARE before anyone COMMITs"
# reset the two customers used below
qa $S1 -c "UPDATE wallets SET balance = 100000 WHERE customer_id IN ($A1, $A1b)" >/dev/null
qa $S2 -c "UPDATE wallets SET balance = 100000 WHERE customer_id IN ($B2, $B2b)" >/dev/null

prepare() {   # $1 port, $2 gid, $3 sql  -> prints OK or the error
  out=$(psql -h $SOCK -p "$1" -U postgres -d payhaven -X -q -v ON_ERROR_STOP=1 2>&1 <<SQL
BEGIN;
$3
PREPARE TRANSACTION '$2';
SQL
) && echo "OK" || echo "$out" | grep ERROR | head -1
}
twopc() {     # $1 gid, $2 amount — A1 (shard1) pays B2 (shard2)
  local gid=$1 amt=$2
  r1=$(prepare $S1 "$gid" "UPDATE wallets SET balance = balance - $amt WHERE customer_id = $A1;
       INSERT INTO wallet_ledger (customer_id, account_number, direction, amount)
       SELECT customer_id, account_number, 'DEBIT', $amt FROM wallets WHERE customer_id = $A1;")
  r2=$(prepare $S2 "$gid" "UPDATE wallets SET balance = balance + $amt WHERE customer_id = $B2;
       INSERT INTO wallet_ledger (customer_id, account_number, direction, amount)
       SELECT customer_id, account_number, 'CREDIT', $amt FROM wallets WHERE customer_id = $B2;")
  echo "  phase 1 (PREPARE): shard1 -> $r1"
  echo "                     shard2 -> $r2"
  if [ "$r1" = "OK" ] && [ "$r2" = "OK" ]; then
    qa $S1 -c "COMMIT PREPARED '$gid'"; qa $S2 -c "COMMIT PREPARED '$gid'"
    echo "  phase 2: both voted YES -> COMMIT PREPARED on both shards"
  else
    [ "$r1" = "OK" ] && qa $S1 -c "ROLLBACK PREPARED '$gid'"
    [ "$r2" = "OK" ] && qa $S2 -c "ROLLBACK PREPARED '$gid'"
    echo "  phase 2: a shard voted NO -> ROLLBACK PREPARED on every shard that had prepared"
  fi
  echo "  balances: shard1 customer $A1 = $(bal $A1)   shard2 customer $B2 = $(bal $B2)   total = $(echo "$(bal $A1) + $(bal $B2)" | bc)"
}
echo; echo "Case 1: N30,000 from $A1 (shard1) to $B2 (shard2) — both shards can commit"
twopc "xfer-001" 30000
echo; echo "Case 2: N60,000 more — shard2 would exceed N150,000 and votes NO at PREPARE"
twopc "xfer-002" 60000

echo; echo "Case 3: the coordinator crashes BETWEEN the phases (both shards prepared, no decision sent)"
prepare $S1 "xfer-003" "UPDATE wallets SET balance = balance - 1000 WHERE customer_id = $A1;" >/dev/null
prepare $S2 "xfer-003" "UPDATE wallets SET balance = balance + 1000 WHERE customer_id = $B2;" >/dev/null
echo "  in-doubt transactions left on the shards:"
for p in $S1 $S2; do q $p -c "SELECT gid, prepared, owner FROM pg_prepared_xacts;" | sed 's/^/    /'; done
echo "  Meanwhile customer $A1 tries a local payment on shard1 (lock_timeout 2 s):"
psql -h $SOCK -p $S1 -U postgres -d payhaven -X -q -c "SET lock_timeout = '2s'" \
     -c "UPDATE wallets SET balance = balance - 500 WHERE customer_id = $A1" 2>&1 | grep ERROR | sed 's/^/    /'
echo "  -> the prepared transaction still holds its row locks: 2PC is BLOCKING until the coordinator recovers."
echo "  Coordinator recovers, reads its decision log (both prepared -> commit) and finishes the job:"
qa $S1 -c "COMMIT PREPARED 'xfer-003'"; qa $S2 -c "COMMIT PREPARED 'xfer-003'"
echo "  prepared transactions remaining: shard1=$(qa $S1 -c 'SELECT count(*) FROM pg_prepared_xacts') shard2=$(qa $S2 -c 'SELECT count(*) FROM pg_prepared_xacts')"
echo "  final balances: $A1 = $(bal $A1)   $B2 = $(bal $B2)   total = $(echo "$(bal $A1) + $(bal $B2)" | bc)  (N200,000 — nothing lost)"

section "CLEAN-UP"
for d in coordinator shard1 shard2; do pg_ctl -D "$BASE/$d" stop -m fast >/dev/null 2>&1 || true; done
echo "all nodes stopped (data left in $BASE)"
