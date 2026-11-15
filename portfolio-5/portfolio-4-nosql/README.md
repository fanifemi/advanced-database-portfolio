# Portfolio 4 — NoSQL and Advanced Data Models

**Case study:** PayHaven (see Portfolio 1). **Stores:** Redis 7 (key-value), MongoDB 7 (document + time-series), with PostgreSQL 16 as the system of record.

## 1. Why NoSQL at all? Polyglot persistence

PostgreSQL is the right home for **money**. It gives ACID transactions, constraints, a double-entry ledger and row locks (Portfolios 1–3). But some PayHaven data has a very different shape or access pattern:

| Data | Access pattern | Best store | Why |
|---|---|---|---|
| Balances, ledger, transfers | Strongly consistent multi-row updates | **PostgreSQL** | ACID, constraints, locks. Nothing here may be lost or approximate |
| Idempotency keys, rate-limit counters, sessions, OTP attempts | Very hot, tiny, short-lived, need atomic counters | **Redis** (key-value, in memory) | Sub-millisecond atomic operations; TTL deletes data automatically |
| App home-screen data | Read on every app open, changes rarely | **Redis** cache | Takes repeated reads off the primary database |
| Leaderboards, notification feeds | Ranked or capped lists | **Redis** sorted sets / lists | Ranking is O(log N), with no `ORDER BY` over a table |
| Customer 360 (profile, KYC docs, devices, accounts, payees) | Read *whole* by support and the app; shape varies (business profiles, new KYC types) | **MongoDB** documents | One read instead of a 6-table join, and the schema can evolve |
| Channel events (USSD session, device, geo, NIP payload) | Append-only, time-ordered, different fields per channel | **MongoDB** time-series | Polymorphic payload, efficient time-bucketed storage |

The rule: **NoSQL stores hold copies, caches and non-monetary data. Money never lives only in a NoSQL store.**

---

## 2. Redis (key-value)

Script: [`redis/redis_patterns.py`](redis/redis_patterns.py). Evidence, **run live** against Redis 7.0: [`evidence/redis_output.txt`](evidence/redis_output.txt)
Prerequisite: Portfolio 2's bulk data is loaded, because R3 and R5 read from it. Run with `docker compose up -d redis`, then `pip install redis "psycopg[binary]"`, then `python redis_patterns.py` (see the script header for the environment variables).

**Key design:** everything uses the namespace `ph:<purpose>:<id>`, for example `ph:session:<token>`, `ph:rl:pin:customer:<id>` and `ph:lb:savings:2026-06`. Every key has a TTL except the leaderboard, which expires at the end of the challenge.

| # | Pattern | Redis structure / commands | Result |
|---|---|---|---|
| R1 | **Idempotency fast-path** | `SET ph:idem:<ref> … NX EX 86400` | 50 concurrent duplicates gave **1 accepted, 49 rejected** |
| R2 | **Rate limiting** (5 wrong PINs / 10 min) | Sorted set as a sliding window, in one **Lua script** (atomic) | Attempts 1–5 allowed, 6–8 blocked with retry-after. 100 concurrent requests against a limit of 10 gave **exactly 10 allowed** |
| R2b | Same limiter **without** Lua | Separate `ZCARD` then `ZADD` | **14 allowed**: a check-then-act race, the same bug as Portfolio 3 E5 |
| R3 | **Cache-aside** home screen | `GET` → on miss query Postgres → `SET … EX 30`; `DEL` after a transfer | Cache hit p50 0.072 ms vs PostgreSQL 0.331 ms (**4.6×**) |
| R4 | **Sessions** | `HSET ph:session:<token>` + `EXPIRE 900`, refreshed on activity | TTL slides back to 900 s on each request. `DEL` on logout |
| R5 | **Leaderboard** (June savings challenge) | `ZINCRBY`, `ZREVRANGE … WITHSCORES`, `ZREVRANK` | 24,612 deposits loaded in 121 ms. Any customer's rank in O(log N) |
| R6 | **Notification feed** | `LPUSH` + `LTRIM 0 19` | Exactly 20 newest kept per customer, so memory is bounded |

**Things to note:**
- **R1 is only a fast-path.** Redis acknowledges writes before they're replicated and persisted, so a key can be lost on failover. The database's UNIQUE constraint on `transactions.reference` (Portfolio 3, E4) is still what guarantees "exactly once".
- **R2 shows why atomicity matters in NoSQL too.** Redis runs each command atomically, but a *sequence* of commands is not atomic. A Lua script, or `MULTI`/`EXEC` with `WATCH`, makes the whole check-and-act one unit.
- **R3's gain is modest on one machine**, because the Postgres query is already well indexed (Portfolio 2). The real value of a cache is **offloading the primary database** during load spikes, such as salary day when every customer opens the app. The cost is **staleness**: the 30 s TTL plus explicit invalidation (`DEL`) after a transfer keep it bounded.
- **Durability and eviction:** `docker-compose.yml` runs Redis with AOF `appendfsync everysec`, so at most about 1 s of writes can be lost. Rate limits and idempotency keys must use `maxmemory-policy noeviction`, because silently evicting a limiter would let attackers through. A pure cache instance would use `allkeys-lru`. In production these would be **separate Redis instances**.

