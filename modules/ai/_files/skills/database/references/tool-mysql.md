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
mysql --defaults-file=~/.my.appdb.cnf \
      -B -N -e "SELECT id, carrier FROM orders LIMIT 10"

# CSV via post-processing (mysql has no native CSV)
mysql --defaults-file=~/.my.cnf -B -N \
      -e "SELECT id, name FROM users" \
      | sed 's/"/""/g;s/\t/","/g;s/^/"/;s/$/"/'

# JSON via JSON_OBJECT
mysql --defaults-file=~/.my.cnf -B -N --raw \
      -e "SELECT JSON_ARRAYAGG(JSON_OBJECT('id',id,'name',name)) FROM users LIMIT 100"

# Run script, stop on first error
mysql --defaults-file=~/.my.cnf --force=false appdb < migration.sql
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

## Troubleshooting `db.sh` with MySQL/MariaDB

| Symptom | Cause | Fix |
|---|---|---|
| `error: no DSN. Set $DB_DSN, …` although you passed `--dsn-cmd` | Older wrapper versions stopped option parsing at the subcommand: `db.sh query --dsn-cmd … "SELECT …"` | Current versions accept options on both sides. Older ones need `db.sh --dsn-cmd … query "SELECT …"` |
| `mysql: unknown variable 'uri=mysql://…'`, exit 7 | Older wrappers passed `--uri=<DSN>`. `--uri` belongs to MySQL Shell. The `mysql`/`mariadb` client rejects it and **prints the whole argument, password included** | Fixed. The wrapper now writes a mode-600 option file and starts `mysql --defaults-extra-file=<file>`. **Rotate any password that this error ever printed** |

Reproduce the old leak without real credentials. No server is needed,
because the error comes from option parsing:

```bash
mysql --uri='mysql://testuser:GEHEIM123@127.0.0.1:3306/testdb' -e 'SELECT 1'
# mysql: unknown variable 'uri=mysql://testuser:GEHEIM123@127.0.0.1:3306/testdb'
```

Check the current wrapper. It must print a connection error and no password:

```bash
${CLAUDE_SKILL_DIR}/scripts/db.sh \
  --dsn 'mysql://testuser:GEHEIM123@127.0.0.1:3306/testdb' query 'SELECT 1'
# ERROR 2002 (HY000): Can't connect to server on '127.0.0.1'
```

The regression test is `modules/ai/_tests/test_database_secrets.py`.
DSN query parameters (`?ssl-mode=…`) are not passed to the client.

## Docs

<https://dev.mysql.com/doc/refman/8.0/en/mysql.html>
