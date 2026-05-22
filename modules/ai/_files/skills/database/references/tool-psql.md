# psql (PostgreSQL)

## Install

```bash
nix shell nixpkgs#postgresql_16   # bundles psql
```

## Non-interactive patterns

```bash
# Safe one-shot: skip rc, stop on error, no password prompt, CSV
psql -X -v ON_ERROR_STOP=1 -w --csv \
     -h db.example.com -U stefan -d kfzif \
     -c "SELECT id, name FROM users WHERE active LIMIT 100"

# Script in a single transaction
psql -X -v ON_ERROR_STOP=1 -w -1 -h db -U stefan -d kfzif -f migration.sql

# JSON via SQL (psql has no --json)
psql -X -A -t -c "SELECT json_agg(t) FROM (SELECT id, name FROM users) t" \
     -h db -U stefan -d kfzif

# Schema dump for inspection
pg_dump --schema-only --no-owner -h db -U stefan -d kfzif > schema.sql

# Machine-readable table list
psql -X -A -t -F $'\t' -c '\dt' -h db -U stefan -d kfzif
```

## Flags

| Flag | Meaning |
|---|---|
| `-X` | Skip `~/.psqlrc` (**required** in scripts) |
| `-A` | Unaligned output (no padding) |
| `-t` | Tuples only — no header, no footer |
| `-F SEP` | Field separator |
| `--csv` | CSV output (PG 12+) |
| `-v ON_ERROR_STOP=1` | Stop on error |
| `-1` | Single transaction for the whole script |
| `-w` | Never prompt for password |
| `-c CMD` | One-shot |
| `-f FILE` | Run script |
| `-q` | Quiet |
| `-P null=NULL` | Render NULL explicitly (else empty string) |

## Connection without password on CLI

- `~/.pgpass` (chmod 600)
- `PGPASSWORD` env (containers OK; risky elsewhere)
- `PGSERVICE` + `~/.pg_service.conf` (idiomatic)
- `PGPASSFILE=/run/secrets/pg.pass` for SOPS/Vault

The `db.sh` wrapper passes `PGAPPNAME=claude-skill-database` so DB-side
audit logs show the source.

## EXPLAIN

```bash
psql -X -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT ..." \
     -h db -U stefan -d kfzif
```

## Read-only

`db.sh` exports `PGOPTIONS="-c default_transaction_read_only=on"`
automatically in `--read-only` mode (default). Equivalent in SQL:
`BEGIN TRANSACTION READ ONLY;`.

## Docs

<https://www.postgresql.org/docs/current/app-psql.html>
