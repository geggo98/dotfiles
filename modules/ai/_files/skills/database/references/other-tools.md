# Other tools worth knowing

## `sq` (sq.io)

CLI in the spirit of `jq` for databases. Pipes between DBs, files, and
JSON.

```bash
nix shell nixpkgs#sq        # if available; otherwise release binary
sq sql 'SELECT * FROM @prod.users' --json
sq inspect @prod.users      # schema
```

Strength: pipelining across heterogeneous sources. Weakness: own DSL
for source aliases. <https://sq.io>

## `pgcli`, `mycli`, `litecli`

Excellent — but **REPL-oriented, not for scripts**. One-shot mode (`-e`)
is equivalent to `psql -c` / `mysql -e`, so no script benefit. Great
for interactive exploration.

## `dbmate`, `golang-migrate`, `Liquibase`, `Flyway`

Migration tools, not query tools. When the agent must apply schema
changes, prefer these over raw DDL — versioned, repeatable, reviewable.

## `osquery`, `steampipe`

SQL over system state (`osquery`) or SaaS APIs (`steampipe`). Not
classical databases; useful as adapters when the agent needs to query
infrastructure.

## `trino` / `presto` CLI

Federated query engine. Worth running when you have many sources to
join *permanently* with dedicated infra. Too heavy for ad-hoc agent use.

## `clickhouse-client`

If ClickHouse is in play (observability, traces): excellent native
client with JSON / CSV / Parquet output. Add to the dispatch table in
`db.sh` if you need it regularly.

## When to integrate vs leave aside

`db.sh` is intentionally narrow. Wrap new tools only when:
- The DSN scheme is well-defined.
- Read-only enforcement is possible (either tool-level or DB-user).
- Output buffers through stdout cleanly.

Otherwise, prefer `${CLAUDE_SKILL_DIR}/scripts/db.sh raw -- <tool> ...`
or a programmatic script (see [`programmatic-scripts.md`](programmatic-scripts.md)).
