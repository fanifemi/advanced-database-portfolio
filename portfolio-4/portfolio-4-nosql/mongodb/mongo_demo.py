"""
Portfolio 4 — MongoDB document model for PayHaven.

Builds two collections from the PostgreSQL system of record (Portfolios 1–2):

  customers           one rich document per customer (Customer-360 read model):
                      embedded addresses, KYC documents, account summaries,
                      beneficiaries, devices and preferences; $jsonSchema validation
  transaction_events  TIME-SERIES collection of channel events with a
                      polymorphic payload (MOBILE / USSD / WEB / API differ)
  otp_codes           one-time passwords that expire automatically (TTL index)

then runs the queries/aggregations PayHaven needs and prints explain() output.

Run against real MongoDB 7 (docker compose up -d mongo):
    pip install pymongo "psycopg[binary]"
    PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=payhaven \
    MONGO_URL=mongodb://localhost:27017 python mongo_demo.py | tee ../evidence/mongodb_output.txt

Dry-run without a MongoDB server (in-memory emulator, some features skipped):
    pip install mongomock
    python mongo_demo.py --mock --limit 5000
"""
import argparse
import datetime as dt
import hashlib
import os
import random
import time
from collections import defaultdict

import psycopg

ap = argparse.ArgumentParser()
ap.add_argument("--mock", action="store_true", help="use mongomock instead of a real server")
ap.add_argument("--limit", type=int, default=0, help="max customers to migrate (0 = all)")
ap.add_argument("--events", type=int, default=200_000, help="number of most recent transactions to migrate as events")
args = ap.parse_args()

if args.mock:
    import mongomock
    client = mongomock.MongoClient()
else:
    from pymongo import MongoClient
    client = MongoClient(os.environ.get("MONGO_URL", "mongodb://localhost:27017"))

from pymongo import ASCENDING, DESCENDING, IndexModel
from pymongo.errors import DuplicateKeyError, WriteError

db = client["payhaven"]
pg = psycopg.connect(autocommit=True)
pg.execute("SET search_path TO payhaven")
pg.execute("SET TimeZone = 'Africa/Lagos'")
rnd = random.Random(8103)


def header(t):
    print("\n" + "=" * 90 + f"\n{t}\n" + "=" * 90, flush=True)


def skipped(feature):
    print(f"  [mock mode] {feature} is not supported by the emulator — run against real MongoDB for this evidence")


# =========================================================================================
# 1. Collections, validation, indexes
# =========================================================================================
CUSTOMER_SCHEMA = {
    "$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "bvn", "name", "phone", "email", "kyc", "accounts", "schema_version"],
        "properties": {
            "_id": {"bsonType": ["int", "long"], "description": "customer_id from PostgreSQL"},
            "bvn": {"bsonType": "string", "pattern": "^[0-9]{11}$"},
            "phone": {"bsonType": "string", "pattern": "^\\+234[0-9]{10}$"},
            "email": {"bsonType": "string", "pattern": "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$"},
            "name": {"bsonType": "object", "required": ["first", "last"],
                     "properties": {"first": {"bsonType": "string"}, "last": {"bsonType": "string"}}},
            "kyc": {"bsonType": "object", "required": ["tier", "status"],
                    "properties": {"tier": {"bsonType": "int", "minimum": 1, "maximum": 3},
                                   "status": {"enum": ["PENDING", "ACTIVE", "SUSPENDED", "CLOSED"]},
                                   "documents": {"bsonType": "array", "maxItems": 10}}},
            "accounts": {"bsonType": "array", "minItems": 0, "maxItems": 20,
                         "items": {"bsonType": "object", "required": ["account_number", "product"],
                                   "properties": {"account_number": {"bsonType": "string", "pattern": "^[0-9]{10}$"}}}},
            "devices": {"bsonType": "array", "maxItems": 50},
            "schema_version": {"bsonType": "int"},
        },
    }
}


