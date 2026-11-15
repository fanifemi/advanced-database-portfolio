# Advanced Database Systems Portfolio — MIT 8103

**Student:** Fanike Femi
**Programme:** Master of Information Technology, 2026/2027 First Semester
**Case study:** **PayHaven**, a simulated Nigerian digital bank and payments platform (wallets, internal and NIP transfers, savings, tiered KYC). All five portfolio activities use this case study.

| # | Activity | Folder | Status |
|---|---|---|---|
| 1 | Database Design and Modelling | [portfolio-1-database-design](portfolio-1-database-design/) | ✅ Complete |
| 2 | Query Processing and Optimisation | [portfolio-2-query-optimisation](portfolio-2-query-optimisation/) | ✅ Complete |
| 3 | Transactions and Concurrency | [portfolio-3-transactions-concurrency](portfolio-3-transactions-concurrency/) | ✅ Complete |
| 4 | NoSQL and Advanced Data Models | [portfolio-4-nosql](portfolio-4-nosql/) | ⏳ |
| 5 | Distributed and Cloud Database | [portfolio-5-distributed-cloud](portfolio-5-distributed-cloud/) | ⏳ |

## Quick start

```bash
docker compose up -d                       # PostgreSQL 16 on localhost:5432 (user/pass: postgres/postgres)
cd portfolio-1-database-design && PGPASSWORD=postgres ./run_all.sh
```

## Tools
PostgreSQL 16 (pg_trgm), Docker, Mermaid (ER diagrams), Python 3 (psycopg, matplotlib) for benchmarks. Further tools are added per portfolio.

## AI-use declaration
AI tools (Claude) were used as a learning aid. They helped with scaffolding, SQL drafting and documentation, as the course guidelines permit. I reviewed, ran and tested all the work, and I can explain it.
