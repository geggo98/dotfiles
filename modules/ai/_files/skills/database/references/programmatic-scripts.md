# Programmatic SQL scripts

When the CLI is insufficient — you need to transform data, join multiple
DBs, or embed logic — write a self-contained script with declared
dependencies.

## scala-cli with Magnum

Scala 3, Magnum as a minimal DB layer, identical JDBC driver as the app.

```scala
//> using scala 3.7
//> using dep com.augustnagro::magnum:2.0.0
//> using dep com.mysql:mysql-connector-j:9.4.0
//> using dep com.zaxxer:HikariCP:7.0.2

import com.augustnagro.magnum.*
import com.zaxxer.hikari.{HikariConfig, HikariDataSource}
import scala.util.Using

val cfg = HikariConfig()
cfg.setJdbcUrl(sys.env("DB_URL"))
cfg.setUsername(sys.env("DB_USER"))
cfg.setPassword(sys.env("DB_PWD"))
cfg.setReadOnly(true)
val ds = HikariDataSource(cfg)

case class BrokerResult(id: Long, carrierId: String, premiumCents: Long) derives DbCodec

Using.resource(ds) { _ =>
  connect(ds):
    val rows = sql"""
      SELECT id, carrier_id, premium_cents
      FROM broker_result
      WHERE created_at > current_date - interval 1 day
    """.query[BrokerResult].run()

    import upickle.default.*
    given ReadWriter[BrokerResult] = macroRW
    println(write(rows))
}
```

Run:

```bash
nix shell nixpkgs#scala-cli
DB_URL=jdbc:mysql://localhost/kfzif DB_USER=stefan DB_PWD=... scala-cli run query.sc
```

Trade-offs: 2–4s cold start; ~1s cached. Coursier cache must be reachable
in CI (pre-run `scala-cli compile query.sc`).

## Python with uv-script header

PEP-723 inline metadata makes Python scripts self-contained.

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "sqlalchemy>=2.0",
#   "pymysql>=1.1",
#   "cryptography>=42",
# ]
# ///
"""Daily report: BrokerResults from the last 24h as JSON."""
from __future__ import annotations

import json, os, sys
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text

engine = create_engine(os.environ["DB_URL"], pool_pre_ping=True, future=True)
since = datetime.utcnow() - timedelta(days=1)

query = text("""
    SELECT id, carrier_id, premium_cents, created_at
    FROM broker_result WHERE created_at >= :since ORDER BY id LIMIT 1000
""")

with engine.connect() as conn:
    conn.execute(text("SET SESSION TRANSACTION READ ONLY"))
    rows = conn.execute(query, {"since": since}).mappings().all()

json.dump([dict(r) for r in rows], sys.stdout, default=str)
sys.stdout.write("\n")
```

Run:

```bash
chmod +x query.py
DB_URL='mysql+pymysql://stefan:pw@localhost/kfzif' ./query.py | jq .
```

First run loads deps to the uv cache (~2s); subsequent runs <500ms.

Driver URLs:

| DB | URL schema | Driver package |
|---|---|---|
| PostgreSQL | `postgresql+psycopg://` | `psycopg[binary]>=3.2` |
| MySQL | `mysql+pymysql://` | `pymysql>=1.1` |
| SQLite | `sqlite:///path` | built-in |
| MSSQL | `mssql+pyodbc://` | `pyodbc` + ODBC driver |
| Oracle | `oracle+oracledb://` | `oracledb` |
| BigQuery | `bigquery://project` | `sqlalchemy-bigquery` |

For agent scripts use `text()` + `.mappings()` — skip the ORM. Alternatives:
`connectorx` (5–10× faster bulk reads), `duckdb` (analytics), `polars`
(DataFrames with SQL).

## jbang with Kotlin

```kotlin
///usr/bin/env jbang "$0" "$@" ; exit $?
//DEPS org.jetbrains.exposed:exposed-core:0.61.0
//DEPS org.jetbrains.exposed:exposed-jdbc:0.61.0
//DEPS com.mysql:mysql-connector-j:9.4.0
//DEPS com.zaxxer:HikariCP:7.0.2

import org.jetbrains.exposed.sql.*
import org.jetbrains.exposed.sql.transactions.transaction
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource

fun main() {
    val cfg = HikariConfig().apply {
        jdbcUrl = System.getenv("DB_URL"); username = System.getenv("DB_USER")
        password = System.getenv("DB_PWD"); isReadOnly = true
    }
    Database.connect(HikariDataSource(cfg))
    transaction {
        exec("SELECT id, carrier_id, premium_cents FROM broker_result LIMIT 10") { rs ->
            while (rs.next()) println("""{"id":${rs.getLong(1)},"carrier":"${rs.getString(2)}","premium":${rs.getLong(3)}}""")
        }
    }
}
```

```bash
DB_URL=jdbc:mysql://localhost/kfzif DB_USER=stefan DB_PWD=... jbang query.kt
```

Use jbang when the team is Kotlin/Java-leaning; otherwise scala-cli is
equivalent.

## When CLI vs script

- **CLI (db.sh)**: one query, ad-hoc results, no transformation logic.
- **Script (uv / scala-cli)**: multi-step pipelines, output massaging,
  re-use with existing app code, JDBC-driver bug reproduction.

## Docs

- <https://scala-cli.virtuslab.org/>
- <https://github.com/AugustNagro/magnum>
- <https://docs.astral.sh/uv/guides/scripts/>
- <https://docs.sqlalchemy.org/en/20/tutorial/>
- <https://www.jbang.dev/documentation/guide/latest/index.html>
