#!/usr/bin/env bash
# =====================================================================
# Portfolio 5 — Replication, consistency, availability and failover lab
#
# Builds a 3-node PostgreSQL 16 cluster on one machine:
#     primary  :5433   ──WAL stream──▶  replica1 :5434
#                      └─WAL stream──▶  replica2 :5435
# loads the PayHaven schema (P1) + transfer functions (P3), then runs
# experiments D1–D5. All output goes to stdout (tee it into evidence/).
#
# Requirements: PostgreSQL 16 server binaries (initdb, pg_ctl, pg_basebackup,
# pg_rewind, pgbench). Run as a NORMAL user (Postgres refuses to run as root).
#   Linux / WSL:  PGBIN=/usr/lib/postgresql/16/bin ./replication_lab.sh | tee ../evidence/replication_lab.txt
#   macOS (brew): PGBIN=$(brew --prefix postgresql@16)/bin ./replication_lab.sh
# =====================================================================
set -uo pipefail
PGBIN=${PGBIN:-/usr/lib/postgresql/16/bin}
BASE=${BASE:-/tmp/payhaven-p5-replication}
SOCK=/tmp
REPO=$(cd "$(dirname "$0")/../.." && pwd)
P=5433; R1=5434; R2=5435
export PATH="$PGBIN:$PATH"

q()  { psql -h $SOCK -p "$1" -U postgres -d payhaven -X -q "${@:2}"; }          # query a node
qa() { psql -h $SOCK -p "$1" -U postgres -d payhaven -X -q -A -t "${@:2}"; }    # unaligned, tuples only
section() { echo; echo "======================================================================================"; echo "$*"; echo "======================================================================================"; }
ms() { date +%s%3N; }

# ---------------------------------------------------------------- clean start
for d in primary replica1 replica2; do pg_ctl -D "$BASE/$d" stop -m immediate >/dev/null 2>&1 || true; done
rm -rf "$BASE"; mkdir -p "$BASE"

section "D1  BUILD THE CLUSTER — primary + 2 streaming replicas (physical, WAL-based)"
initdb -D "$BASE/primary" -U postgres -A trust --no-sync >/dev/null
cat >> "$BASE/primary/postgresql.conf" <<EOF
port = $P
listen_addresses = ''
unix_socket_directories = '$SOCK'
timezone = 'Africa/Lagos'
wal_level = replica              # write enough WAL for physical replicas
max_wal_senders = 10
max_replication_slots = 10
wal_log_hints = on               # needed later by pg_rewind (re-join after failover)
hot_standby = on                 # replicas accept read-only queries
synchronous_standby_names = ''   # start asynchronous
EOF
pg_ctl -D "$BASE/primary" -l "$BASE/primary.log" -w start >/dev/null
createdb -h $SOCK -p $P -U postgres payhaven
psql -h $SOCK -p $P -U postgres -d payhaven -X -q -c "ALTER DATABASE payhaven SET search_path TO payhaven, public"
for f in "$REPO"/portfolio-1-database-design/sql/0{1,2,3,4}_*.sql \
         "$REPO"/portfolio-3-transactions-concurrency/sql/01_transfer_procedures.sql \
         "$REPO"/portfolio-3-transactions-concurrency/sql/00_setup_lab.sql; do
  q $P -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>&1 || { echo "failed loading $f"; exit 1; }
done
echo "primary :$P  loaded PayHaven schema, seed data and transfer functions"

for i in 1 2; do
  port=$([ $i = 1 ] && echo $R1 || echo $R2)
  # base backup of the running primary + replication slot, -R writes standby.signal & primary_conninfo
  pg_basebackup -h $SOCK -p $P -U postgres -D "$BASE/replica$i" -X stream -C -S "replica${i}_slot" -R >/dev/null
  cat >> "$BASE/replica$i/postgresql.auto.conf" <<EOF
port = $port
primary_conninfo = 'host=$SOCK port=$P user=postgres application_name=replica$i'
EOF
  pg_ctl -D "$BASE/replica$i" -l "$BASE/replica$i.log" -w start >/dev/null
  echo "replica$i :$port  created with pg_basebackup (slot replica${i}_slot) and started in standby mode"
done
sleep 1
echo; echo "pg_stat_replication on the primary:"
q $P -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication ORDER BY 1;"