def setup():
    header("1. CREATE COLLECTIONS — $jsonSchema validator, time-series collection, indexes")
    for name in ("customers", "transaction_events", "otp_codes"):
        db.drop_collection(name)

    if args.mock:
        db.create_collection("customers")
        db.create_collection("transaction_events")
        skipped("$jsonSchema validation and time-series collections")
    else:
        db.create_collection("customers", validator=CUSTOMER_SCHEMA, validationLevel="strict", validationAction="error")
        db.create_collection("transaction_events",
                             timeseries={"timeField": "ts", "metaField": "meta", "granularity": "minutes"})
        print("  customers           : created with $jsonSchema validator (strict / error)")
        print("  transaction_events  : created as time-series (timeField=ts, metaField=meta, granularity=minutes)")
    db.create_collection("otp_codes")

    idx = [
        IndexModel([("bvn", ASCENDING)], unique=True, name="ux_bvn"),
        IndexModel([("phone", ASCENDING)], unique=True, name="ux_phone"),
        IndexModel([("accounts.account_number", ASCENDING)], unique=True, name="ux_account_number",   # multikey
                   partialFilterExpression={"accounts.account_number": {"$exists": True}}),
        IndexModel([("devices.device_id", ASCENDING)], name="ix_device"),                              # multikey
        IndexModel([("kyc.tier", ASCENDING), ("kyc.status", ASCENDING)], name="ix_kyc"),
    ]
    if not args.mock:
        # case-insensitive unique email: collation strength 2 ignores case (Portfolio 1 used lower(email))
        idx.append(IndexModel([("email", ASCENDING)], unique=True, name="ux_email_ci",
                              collation={"locale": "en", "strength": 2}))
    db.customers.create_indexes(idx)
    db.transaction_events.create_index([("meta.customer_id", ASCENDING), ("ts", DESCENDING)], name="ix_customer_ts")
    db.otp_codes.create_index("created_at", expireAfterSeconds=300, name="ttl_5_minutes")
    for coll in ("customers", "transaction_events", "otp_codes"):
        print(f"  indexes on {coll:18}: {sorted(db[coll].index_information().keys())}")


# =========================================================================================
# 2. Migrate from PostgreSQL -> documents
# =========================================================================================
def device_for(cid):
    """Deterministic synthetic device ids. ~0.2% of devices are shared by several
    customers (a common fraud signal: one phone operating many 'different' people's wallets)."""
    if cid % 500 == 7:
        ring = cid // 5000                       # customers in the same 5,000-block share one device
        return [f"dev-ring-{ring:03d}"]
    h = hashlib.sha1(str(cid).encode()).hexdigest()
    return [f"dev-{h[:10]}"] + ([f"dev-{h[10:20]}"] if cid % 4 == 0 else [])


