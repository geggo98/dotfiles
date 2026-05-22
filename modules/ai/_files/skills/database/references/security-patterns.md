# Security patterns

Three layers of read-only enforcement. Use all three.

## 1. DB user with SELECT-only privileges (mandatory)

Everything below is theatre without this. A least-privilege DB user is
the only defence that survives a wrapper bug.

```sql
-- PostgreSQL
CREATE ROLE claude_agent LOGIN PASSWORD '…';
GRANT CONNECT ON DATABASE kfzif TO claude_agent;
GRANT USAGE ON SCHEMA public TO claude_agent;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO claude_agent;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO claude_agent;

-- MySQL
CREATE USER 'claude_agent'@'%' IDENTIFIED BY '…';
GRANT SELECT ON kfzif.* TO 'claude_agent'@'%';
```

## 2. Tool-level read-only flags

What `db.sh` does in `--read-only` mode (default):

```sql
-- PostgreSQL
BEGIN TRANSACTION READ ONLY;     -- or PGOPTIONS=-c default_transaction_read_only=on
-- MySQL
SET SESSION TRANSACTION READ ONLY;
-- Oracle
SET TRANSACTION READ ONLY;
-- MSSQL
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;   -- best available
```

## 3. Read-only at the script / wrapper level

`db.sh` defaults to `--read-only`. Passing `--write` is the agent's
explicit opt-in. Treat the absence of `--write` as a hard constraint;
the alternative is a buggy LLM running `DROP TABLE` because the prompt
said "clean up".

## Query timeouts

Prevent runaway queries:

```bash
# Per-statement:
PGOPTIONS='-c statement_timeout=30s' psql -c "..."
mysql -e "SET SESSION max_execution_time=30000; SELECT ..."

# Via usql DSN parameter
usql 'pg://user@host/db?statement_timeout=30s' -c "..."

# Wrapper default — gtimeout on the whole pipeline
${CLAUDE_SKILL_DIR}/scripts/db.sh --timeout 30s query "..."
```

## Output limits

`db.sh` and `bq.sh` cap output to 32 KiB by default (`--output-max-bytes`
or `$DB_OUTPUT_MAX_BYTES`). Without this, an agent can flood its context
with megabytes of result data. Inside SQL also use `LIMIT`.

## Audit trail

Mark every agent-issued query so DB-side logs identify the source:

```bash
PGAPPNAME=claude-skill-database psql ...        # db.sh sets this
mysql --connect-attr=program_name=claude-skill ...
```

Combined with read-only DB users, the audit trail tells you exactly
what the agent did and when.

## Never

- Embed plaintext credentials in commit history, even in tests.
- Use `MYSQL_PWD` or `-p<password>` — they leak to `ps` and `~/.bash_history`.
- Run agent queries against production with a write-capable DB user.
- Disable `--maximum_bytes_billed` for BigQuery. The wrapper refuses.
