# SQLcl / sqlplus (Oracle)

**SQLcl** is Oracle's modern Java-based CLI. It supersedes `sqlplus`
(Liquibase integration, JSON output, REST endpoints). Always use SQLcl
for new agent work.

## Install

```bash
# sqlcl is unfree, and nixpkgs marks meta.platforms = x86_64-linux only.
# It's pure Java, so it runs on any platform with a JDK — the UNSUPPORTED
# override is safe. --impure lets nix read the NIXPKGS_ALLOW_* env vars.
NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  nix shell --impure nixpkgs#sqlcl
```

## Non-interactive patterns

```bash
# JSON
sqlcl -S stefan/pw@//db:1521/XEPDB1 <<'EOF'
set sqlformat json
set echo off
whenever sqlerror exit failure rollback
SELECT id, name FROM users WHERE rownum <= 10;
EOF

# CSV
echo "set sqlformat csv
SELECT * FROM users;" | sqlcl -S stefan/pw@//db/XEPDB1

# Script
sqlcl -S stefan/pw@//db/XEPDB1 @migration.sql
```

## Output formats (`set sqlformat ...`)

- `csv`, `json`, `json-formatted`, `xml`
- `insert`, `loader`, `fixed`, `text` (default)
- `ansiconsole` (coloured — **not** for scripts)

## Required preamble for scripts

```sql
set echo off
set feedback off
set heading off          -- when sqlformat=csv, suppress header
set termout off
whenever sqlerror exit failure rollback
whenever oserror exit failure
```

## EXPLAIN

```sql
explain plan for SELECT ...;
SELECT * FROM table(dbms_xplan.display(format=>'ALL'));
```

## Connection

`tnsnames.ora` is idiomatic. Easy-connect:
`user/pw@//host:port/service_name`.

## Read-only

`db.sh` prepends `set readonly on;` in `--read-only` mode. This is
advisory — for hard guarantees rely on a least-privilege DB user.

## Docs

- <https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/>
- <https://github.com/oracle/oracle-db-tools/tree/master/sqlcl>