def migrate():
    header("2. MIGRATE PostgreSQL -> MongoDB (relational rows -> aggregate documents)")
    lim = f"LIMIT {args.limit}" if args.limit else ""
    t0 = time.perf_counter()
    cust = pg.execute(f"""SELECT customer_id, bvn, first_name, middle_name, last_name, email, phone, date_of_birth,
                                 kyc_tier, status, created_at FROM customers ORDER BY customer_id {lim}""").fetchall()
    ids = [c[0] for c in cust]
    grouped = defaultdict(lambda: defaultdict(list))
    for row in pg.execute("SELECT customer_id, address_type, line1, city, state FROM customer_addresses "
                          "WHERE customer_id = ANY(%s)", (ids,)):
        grouped[row[0]]["addresses"].append({"type": row[1], "line1": row[2], "city": row[3], "state": row[4]})
    for row in pg.execute("""SELECT k.customer_id, k.document_type, k.document_number, k.status, k.submitted_at,
                                    s.staff_number, k.reviewed_at, k.rejection_reason
                             FROM kyc_documents k LEFT JOIN staff s ON s.staff_id = k.reviewed_by
                             WHERE k.customer_id = ANY(%s)""", (ids,)):
        d = {"type": row[1], "number": row[2], "status": row[3], "submitted_at": row[4]}
        if row[5]:
            d["reviewed_by"], d["reviewed_at"] = row[5], row[6]
        if row[7]:
            d["rejection_reason"] = row[7]
        grouped[row[0]]["kyc_docs"].append(d)
    for row in pg.execute("""SELECT customer_id, account_number, product_code, currency, status, opened_at
                             FROM accounts WHERE customer_id = ANY(%s)""", (ids,)):
        grouped[row[0]]["accounts"].append({"account_number": row[1], "product": row[2], "currency": row[3],
                                            "status": row[4], "opened_at": row[5]})
    for row in pg.execute("""SELECT b.customer_id, b.bank_code, k.bank_name, b.account_number, b.account_name
                             FROM beneficiaries b JOIN banks k USING (bank_code) WHERE b.customer_id = ANY(%s)""", (ids,)):
        grouped[row[0]]["beneficiaries"].append({"bank_code": row[1], "bank": row[2], "account_number": row[3],
                                                 "name": row[4]})

    docs = []
    for (cid, bvn, fn, mn, ln, email, phone, dob, tier, status, created) in cust:
        g = grouped[cid]
        name = {"first": fn, "last": ln}
        if mn:
            name["middle"] = mn
        doc = {
            "_id": cid, "bvn": bvn, "name": name, "email": email, "phone": phone,
            "date_of_birth": dt.datetime.combine(dob, dt.time()),
            "kyc": {"tier": tier, "status": status, "documents": g["kyc_docs"]},
            "addresses": g["addresses"],
            "accounts": g["accounts"],          # summaries only — balances stay in PostgreSQL
            "beneficiaries": g["beneficiaries"],
            "devices": [{"device_id": d, "os": rnd.choice(["Android 14", "Android 13", "iOS 17", "iOS 18"]),
                         "first_seen": created} for d in device_for(cid)],
            "preferences": {"language": rnd.choice(["en", "en", "en", "yo", "ha", "ig", "pcm"]),
                            "notify": {"sms": True, "push": rnd.random() < 0.8, "email": rnd.random() < 0.4}},
            "created_at": created, "schema_version": 1,
        }
        # optional attributes only exist where they apply — no NULL columns
        if tier == 3 and cid % 3 == 0:
            doc["business"] = {"name": f"{ln} Ventures", "cac_number": f"RC{100000 + cid}"}
        docs.append(doc)
    for i in range(0, len(docs), 5000):
        db.customers.insert_many(docs[i:i + 5000], ordered=False)
    t1 = time.perf_counter()
    print(f"  customers: {db.customers.count_documents({}):,} documents in {t1 - t0:.1f} s "
          f"(from 6 relational tables: customers, customer_addresses, kyc_documents, staff, accounts, beneficiaries)")

    # ---- transaction events (most recent N transactions, polymorphic payload by channel)
    rows = pg.execute(f"""SELECT t.transaction_id, t.reference, t.transaction_type, t.status, t.amount, t.fee,
                                 t.channel, t.initiated_by, t.created_at, e.nip_session_id, e.response_code, b.bank_code
                          FROM transactions t
                          LEFT JOIN external_transfers e ON e.transaction_id = t.transaction_id
                          LEFT JOIN beneficiaries b ON b.beneficiary_id = e.beneficiary_id
                          WHERE t.initiated_by = ANY(%s)
                          ORDER BY t.created_at DESC LIMIT {args.events}""", (ids,)).fetchall()
    events = []
    for (tid, ref, ttype, status, amt, fee, chan, cid, ts, nip, code, bank) in rows:
        ev = {"ts": ts, "meta": {"customer_id": cid, "channel": chan},
              "reference": ref, "type": ttype, "status": status, "amount": float(amt), "fee": float(fee)}
        if chan == "MOBILE":
            ev["mobile"] = {"device_id": device_for(cid)[0], "app_version": rnd.choice(["4.2.0", "4.2.1", "4.3.0"]),
                            "geo": {"type": "Point", "coordinates": [round(3.3 + rnd.random(), 4), round(6.4 + rnd.random(), 4)]}}
        elif chan == "USSD":
            ev["ussd"] = {"telco": rnd.choice(["MTN", "Airtel", "Glo", "9mobile"]), "short_code": "*7788#",
                          "session_id": f"U{tid}"}
        elif chan == "WEB":
            ev["web"] = {"ip": f"102.89.{tid % 256}.{(tid // 256) % 256}", "browser": rnd.choice(["Chrome", "Safari", "Edge"])}
        else:
            ev["api"] = {"partner_id": rnd.choice(["merchant-001", "payroll-004", "erp-017"])}
        if ttype == "EXTERNAL_TRANSFER":
            ev["nip"] = {"session_id": nip, "response_code": code, "destination_bank": bank}
        events.append(ev)
    for i in range(0, len(events), 10000):
        db.transaction_events.insert_many(events[i:i + 10000], ordered=False)
    print(f"  transaction_events: {db.transaction_events.count_documents({}):,} events in {time.perf_counter() - t1:.1f} s")

    sample = db.customers.find_one({"kyc.documents.1": {"$exists": True}, "business": {"$exists": True}}) \
        or db.customers.find_one({"kyc.documents.1": {"$exists": True}}) or db.customers.find_one()
    print("\n  Example customer document:")
    import pprint
    pprint.pprint(sample, width=110, sort_dicts=False)
    for ch in ("MOBILE", "USSD"):
        ev = db.transaction_events.find_one({"meta.channel": ch}, {"_id": 0})
        print(f"\n  Example {ch} event:")
        pprint.pprint(ev, width=110, sort_dicts=False)


