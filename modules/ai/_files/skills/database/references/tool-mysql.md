# mysql-client (MySQL / MariaDB)

## Install

```bash
nix shell nixpkgs#mysql-client      # vanilla MySQL
# or:
nix shell nixpkgs#mariadb-client
```

## Non-interactive patterns

```bash
# Batch mode (TSV), connection file
mysql --defaults-file=~/.my.kfzif.cnf \
      -B -N -e "SELECT id, carrier FROM brokerresult LIMIT 10"

# CSV via post-processing (mysql has no native CSV)
mysql --defaults-file=~/.my.cnf -B -N \
      -e "SELECT id, name FROM users" \
      | sed 's/"/""/g;s/\t/","/g;s/^/"/;s/$/"/'

# JSON via JSON_OBJECT
mysql --defaults-file=~/.my.cnf -B -N --raw \
      -e "SELECT JSON_ARRAYAGG(JSON_OBJECT('id',id,'name',name)) FROM users LIMIT 100"

# Run script, stop on first error
mysql --defaults-file=~/.my.cnf --force=false kfzif < migration.sql
```

## Flags

| Flag | Meaning |
|---|---|
| `-B`, `--batch` | Batch mode (TSV) |
| `-N`, `--skip-column-names` | No header |
| `--raw` | No escape processing |
| `--silent` (`-s`) | Less chatter |
| `--quick` | Stream rather than buffer |
| `--force=false` | **Required** — stop at first error (default is `true`!) |
| `--defaults-file=PATH` | Credentials from file |
| `-e SQL` | One-shot |

## Connection without password on CLI

- `~/.my.cnf` with `[client] password=...` (chmod 600)
- `mysql_config_editor` (encrypted)
- `MYSQL_PWD` env (logs leak — avoid)

## EXPLAIN

```bash
mysql --defaults-file=~/.my.cnf -e "EXPLAIN FORMAT=JSON SELECT ..." | jq .
mysql --defaults-file=~/.my.cnf -e "EXPLAIN ANALYZE SELECT ..."   # MySQL 8.0.18+
```

## Pitfall

Default `--force=true` makes scripts continue past errors. Always pass
`--force=false` in CI / agent contexts.

## Read-only

`db.sh` prepends `SET SESSION TRANSACTION READ ONLY;` in `--read-only`
mode (default).

## Docs

<https://dev.mysql.com/doc/refman/8.0/en/mysql.html>
