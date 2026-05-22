---
name: database
description: >-
  Non-interactive SQL access to relational and cloud databases from agents:
  PostgreSQL, MySQL/MariaDB, SQLite, MS SQL Server, Oracle, BigQuery,
  MongoDB, DuckDB. Wrappers enforce secret hygiene, 5-minute timeouts,
  output buffering, read-only by default, and mandatory BigQuery cost
  caps. Triggers on: psql, mysql, sqlite, sqlcmd, sqlcl, bq, BigQuery,
  usql, duckdb, mongosh, SQL query, schema introspection, EXPLAIN, query
  plan, ad-hoc database access from an agent.
argument-hint: "<subcommand> [args...] | help"
allowed-tools: >-
  Read(references/*)
  Bash(./scripts/db.sh *)
  Bash(./scripts/bq.sh *)
  Bash(./scripts/db-buffer.sh *)
  Bash(${CLAUDE_SKILL_DIR}/scripts/db.sh *)
  Bash(${CLAUDE_SKILL_DIR}/scripts/bq.sh *)
  Bash(${CLAUDE_SKILL_DIR}/scripts/db-buffer.sh *)
  Read
dependencies: >-
  bash 4+, coreutils (gtimeout), nix. Tool binaries (psql, mysql,
  sqlite3, duckdb, mongosh, sqlcmd, sqlcl, usql, bq, gcloud, jq) are
  AUTO-BOOTSTRAPPED via `nix shell nixpkgs#<pkg>` on first use — agents
  do NOT need to invoke the nix-shell skill manually. If `nix` itself
  is unavailable, the wrappers emit a copy-pasteable
  `nix shell nixpkgs#... --command <script> <args>` template.
---

# Database — non-interactive SQL access for agents

Three wrappers in `scripts/`:

| Wrapper | Purpose |
|---|---|
| [`scripts/db.sh`](scripts/db.sh) | Universal SQL wrapper. Dispatches by DSN scheme. Read-only by default, 5-min timeout, output buffered. |
| [`scripts/bq.sh`](scripts/bq.sh) | BigQuery only. Always sets `--maximum_bytes_billed` (default ≈ 1 EUR). Optional pre-flight `--dry_run`. |
| [`scripts/db-buffer.sh`](scripts/db-buffer.sh) | Ad-hoc output buffer: pipe arbitrary stdout through it; ≤ 32 KiB inlined, larger gets path + preview. |

All three accept `--help`.

## Missing tools? The wrapper bootstraps for you

If `psql`, `bq`, `gcloud`, or any other dependency is missing on `$PATH`,
the wrapper re-execs itself transparently under
`nix shell nixpkgs#<pkg> --command <wrapper> <original args>`. The agent
sees a one-line `note: bootstrapping ...` on stderr and the command
proceeds. First-time bootstrap fetches into the nix store and may take a
minute; subsequent runs reuse the cache.

If `nix` is also missing, the wrapper dies with a copy-pasteable
template — install nix (https://nixos.org/download), or use the
`nix-shell` skill once nix is available.

## Pick a tool

| Use case | Use |
|---|---|
| Read a table from any SQL DB you already have a DSN for | `db.sh query` |
| Inspect schema / list tables | `db.sh schema [table]` |
| Run `EXPLAIN` / `EXPLAIN ANALYZE` | `db.sh explain "<sql>"` |
| Anything BigQuery (cost-sensitive!) | `bq.sh dry-run` then `bq.sh query` |
| Tool-specific flags the wrapper doesn't expose | `db.sh raw -- <native-cli args>` |
| Multi-DB joins, federated queries, Parquet/CSV files as tables | DuckDB (`db.sh --dsn 'duckdb:/path/to.duckdb'` or `raw -- duckdb …`); see [`references/tool-duckdb.md`](references/tool-duckdb.md) |
| Reproduce a JDBC-driver-specific bug from a JVM app | Beeline; see [`references/tool-beeline.md`](references/tool-beeline.md) |
| Scripts with logic, not just SQL | scala-cli or `uv run --script`; see [`references/programmatic-scripts.md`](references/programmatic-scripts.md) |

## Invoke

Canonical patterns (the agent picks one):

```bash
# 1. Read-only query (DSN from an executable secret provider)
${CLAUDE_SKILL_DIR}/scripts/db.sh query \
  --dsn-cmd 'vault kv get -field=dsn kv/db/prod' \
  "SELECT id, email FROM users WHERE active LIMIT 50"

# 2. Schema introspection
${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn-file ~/.config/db/staging.dsn \
  schema users

# 3. BigQuery — always dry-run an unknown query first
${CLAUDE_SKILL_DIR}/scripts/bq.sh dry-run \
  'SELECT user_id FROM `prj.ds.events` WHERE day = "2026-05-01"'

# 4. BigQuery query under the default ≈ 1 EUR cap, ephemeral SA auth
${CLAUDE_SKILL_DIR}/scripts/bq.sh \
  --credentials-file ~/.config/sops-nix/secrets/my-sa.json \
  query 'SELECT user_id FROM `prj.ds.events` WHERE day = "2026-05-01" LIMIT 100'

# 5. Native-CLI passthrough (under the wrapper's timeout)
${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn "$STAGING_DSN" \
  raw -- psql -X -c '\dt+ public.*'
```

The wrappers honor `${CLAUDE_SKILL_DIR}` so the same patterns work whether
the skill is installed at user, project, or plugin scope.

## Connection & secrets

Never put plaintext passwords in commands, environment, or shell history.
Sources are tried in this order; first non-empty wins:

1. `--dsn-cmd 'CMD'` — wrapper runs CMD; uses its stdout as the DSN.
2. `--dsn-file PATH` — read DSN from a file (mode 600 recommended).
3. `--dsn 'URL'` — literal DSN on the CLI (**warned** as history-leak).
4. `${DB_DSN}_CMD` env var — wrapper runs the named command.
5. `$DB_DSN` env var — literal env DSN (**warned** as env-leak).

The resolved value is never echoed to stderr, logs, or shell history.
The warning labels reference only the *source name*. Use executable
providers (`vault kv get`, `op item get`, `gcloud auth print-access-token`,
`sops -d --extract …`, `pass show …`) whenever possible.

Full details and per-tool patterns: [`references/secrets-and-connection.md`](references/secrets-and-connection.md).

## Output buffering

Every wrapper captures stdout to a tempfile:

- ≤ 32 KiB (`--output-max-bytes` or `$DB_OUTPUT_MAX_BYTES` to override):
  content is inlined to stdout and the tempfile is removed.
- larger: stdout shows a short header, the absolute tempfile path, and
  the first 20 lines as a preview. **The agent must Read the file path
  explicitly** when it needs the full result.

Pass `--output FILE` to skip the threshold check and write directly to
a chosen path. `scripts/db-buffer.sh` exposes the same logic for any
command (`some-cmd | db-buffer.sh --max-bytes N`).

## BigQuery cost cap (`bq.sh` only)

- `--maximum_bytes_billed` is set on every query. Always.
- Default cap = **214 748 364 800 bytes** (≈ 200 GiB, ≈ 1 EUR at on-demand
  $6.25/TiB and 0.92 USD/EUR).
- Override with `--max-bytes-billed N` or `$BQ_MAX_BYTES_BILLED`.
- A pre-flight `--dry_run` runs by default; if estimated bytes > cap,
  the query is refused before any byte is billed. Disable with `--no-dry-run`.
- Caps above **1 TiB ≈ 5 EUR** require `--confirm-cost` — guards against
  typos like an extra zero.
- Cap raised above the default emits a one-line stderr warning showing
  the new EUR-equivalent.

`bq.sh dry-run "<sql>"` is the agent's friend: zero charge, returns
`{ estimated bytes, estimated cost, cap }` and exits non-zero if over cap.

## BigQuery auth (`bq.sh` only)

`bq.sh` accepts `--credentials-file PATH` (or `$GOOGLE_APPLICATION_CREDENTIALS`)
pointing to a service-account JSON. The wrapper:

1. Creates an isolated `CLOUDSDK_CONFIG` tempdir so user-global gcloud
   state is not touched.
2. Runs `gcloud auth activate-service-account --key-file=...` silently.
3. Derives `--project-id` from the JSON if you didn't pass one.
4. Removes the tempdir on exit (trap).

Without this flag, `bq.sh` falls back to whatever `gcloud` already has
configured (ADC or user login). Only service-account JSONs are
auto-activated; user-credential or impersonation files raise an error.

The path to the key file goes in the agent's prompt; the *contents*
never do.

Background on BigQuery pricing edge-cases (10 MiB minimum per query,
`LIMIT` does not reduce cost, `SELECT *` is the bankruptcy classic,
cache-hit semantics): [`references/bigquery-pricing.md`](references/bigquery-pricing.md).

## Read-only by default

`db.sh` defaults to `--read-only`. Per dialect:

| Dialect | Enforcement |
|---|---|
| psql / postgres | `PGOPTIONS=-c default_transaction_read_only=on` |
| mysql / mariadb | `SET SESSION TRANSACTION READ ONLY;` prepended |
| sqlite3 | `-readonly` flag |
| duckdb | `-readonly` flag (file DSN only) |
| sqlcmd (MSSQL) | warning only — use DB-user permissions |
| sqlcl (Oracle) | `set readonly on;` prepended (advisory) |
| mongosh | refuses to run without `--write`; mongo has no equivalent |
| usql (universal fallback) | warning only — use DB-user permissions |

Pass `--write` to opt into DDL/DML. The wrapper-level enforcement is a
backstop, not a substitute for **least-privilege DB users**. See
[`references/security-patterns.md`](references/security-patterns.md).

## Timeouts

Default 5 minutes. Override with `--timeout DURATION` (any value
`gtimeout`/`timeout` accepts: `90s`, `2m`, `1h`). Exit code 124 ==
killed by timeout.

## All references

| File | Contents |
|---|---|
| [`references/tool-usql.md`](references/tool-usql.md) | Universal CLI for 20+ databases — Go binary, `psql`-style commands |
| [`references/tool-psql.md`](references/tool-psql.md) | PostgreSQL: flags, `~/.pgpass`, EXPLAIN, NULL handling |
| [`references/tool-mysql.md`](references/tool-mysql.md) | MySQL/MariaDB: `--defaults-file`, batch mode, JSON via JSON_OBJECT |
| [`references/tool-sqlite.md`](references/tool-sqlite.md) | SQLite3: `.mode`, `-readonly`, `.schema` |
| [`references/tool-sqlcmd.md`](references/tool-sqlcmd.md) | MS SQL Server: go-sqlcmd, Entra/AAD auth, batch mode |
| [`references/tool-sqlcl.md`](references/tool-sqlcl.md) | Oracle: SQLcl over sqlplus, `set sqlformat json`, tnsnames |
| [`references/tool-bq.md`](references/tool-bq.md) | BigQuery: bq CLI flags, ADC, partitioning + cost mitigations |
| [`references/tool-mongosh.md`](references/tool-mongosh.md) | MongoDB shell: `--eval`, aggregation pipelines, mongoexport |
| [`references/tool-duckdb.md`](references/tool-duckdb.md) | DuckDB: ATTACH for cross-DB joins, Parquet/CSV/S3, JSON output |
| [`references/tool-beeline.md`](references/tool-beeline.md) | Generic JDBC CLI — useful for driver-specific bug reproduction |
| [`references/programmatic-scripts.md`](references/programmatic-scripts.md) | scala-cli + Magnum, `uv run --script` + SQLAlchemy, jbang + Kotlin |
| [`references/output-formats.md`](references/output-formats.md) | JSON vs JSON Lines vs CSV vs TSV vs Parquet for agent consumption |
| [`references/secrets-and-connection.md`](references/secrets-and-connection.md) | Per-tool credential patterns: pgpass, my.cnf, ADC, Vault, SOPS, op |
| [`references/security-patterns.md`](references/security-patterns.md) | Read-only enforcement, query timeouts, output limits, audit trail |
| [`references/bigquery-pricing.md`](references/bigquery-pricing.md) | $6.25/TiB on-demand, dry-run cost calc, partitioning + clustering |
| [`references/other-tools.md`](references/other-tools.md) | sq, pgcli/mycli, dbmate, trino, clickhouse-client, osquery |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Wrapper or tool error |
| 2 | Argument parsing error (rare; usually surfaces as 1) |
| 124 | Killed by gtimeout / timeout |