# =========================================================================================
# 3. Validation
# =========================================================================================
def validation():
    header("3. SCHEMA VALIDATION — flexible, but not schemaless")
    if args.mock:
        skipped("$jsonSchema validation")
        return
    bad_docs = [
        ("BVN with 9 digits", {"_id": 999999901, "bvn": "123456789", "name": {"first": "A", "last": "B"},
                               "phone": "+2348011111111", "email": "a@b.example", "kyc": {"tier": 1, "status": "ACTIVE"},
                               "accounts": [], "schema_version": 1}),
        ("KYC tier 7", {"_id": 999999902, "bvn": "29999999902", "name": {"first": "A", "last": "B"},
                        "phone": "+2348011111112", "email": "c@d.example", "kyc": {"tier": 7, "status": "ACTIVE"},
                        "accounts": [], "schema_version": 1}),
        ("missing name", {"_id": 999999903, "bvn": "29999999903", "phone": "+2348011111113", "email": "e@f.example",
                          "kyc": {"tier": 1, "status": "ACTIVE"}, "accounts": [], "schema_version": 1}),
    ]
    for label, doc in bad_docs:
        try:
            db.customers.insert_one(doc)
            print(f"  {label:20} -> ACCEPTED (unexpected)")
        except WriteError as e:
            print(f"  {label:20} -> REJECTED  code {e.code} ({e.details.get('errmsg', '')[:40]})")
    existing = db.customers.find_one({}, {"email": 1})
    try:
        clone = db.customers.find_one({"_id": existing["_id"]})
        clone["_id"], clone["bvn"], clone["phone"] = 999999904, "29999999904", "+2348011111114"
        clone["accounts"] = []
        clone["email"] = existing["email"].upper()
        db.customers.insert_one(clone)
        print("  duplicate email (different case) -> ACCEPTED (unexpected)")
    except DuplicateKeyError:
        print(f"  duplicate email in UPPER CASE -> REJECTED by unique index ux_email_ci (collation strength 2)")
    # schema evolution: v2 documents can add fields without a migration
    print("\n  Schema evolution: a schema_version 2 document with a new 'nin_verified' field is accepted alongside v1:")
    db.customers.update_one({"_id": existing["_id"]}, {"$set": {"schema_version": 2, "nin_verified": True}})
    print(f"  versions present: {sorted(db.customers.distinct('schema_version'))}")


