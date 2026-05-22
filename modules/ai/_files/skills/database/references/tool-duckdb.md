# DuckDB

DuckDB is not a target database here — it's a **federation query engine**.
From DuckDB you can `ATTACH` PostgreSQL, MySQL, SQLite, Parquet files,
CSVs, JSON, and S3 buckets, then join across them with one SQL query.

## Install

```bash
nix shell nixpkgs#duckdb
```

## Cross-DB join in one shell call

```bash
duckdb -json -c "
INSTALL postgres; LOAD postgres;
INSTALL mysql;    LOAD mysql;

ATTACH 'postgres://stefan@prod/kfzif'     AS pg (READ_ONLY);
ATTACH 'mysql://root@legacy/old_kfzif'    AS my (TYPE mysql, READ_ONLY);

SELECT br.id, br.carrier, lc.legacy_status
FROM pg.brokerresult br
JOIN my.legacy_customers lc ON lc.id = br.customer_id
WHERE br.created_at > '2026-01-01'
LIMIT 100;
"
```

## Output formats

```bash
duckdb -c ".mode json"     -c "SELECT 1"
duckdb -c ".mode csv"      -c "SELECT 1"
duckdb -c ".mode jsonl"    -c "SELECT 1"    # newline-delimited
duckdb -c ".mode markdown" -c "SELECT 1"
```

Or as flags:

```bash
duckdb -json -c "SELECT * FROM read_csv_auto('data.csv') LIMIT 10"
duckdb -csv  -c "..."
```

## Parquet / CSV / JSON files as tables

```bash
duckdb -json -c "
SELECT carrier, count(*) c
FROM read_parquet('s3://bucket/year=2026/*.parquet')
GROUP BY 1 ORDER BY c DESC LIMIT 10
"
```

## Read-only

```bash
duckdb -readonly db.duckdb -c "SELECT ..."
# Or per ATTACH:
duckdb -c "ATTACH 'postgres://...' AS pg (READ_ONLY); SELECT ..."
```

`db.sh` passes `-readonly` automatically (except for `:memory:`).

## EXPLAIN

```bash
duckdb -c "EXPLAIN ANALYZE SELECT ..."
duckdb -c "EXPLAIN (FORMAT JSON) SELECT ..."
```

## When to reach for DuckDB instead of `db.sh query`

- Data sources are heterogeneous (multiple DBs, plus files).
- You need analytical SQL (window functions, aggregations over large data).
- You want to transform **locally** instead of in production.
- You need Parquet/Arrow output.

## Pitfall

Push-down across attached databases is **limited**. Large remote tables
may be transferred entirely over the network.
<https://motherduck.com/blog/duckdb-the-great-federator/>

## Docs

<https://duckdb.org/2024/01/26/multi-database-support-in-duckdb>
