# Beeline (JDBC)

Generic JDBC CLI from the Hive project. Give it a JDBC URL and a driver
JAR and you have a SQL REPL against *anything* that speaks JDBC. The
value for agents: the **identical JDBC driver** as your Spring /
Hibernate application — useful for reproducing driver-specific bugs
(timezones, BLOB handling, connection-pool behaviour).

## Install

```bash
nix shell nixpkgs#hive
# Alternatively via jbang or a Maven download.
```

## Non-interactive use

```bash
beeline --silent=true \
        -d com.mysql.cj.jdbc.Driver \
        -u "jdbc:mysql://localhost:3306/kfzif" \
        -n stefan -p geheim \
        --outputformat=csv2 \
        -e "SELECT id, carrier FROM brokerresult LIMIT 10"

beeline --silent=true --force=false \
        -u "jdbc:postgresql://localhost/kfzif" \
        -n stefan \
        -f migrations/001.sql
```

## Output formats

- `table` (default; ASCII — agent-useless)
- `vertical`
- `xmlattr`, `xmlelements`
- `csv`, `tsv` (with quoting), `dsv` (custom delimiter)
- `csv2`, `tsv2` (no quoting — cleaner)

## Flags

| Flag | Meaning |
|---|---|
| `--silent=true` | No connection banner |
| `--showHeader=false` | Drop header row |
| `--outputformat=csv2` | CSV without quotes |
| `--force=false` | Stop on error (default!) |
| `-e SQL` | One-shot |
| `-f FILE` | Script |

## Driver classpath

```bash
export HIVE_AUX_JARS_PATH=/path/to/postgresql-42.7.0.jar:/path/to/mysql-connector-j-9.4.0.jar
beeline -d org.postgresql.Driver -u "jdbc:postgresql://..." -e "SELECT 1"
```

## Limits

- Clunky UX from Hive heritage.
- You must source driver JARs yourself.
- No native JSON output.
- No `\d` equivalent — introspect via SQL against `information_schema`.

## Docs

<https://cwiki.apache.org/confluence/display/Hive/HiveServer2+Clients>