# =========================================================================================
# 4. Queries and aggregations
# =========================================================================================
def queries():
    header("4. QUERIES AND AGGREGATION PIPELINES")
    some = db.customers.find_one({"accounts.0": {"$exists": True}}, {"phone": 1, "accounts": 1})

    print("\n  Q1  Customer-360 lookup by phone (support agent) — ONE read returns the whole profile")
    t0 = time.perf_counter()
    doc = db.customers.find_one({"phone": some["phone"]})
    print(f"      found {doc['name']['first']} {doc['name']['last']} with {len(doc['accounts'])} account(s), "
          f"{len(doc['kyc']['documents'])} KYC doc(s), {len(doc['devices'])} device(s) in {(time.perf_counter() - t0) * 1000:.2f} ms")
    print("      (the same view in PostgreSQL joins 6 tables)")

    print("\n  Q2  Which customer owns account number X? (multikey index on accounts.account_number)")
    acct = some["accounts"][0]["account_number"]
    owner = db.customers.find_one({"accounts.account_number": acct}, {"name": 1})
    print(f"      {acct} -> customer {owner['_id']} {owner['name']['first']} {owner['name']['last']}")

    print("\n  Q3  KYC funnel — documents by type and status ($unwind + $group)")
    for r in db.customers.aggregate([
        {"$unwind": "$kyc.documents"},
        {"$group": {"_id": {"type": "$kyc.documents.type", "status": "$kyc.documents.status"}, "n": {"$sum": 1}}},
        {"$sort": {"_id.type": 1, "_id.status": 1}}]):
        print(f"      {r['_id']['type']:15} {r['_id']['status']:10} {r['n']:>6}")

    print("\n  Q4  Customers by KYC tier, with share that run a business ($group + $cond)")
    for r in db.customers.aggregate([
        {"$group": {"_id": "$kyc.tier", "customers": {"$sum": 1},
                    "businesses": {"$sum": {"$cond": [{"$ifNull": ["$business", False]}, 1, 0]}}}},
        {"$sort": {"_id": 1}}]):
        print(f"      tier {r['_id']}: {r['customers']:>7,} customers, {r['businesses']:>6,} with a business profile")

    print("\n  Q5  FRAUD SIGNAL — devices used by 3 or more different customers ($unwind + $group + $addToSet)")
    for r in db.customers.aggregate([
        {"$unwind": "$devices"},
        {"$group": {"_id": "$devices.device_id", "customers": {"$addToSet": "$_id"}}},
        {"$project": {"n": {"$size": "$customers"}, "customers": {"$slice": ["$customers", 6]}}},
        {"$match": {"n": {"$gte": 3}}},
        {"$sort": {"n": -1}}, {"$limit": 5}]):
        print(f"      {r['_id']:16} shared by {r['n']:>3} customers e.g. {r['customers']}")

    print("\n  Q6  Monthly volume by channel from the time-series events ($match on ts + $group)")
    for r in db.transaction_events.aggregate([
        {"$match": {"status": "SUCCESSFUL", "ts": {"$gte": dt.datetime(2026, 4, 1), "$lt": dt.datetime(2026, 7, 1)}}},
        {"$group": {"_id": {"m": {"$dateToString": {"format": "%Y-%m", "date": "$ts"}}, "ch": "$meta.channel"},
                    "n": {"$sum": 1}, "amount": {"$sum": "$amount"}}},
        {"$sort": {"_id.m": 1, "amount": -1}}]):
        print(f"      {r['_id']['m']}  {r['_id']['ch']:7} {r['n']:>7,} txns  N{r['amount']:>18,.2f}")

    print("\n  Q7  Polymorphic fields: USSD volume by telco (field exists only on USSD events — no schema change needed)")
    for r in db.transaction_events.aggregate([
        {"$match": {"meta.channel": "USSD"}},
        {"$group": {"_id": "$ussd.telco", "n": {"$sum": 1}}}, {"$sort": {"n": -1}}]):
        print(f"      {r['_id']:8} {r['n']:>7,}")

    print("\n  Q8  NIP failures by destination bank (nested sub-document only on external transfers)")
    for r in db.transaction_events.aggregate([
        {"$match": {"type": "EXTERNAL_TRANSFER"}},
        {"$group": {"_id": "$nip.destination_bank", "total": {"$sum": 1},
                    "failed": {"$sum": {"$cond": [{"$eq": ["$status", "FAILED"]}, 1, 0]}}}},
        {"$sort": {"_id": 1}}]):
        print(f"      bank {r['_id']}: {r['total']:>6,} transfers, {r['failed']:>4} failed ({100 * r['failed'] / r['total']:.1f}%)")

    print("\n  Q9  $lookup (join) — last 3 events of one customer with their name. Possible, but it is the")
    print("      exception: the model embeds what is read together so most reads need no join.")
    cid = db.transaction_events.find_one({}, sort=[("ts", -1)])["meta"]["customer_id"]
    for r in db.transaction_events.aggregate([
        {"$match": {"meta.customer_id": cid}}, {"$sort": {"ts": -1}}, {"$limit": 3},
        {"$lookup": {"from": "customers", "localField": "meta.customer_id", "foreignField": "_id", "as": "c"}},
        {"$project": {"_id": 0, "ts": 1, "type": 1, "amount": 1, "name": {"$first": "$c.name.first"}}}]):
        print(f"      {r}")

    print("\n  Q10 TTL index — OTP codes delete themselves 5 minutes after created_at")
    db.otp_codes.insert_one({"customer_id": cid, "code_hash": hashlib.sha256(b"482913").hexdigest()[:16],
                             "purpose": "TRANSFER", "created_at": dt.datetime.now(dt.timezone.utc)})
    print(f"      inserted 1 OTP; index ttl_5_minutes has expireAfterSeconds = "
          f"{db.otp_codes.index_information()['ttl_5_minutes'].get('expireAfterSeconds')}")