---

## 3. MongoDB (document and time-series)

Script: [`mongodb/mongo_demo.py`](mongodb/mongo_demo.py). It migrates PayHaven's PostgreSQL data into documents, validates, indexes, queries and explains.

### 3.1 Document model

```js
// customers — one document per customer (Customer-360 read model)
{
  _id: 204320,                                   // = customers.customer_id in PostgreSQL
  bvn: "23000000001", phone: "+2348100000001", email: "…",
  name: { first: "Tunde", middle: "…", last: "Okafor" },
  date_of_birth: ISODate(…),
  kyc: { tier: 3, status: "ACTIVE",
         documents: [ { type: "NIN", number: "…", status: "VERIFIED", reviewed_by: "PH-0001", reviewed_at: … } ] },
  addresses:     [ { type: "RESIDENTIAL", line1: "…", city: "Lekki", state: "Lagos" } ],
  accounts:      [ { account_number: "2000000001", product: "PH_TIER3", currency: "NGN", status: "ACTIVE" } ],
  beneficiaries: [ { bank_code: "058", bank: "Guaranty Trust Bank", account_number: "…", name: "…" } ],
  devices:       [ { device_id: "dev-356a192b79", os: "iOS 18", first_seen: … } ],
  preferences:   { language: "yo", notify: { sms: true, push: true, email: false } },
  business:      { name: "Okafor Ventures", cac_number: "RC…" },   // ONLY on business customers
  created_at: …, schema_version: 1
}

// transaction_events — TIME-SERIES collection (timeField: ts, metaField: meta)
{ ts: ISODate(…), meta: { customer_id: 204320, channel: "USSD" },
  reference: "PH-B-00999986", type: "EXTERNAL_TRANSFER", status: "SUCCESSFUL", amount: 1943.32, fee: 10.75,
  ussd:   { telco: "MTN", short_code: "*7788#", session_id: "U…" },          // only USSD events
  nip:    { session_id: "999…", response_code: "00", destination_bank: "058" } } // only external transfers
// a MOBILE event has  mobile: { device_id, app_version, geo: { type: "Point", coordinates: [lng, lat] } }
// a WEB event has     web: { ip, browser }       an API event has  api: { partner_id }
```

### 3.2 Embed or reference? The design decisions

| Relationship | Decision | Reason |
|---|---|---|
| Customer → addresses, KYC documents, devices, preferences | **Embed** | Always read with the customer, owned by the customer, small and bounded (validator caps them, e.g. max 10 KYC docs) |
| Customer → accounts | **Embed a summary** (number, product, status) | Support needs to see them in one read. **Balances are not copied**: they change constantly and PostgreSQL owns them |
| Customer → beneficiaries | **Embed** | Small list, always shown on the transfer screen |
| Customer → transactions | **Reference** (separate `transaction_events` collection, `meta.customer_id`) | Unbounded growth. Embedding would break the 16 MB document limit and rewrite a growing document on every transfer |
| Banks | **Extended reference** (copy `bank` name into each payee) | Bank names almost never change, so duplicating them avoids a `$lookup` |

This is the opposite of Portfolio 1's normalisation. A document is designed around **how the data is read**, not around removing redundancy. The cost is that a bank rename would need an `updateMany`, which is an acceptable trade for an event that almost never happens.

### 3.3 Schema validation, indexes, special collections

