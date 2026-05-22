# sqlite3

The friendliest CLI for agents — JSON, CSV, schema introspection all
built in.

## Install

```bash
nix shell nixpkgs#sqlite-interactive
```

## Non-interactive patterns

```bash
# JSON
sqlite3 data.db -json "SELECT id, name FROM users LIMIT 10"

# CSV with headers
sqlite3 data.db -header -csv "SELECT * FROM users" > users.csv

# Run script, stop on error
sqlite3 -batch -bail data.db < migration.sql

# Schema dump
sqlite3 data.db .schema > schema.sql
sqlite3 data.db "SELECT sql FROM sqlite_master WHERE type='table'"
```

## Output modes (`.mode` or `-MODE`)

- `csv`, `tsv`, `json`, `jsonl` (newline-delimited)
- `box`, `table`, `markdown`, `html`
- `insert` (emits INSERT statements)
- `quote`, `line`, `ascii`

## Read-only

```bash
sqlite3 -readonly data.db "SELECT ..."
# Or via URI:
sqlite3 "file:data.db?mode=ro"
```

`db.sh` passes `-readonly` automatically (unless DSN is `sqlite::memory:`).

## EXPLAIN

```bash
sqlite3 data.db "EXPLAIN QUERY PLAN SELECT ..."
sqlite3 data.db "EXPLAIN SELECT ..."   # low-level opcodes
```

## Docs

<https://sqlite.org/cli.html>