# ---------------------------------------------------------------- D2
section "D2  READ SCALING — write on the primary, read on the replicas; replicas reject writes"
A=$(qa $P -c "SELECT payhaven.lab_new_account('24000000001','PH_TIER3',100000)")
B=$(qa $P -c "SELECT payhaven.lab_new_account('24000000002','PH_TIER3',0)")
qa $P -c "SELECT payhaven.transfer('D2-$A','$A','$B',15000)" >/dev/null
sleep 0.5
for node in "primary:$P" "replica1:$R1" "replica2:$R2"; do
  printf "%-9s in_recovery=%s  balances %s=%s  %s=%s\n" "${node%%:*}" \
    "$(qa ${node##*:} -c 'SELECT pg_is_in_recovery()')" \
    "$A" "$(qa ${node##*:} -c "SELECT balance FROM payhaven.accounts WHERE account_number='$A'")" \
    "$B" "$(qa ${node##*:} -c "SELECT balance FROM payhaven.accounts WHERE account_number='$B'")"
done
echo; echo "Attempt a transfer on replica1:"
qa $R1 -c "SELECT payhaven.transfer('D2b-$A','$A','$B',1000)" 2>&1 | head -1

# ---------------------------------------------------------------- D3
section "D3  REPLICATION LAG = STALE READS (eventual consistency on asynchronous replicas)"
echo "Pause WAL replay on replica1 (simulates a lagging replica), then transfer N25,000 on the primary."
qa $R1 -c "SELECT pg_wal_replay_pause()" >/dev/null
qa $P -c "SELECT payhaven.transfer('D3-$A','$A','$B',25000)" >/dev/null
sleep 0.5
for node in "primary:$P" "replica1:$R1" "replica2:$R2"; do
  printf "%-9s balance of %s = %s\n" "${node%%:*}" "$A" "$(qa ${node##*:} -c "SELECT balance FROM payhaven.accounts WHERE account_number='$A'")"
done
echo; echo "Primary's view of the replicas (replay_lsn behind sent_lsn = WAL received but not yet applied):"
q $P -c "SELECT application_name, sent_lsn, replay_lsn, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_behind, replay_lag FROM pg_stat_replication ORDER BY 1;"
echo "A customer whose app reads from replica1 right after transferring would see their OLD balance."
echo "Resume replay:"
qa $R1 -c "SELECT pg_wal_replay_resume()" >/dev/null; sleep 1
printf "replica1  balance of %s = %s  (caught up)\n" "$A" "$(qa $R1 -c "SELECT balance FROM payhaven.accounts WHERE account_number='$A'")"

# ---------------------------------------------------------------- D4
section "D4  CONSISTENCY vs LATENCY — asynchronous vs synchronous commit (pgbench, 1 client, 8 s each)"
cat > "$BASE/deposit.sql" <<EOF
SELECT payhaven.deposit('PB-' || left(md5(random()::text || clock_timestamp()::text), 26), '$B', 10);
EOF
bench() {
  pgbench -h $SOCK -p $P -U postgres -n -c 1 -T 8 -f "$BASE/deposit.sql" payhaven 2>/dev/null \
    | awk '/latency average/ {lat=$4} /tps =/ {tps=$3} END {printf "latency avg %6.3f ms   tps %7.1f\n", lat, tps}'
}
set_sync() {   # $1 = synchronous_standby_names, $2 = synchronous_commit
  qa $P -c "ALTER SYSTEM SET synchronous_standby_names = '$1'" >/dev/null
  qa $P -c "ALTER SYSTEM SET synchronous_commit = '$2'" >/dev/null
  qa $P -c "SELECT pg_reload_conf()" >/dev/null; sleep 1
}
set_sync "" "on";                       printf "%-62s %s\n" "async   (no synchronous standby)"                       "$(bench)"
set_sync "FIRST 1 (replica1)" "on";     printf "%-62s %s\n" "sync    on           (replica1 has FLUSHED the WAL)"     "$(bench)"
set_sync "FIRST 1 (replica1)" "remote_apply"; printf "%-62s %s\n" "sync    remote_apply (replica1 has APPLIED it: readable)" "$(bench)"
q $P -c "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY 1;"
echo "All nodes share one machine, so the network round-trip is ~0. Across cloud availability zones each"
echo "synchronous commit adds roughly one inter-AZ round trip (~1-2 ms); across regions, tens of ms."