def explain():
    header("5. EXPLAIN — index vs collection scan")
    if args.mock:
        skipped("explain()")
        return
    some = db.customers.find_one({}, {"phone": 1, "preferences": 1})

    def summary(cursor_explain):
        ex = cursor_explain["executionStats"]
        stages, p = [], cursor_explain["queryPlanner"]["winningPlan"]
        while p:
            stages.append(p.get("stage"))
            p = p.get("inputStage") or (p.get("inputStages") or [None])[0]
        return (f"stages {' <- '.join(s for s in stages if s)}; keysExamined {ex['totalKeysExamined']:,}; "
                f"docsExamined {ex['totalDocsExamined']:,}; returned {ex['nReturned']:,}; {ex['executionTimeMillis']} ms")

    e1 = db.command("explain", {"find": "customers", "filter": {"phone": some["phone"]}}, verbosity="executionStats")
    print(f"  find by phone (indexed)            : {summary(e1)}")
    e2 = db.command("explain", {"find": "customers", "filter": {"preferences.language": "ha"}}, verbosity="executionStats")
    print(f"  find by preferences.language (not) : {summary(e2)}")
    e3 = db.command("explain", {"find": "customers", "filter": {"devices.device_id": "dev-ring-001"}}, verbosity="executionStats")
    print(f"  find by devices.device_id (multikey): {summary(e3)}")
    stats = db.command("collstats", "customers")
    print(f"\n  customers: {stats['count']:,} docs, avg {stats['avgObjSize']:,} bytes/doc, data {stats['size'] / 1e6:.1f} MB, "
          f"storage {stats['storageSize'] / 1e6:.1f} MB (compressed), indexes {stats['totalIndexSize'] / 1e6:.1f} MB")


if __name__ == "__main__":
    print(f"MongoDB demo — {'mongomock (emulator)' if args.mock else 'MongoDB server ' + client.server_info()['version']}")
    setup()
    migrate()
    validation()
    queries()
    explain()
