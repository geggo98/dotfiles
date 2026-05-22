# usql

Go binary modelled on `psql`. Covers 20+ databases (PostgreSQL, MySQL,
SQLite, Oracle, MSSQL, BigQuery, Snowflake, Redshift, ClickHouse,
CockroachDB, …). The universal fallback for `db.sh`.

## Install

```bash
nix shell nixpkgs#usql
```

Avoid distro builds with CGO linkage for Oracle/MSSQL — prefer the
static release binary from <https://github.com/xo/usql/releases>.

## Non-interactive patterns

```bash
# JSON output
usql -J -c "SELECT id, name FROM users LIMIT 10" pg://stefan@host/db

# CSV
usql -C -c "SELECT * FROM brokerresult WHERE created_at > current_date - 1" \
     my://root:pw@db:3306/kfzif > today.csv

# Script file, stop at first error
usql -v ON_ERROR_STOP=1 -f migrations/001-add-index.sql pg://stefan@host/db

# Backslash commands work in `-c`
usql -c '\d brokerresult' my://root@host/kfzif
usql -c '\dt+ public.*'   pg://stefan@host/db
usql -c '\df'             pg://stefan@host/db   # functions

# Plan
usql -c 'EXPLAIN ANALYZE SELECT ...' pg://...
usql -c 'EXPLAIN FORMAT=JSON SELECT ...' my://...

# Cross-DB copy (built-in)
usql -c "\copy 'pg://prod/kfzif' 'my://stage/kfzif' \
         'SELECT * FROM brokerresult LIMIT 1000' \
         'INSERT INTO brokerresult_sample'"
```

## Flags relevant to agents

| Flag | Meaning |
|---|---|
| `-c CMD` | One-shot command |
| `-f FILE` | Run script file |
| `-J` | JSON output |
| `-C` | CSV output |
| `-q` | Quiet (no banner) |
| `-X` | Skip `~/.usqlrc` |
| `-v ON_ERROR_STOP=1` | Stop at first error |
| `--field-separator='|'` | Custom delimiter |
| `-w` | Never prompt for password (**required** in scripts) |

## Pitfalls

- No `--read-only` flag — enforce via DB-user permissions.
- EXPLAIN output is raw; no visualisation.
- URL-encode special characters in DSN passwords.

## Docs

<https://github.com/xo/usql>
<https://github.com/xo/usql#database-support>