- **`$jsonSchema` validator** (strict/error): BVN must be 11 digits, phone must match `+234…`, KYC tier 1–3, status from a fixed list, required fields, array size caps. Flexible doesn't mean schemaless. The script tries three invalid documents, and real MongoDB should reject each one with code 121 (DocumentValidationFailure). Check this in your own run's output.
- **Schema evolution:** a `schema_version: 2` document with a new field lives alongside v1 documents, with no migration or downtime. Readers check `schema_version`.
- **Indexes:** unique `bvn` and `phone`; **case-insensitive unique email** using a collation with strength 2 (the MongoDB equivalent of Portfolio 1's `lower(email)` index); a **multikey** unique index on `accounts.account_number` (finds the owner of any account); a multikey index on `devices.device_id`; a compound index on `kyc.tier + kyc.status`; and a time-series secondary index on `meta.customer_id + ts`.
- **TTL index:** `otp_codes.created_at` with `expireAfterSeconds: 300`. MongoDB deletes expired OTPs automatically.
- **Time-series collection:** events are stored in compressed, time-bucketed chunks grouped by `meta`, which suits append-only, time-range queries.

### 3.4 Queries and aggregation pipelines

| # | Question | Technique |
|---|---|---|
| Q1 | Customer 360 by phone | `find_one` on a unique index, one read instead of a 6-table join |
| Q2 | Who owns account X? | Multikey index on an embedded array |
| Q3 | KYC funnel by document type and status | `$unwind` → `$group` |
| Q4 | Customers per tier, and how many are businesses | `$group` with `$cond` / `$ifNull` on an optional field |
| Q5 | **Fraud signal:** devices shared by 3+ customers | `$unwind` devices → `$group` with `$addToSet` → `$match` on `$size` |
| Q6 | Monthly volume by channel | Time-series `$match` on `ts` → `$group` with `$dateToString` |
| Q7 | USSD volume by telco | Querying a field that exists only on some documents (polymorphism) |
| Q8 | NIP failure rate by destination bank | Conditional sums on a nested sub-document |
| Q9 | Events with customer name | `$lookup`: joins are possible but deliberately rare |
| Q10 | Self-expiring OTPs | TTL index |

Section 5 of the script prints `explain("executionStats")`. You should see **IXSCAN** with about 1 key and 1 document examined for the indexed phone lookup, against **COLLSCAN** over every document for the unindexed `preferences.language` filter. That's the document-store equivalent of Portfolio 2's Index Scan vs Seq Scan.

### 3.5 Evidence status

MongoDB couldn't be installed in the environment where this portfolio was prepared. The script was checked end to end against **mongomock**, an in-memory MongoDB emulator ([`evidence/mongodb_mock_dryrun.txt`](evidence/mongodb_mock_dryrun.txt)), which confirmed the migration and all ten queries. Validation, time-series and `explain()` aren't supported by the emulator, so the final evidence comes from running it on real MongoDB:

```bash
docker compose up -d mongo            # from the repository root
cd portfolio-4-nosql/mongodb
pip install pymongo "psycopg[binary]"
PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres PGDATABASE=payhaven \
MONGO_URL=mongodb://localhost:27017 python mongo_demo.py | tee ../evidence/mongodb_output.txt
```
Then take screenshots of the output and of the collections in MongoDB Compass (optional) and save them in `evidence/`.

---

## 4. Suitability: what NoSQL gains, and what it costs

| | PostgreSQL (P1–P3) | MongoDB | Redis |
|---|---|---|---|
| Data model | Normalised tables, joins | Aggregate documents, read-optimised | Keys → simple structures |
| Schema | Enforced by DDL; changes need migrations | Validator-enforced but evolvable per document | None (the application decides) |
| Transactions | Full ACID, any rows | Atomic per document; multi-document transactions exist but cost more | Atomic per command / Lua script |
| Consistency | Strong | Strong on primary reads (`w: majority`); secondaries may lag | Strong on one node; replicas are asynchronous |
| Scaling | Vertical + read replicas (P5) | Built-in sharding | Cluster sharding by hash slot |
| PayHaven use | Money, the ledger, anything audited | Customer 360, channel events, flexible KYC payloads | Counters, limits, sessions, caches, rankings |

**Why not use MongoDB for the ledger?** A transfer updates two balances and inserts several ledger lines that must all succeed together, under constraints (no overdraft, debits = credits). Every one of those rules is declarative in PostgreSQL. In MongoDB they would be application code inside multi-document transactions. That's possible but more error-prone, and it gives up the database-enforced guarantees that Portfolio 3 relied on.

**A hybrid alternative:** PostgreSQL's `JSONB` type with a GIN index can store flexible payloads, such as raw KYC-provider responses, inside the relational database, keeping ACID and joins. For PayHaven that's a sensible middle ground for semi-structured data that's *tied to monetary rows*. MongoDB earns its place for the large, independent, read-heavy and fast-evolving collections above.

**Keeping copies in sync:** the MongoDB documents are a **read model** derived from PostgreSQL. This portfolio uses a batch migration. In production they'd be kept fresh by **change data capture** (for example Debezium reading the PostgreSQL WAL into Kafka), which makes them **eventually consistent**. That's acceptable for a support screen, but never for a balance check.

## Files

| Path | Contents |
|---|---|
| `redis/redis_patterns.py` | R1–R6, run live |
| `mongodb/mongo_demo.py` | Collections, validator, indexes, migration, Q1–Q10, explain (`--mock` for a dry run) |
| `evidence/redis_output.txt` | Live Redis output |
| `evidence/mongodb_mock_dryrun.txt` | Emulator dry run (3,000 customers, 20,000 events) |
| `evidence/mongodb_output.txt` | *Produce this by running against real MongoDB* |