section "D4b AVAILABILITY — the synchronous standby goes down (CAP in practice)"
set_sync "FIRST 1 (replica1)" "on"
pg_ctl -D "$BASE/replica1" stop -m fast >/dev/null
echo "replica1 stopped. Committing a N1,000 transfer on the primary (it must wait for replica1's acknowledgement)..."
( qa $P -c "SELECT payhaven.transfer('D4b-$A','$A','$B',1000)" > "$BASE/d4b.out" 2>&1 ) &
BG=$!
sleep 3
echo "After 3 s the session is still waiting:"
q $P -c "SELECT pid, state, wait_event_type, wait_event, left(query, 45) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
echo "Operator cancels the wait:"
qa $P -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'" >/dev/null
wait $BG 2>/dev/null
sed 's/^/   client saw: /' "$BASE/d4b.out"
echo "=> With one synchronous standby, losing that standby blocks every commit: the primary chose CONSISTENCY over AVAILABILITY."
echo
echo "Fix: quorum commit — any 1 of the 2 replicas may acknowledge:"
set_sync "ANY 1 (replica1, replica2)" "on"
s=$(ms); qa $P -c "SELECT payhaven.transfer('D4c-$A','$A','$B',1000)" >/dev/null; e=$(ms)
echo "   transfer committed in $((e - s)) ms with replica1 still down (replica2 acknowledged)"
q $P -c "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1;"
pg_ctl -D "$BASE/replica1" -l "$BASE/replica1.log" -w start >/dev/null; sleep 1
set_sync "" "on"

# ---------------------------------------------------------------- D5
section "D5  FAILOVER — the primary crashes; promote replica2; re-attach the others"
qa $P -c "SELECT payhaven.transfer('D5-$A','$A','$B',2000)" >/dev/null
sleep 1
BEFORE=$(qa $P -c "SELECT count(*) FROM payhaven.transactions")
echo "transactions on primary before crash: $BEFORE"
T0=$(ms)
pg_ctl -D "$BASE/primary" stop -m immediate >/dev/null      # simulated crash: no clean shutdown
T1=$(ms)
echo "primary killed (immediate stop) at t=0"
qa $R2 -c "SELECT pg_promote(wait => true)" >/dev/null
T2=$(ms)
qa $R2 -c "SELECT payhaven.transfer('D5-after-$A','$A','$B',3000)" >/dev/null
T3=$(ms)
echo "replica2 promoted after $((T2 - T0)) ms; first successful transfer on the new primary at $((T3 - T0)) ms"
echo "replica2 in_recovery=$(qa $R2 -c 'SELECT pg_is_in_recovery()')  transactions=$(qa $R2 -c 'SELECT count(*) FROM payhaven.transactions')  (before crash: $BEFORE, +1 new)"
echo "RPO here = 0 transactions lost (every pre-crash commit had already streamed). With asynchronous"
echo "replication a crash CAN lose the last few commits; with synchronous replication it cannot."
echo
echo "Re-point replica1 at the new primary (it follows the new timeline):"
cat >> "$BASE/replica1/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$SOCK port=$R2 user=postgres application_name=replica1'
primary_slot_name = ''
EOF
pg_ctl -D "$BASE/replica1" -l "$BASE/replica1.log" -w restart >/dev/null; sleep 2
echo "Re-join the OLD primary as a replica with pg_rewind (discards its divergent WAL, copies changed blocks):"
pg_rewind --target-pgdata="$BASE/primary" --source-server="host=$SOCK port=$R2 user=postgres dbname=postgres" 2>&1 | tail -1
touch "$BASE/primary/standby.signal"
# pg_rewind copied replica2's config files too, so restore this node's own port and drop the slot name
cat >> "$BASE/primary/postgresql.auto.conf" <<EOF
port = $P
primary_slot_name = ''
primary_conninfo = 'host=$SOCK port=$R2 user=postgres application_name=old_primary'
EOF
pg_ctl -D "$BASE/primary" -l "$BASE/primary.log" -w start >/dev/null; sleep 2
echo; echo "New topology — pg_stat_replication on replica2 (the new primary, :$R2):"
q $R2 -c "SELECT application_name, state, sync_state, replay_lsn FROM pg_stat_replication ORDER BY 1;"
for node in "old_primary:$P" "replica1:$R1" "replica2:$R2"; do
  printf "%-12s in_recovery=%-2s timeline=%s  balance %s=%s\n" "${node%%:*}" "$(qa ${node##*:} -c 'SELECT pg_is_in_recovery()')" \
    "$(qa ${node##*:} -c "SELECT CASE WHEN pg_is_in_recovery() THEN (SELECT received_tli FROM pg_stat_wal_receiver)
                                    ELSE ('x' || substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8))::bit(32)::int END")" "$A" \
    "$(qa ${node##*:} -c "SELECT balance FROM payhaven.accounts WHERE account_number='$A'")"
done

section "CLEAN-UP"
for d in primary replica1 replica2; do pg_ctl -D "$BASE/$d" stop -m fast >/dev/null 2>&1 || true; done
echo "all three nodes stopped (data left in $BASE)"
