#!/usr/bin/env bash
# db.sh — universal non-interactive SQL wrapper.
#
# Dispatches by DSN scheme to psql / mysql / sqlite3 / duckdb / mongosh /
# sqlcmd / sqlcl / usql, with secret resolution that keeps passwords out
# of the LLM context, a default 5-minute timeout, read-only by default,
# and output buffered through scripts/db-buffer.sh.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

usage() {
  cat <<'EOF'
Usage:
  db.sh [global-options] <subcommand> [args...]

Subcommands:
  query <sql>            Run a one-shot SQL statement
  schema [pattern]       Schema introspection (best-effort per dialect)
  explain <sql>          Plan / EXPLAIN
  raw -- <cmd...>        Pass-through under the timeout (no formatting)
  help                   This message

Global options:
  --dsn-cmd 'CMD'        Resolve DSN by running CMD; capture stdout
  --dsn-file PATH        Read DSN from a file (mode 600 recommended)
  --dsn URL              Literal DSN (visible in shell history — warns)
  --dsn-env NAME         Env var holding the DSN (default: DB_DSN). If
                         NAME_CMD is also set, the _CMD form wins.
  --timeout DURATION     Default 5m
  --output-max-bytes N   Default 32768; or DB_OUTPUT_MAX_BYTES env
  --output FILE          Write all output to FILE; skip the buffer check
  --format FMT           native (default) | json | csv | tsv
  --read-only            Default. Dialect-specific read-only wrapping.
  --write                Allow writes. Required for mongosh.
  --no-rc                Skip user rc files (~/.psqlrc, ~/.my.cnf, ...)
  -h, --help             This message

DSN schemes → tools:
  pg|postgres|postgresql:// → psql
  mysql|mariadb://          → mysql
  sqlite|sqlite3:           → sqlite3
  duckdb:    or path *.duckdb → duckdb
  mongodb://                → mongosh
  mssql|sqlserver://        → sqlcmd
  oracle://                 → sql (SQLcl)
  bigquery://               → rejected — use bq.sh
  *                         → usql

Examples:
  ${CLAUDE_SKILL_DIR}/scripts/db.sh query \
    --dsn-cmd 'vault kv get -field=dsn kv/db/prod' \
    "SELECT id, email FROM users WHERE active LIMIT 50"

  ${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn 'sqlite::memory:' \
    query "SELECT 1 AS one"

  ${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn-file ~/.config/db/staging.dsn \
    schema users

  ${CLAUDE_SKILL_DIR}/scripts/db.sh --dsn "$STAGING_DSN" \
    raw -- psql -X -c '\dt+ public.*'
EOF
}

# ---------------------------------------------------------------------------
# Parse global flags
# ---------------------------------------------------------------------------

timeout_dur="5m"
max_bytes="${DB_OUTPUT_MAX_BYTES:-32768}"
output_file=""
format="native"
mode="read-only"
no_rc=0
dsn_cli=""
dsn_cli_cmd=""
dsn_file=""
dsn_env="DB_DSN"
subcommand=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dsn)              dsn_cli="$2";     shift 2 ;;
    --dsn-cmd)          dsn_cli_cmd="$2"; shift 2 ;;
    --dsn-file)         dsn_file="$2";    shift 2 ;;
    --dsn-env)          dsn_env="$2";     shift 2 ;;
    --timeout)          timeout_dur="$2"; shift 2 ;;
    --output-max-bytes) max_bytes="$2";   shift 2 ;;
    --output)           output_file="$2"; shift 2 ;;
    --format)           format="$2";      shift 2 ;;
    --read-only)        mode="read-only"; shift ;;
    --write)            mode="write";     shift ;;
    --no-rc)            no_rc=1;          shift ;;
    -h|--help|help)     usage; exit 0 ;;
    query|schema|explain|raw)
                        subcommand="$1"; shift; args=("$@"); break ;;
    *)                  die "unknown option or subcommand: $1 (try --help)" ;;
  esac
done

[[ -n "$subcommand" ]] || die "no subcommand given (try --help)"

# ---------------------------------------------------------------------------
# Resolve DSN
# ---------------------------------------------------------------------------

DSN="$(resolve_secret \
  --cli-cmd     "$dsn_cli_cmd" \
  --cli-file    "$dsn_file" \
  --cli-literal "$dsn_cli" \
  --env-cmd     "${dsn_env}_CMD" \
  --env         "$dsn_env")"

[[ -n "$DSN" ]] || die "no DSN. Set \$$dsn_env, \$${dsn_env}_CMD, --dsn-cmd, --dsn-file, or --dsn"

# ---------------------------------------------------------------------------
# Determine dialect
# ---------------------------------------------------------------------------

scheme="${DSN%%:*}"
case "$scheme" in
  pg|postgres|postgresql) dialect=postgres ;;
  mysql|mariadb)          dialect=mysql ;;
  sqlite|sqlite3)         dialect=sqlite ;;
  duckdb)                 dialect=duckdb ;;
  mongodb)                dialect=mongo ;;
  mssql|sqlserver)        dialect=mssql ;;
  oracle)                 dialect=oracle ;;
  bigquery|bq)            die "DSN scheme '$scheme' — use scripts/bq.sh for BigQuery (cost-cap enforcement)" ;;
  *)
    case "$DSN" in
      *.db|*.sqlite|*.sqlite3) dialect=sqlite ;;
      *.duckdb)                dialect=duckdb ;;
      *)                       dialect=usql ;;
    esac
    ;;
esac

# Warn (once) for dialects where the wrapper can't enforce read-only itself.
case "$dialect:$mode" in
  mongo:read-only|mssql:read-only|oracle:read-only|usql:read-only)
    if [[ "$subcommand" == "query" || "$subcommand" == "explain" ]]; then
      warn_once "ro-$dialect" "$dialect: wrapper cannot enforce session-level read-only; rely on DB-user permissions. Pass --write to acknowledge."
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Per-dialect runners. Each calls the underlying binary under with_timeout.
# ---------------------------------------------------------------------------

strip_scheme() { local v="$1"; v="${v#*:}"; printf '%s' "${v#//}"; }

run_psql() {
  require_cmd psql "install postgresql client"
  local sql="$1"
  local -a flags=(-X -A -w -v ON_ERROR_STOP=1)
  case "$format" in
    json) sql="SELECT json_agg(t) FROM ($sql) t" ;;
    csv)  flags+=(--csv) ;;
    tsv)  flags+=(-F $'\t') ;;
    native|*) ;;
  esac
  if [[ "$mode" == "read-only" ]]; then
    export PGOPTIONS="${PGOPTIONS-} -c default_transaction_read_only=on"
  fi
  export PGAPPNAME=claude-skill-database
  with_timeout "$timeout_dur" -- psql "${flags[@]}" -c "$sql" "$DSN"
}

run_mysql() {
  require_cmd mysql "install mysql or mariadb client"
  local sql="$1"
  local -a flags=(--batch --skip-column-names --connect-timeout=10)
  [[ "$no_rc" -eq 1 ]] && flags+=(--no-defaults)
  [[ "$mode" == "read-only" ]] && sql="SET SESSION TRANSACTION READ ONLY; $sql"
  case "$format" in
    csv|tsv|json|native|*) : ;;  # mysql -B is TSV; no native JSON/CSV
  esac
  with_timeout "$timeout_dur" -- mysql "${flags[@]}" --uri="$DSN" -e "$sql"
}

run_sqlite() {
  require_cmd sqlite3 "install sqlite-interactive"
  local sql="$1"
  local path
  path="$(strip_scheme "$DSN")"
  local -a flags=(-batch -bail)
  [[ "$mode" == "read-only" && "$path" != ":memory:" ]] && flags+=(-readonly)
  case "$format" in
    json) flags+=(-json) ;;
    csv)  flags+=(-csv -header) ;;
    tsv)  flags+=(-separator $'\t' -header) ;;
    native|*) ;;
  esac
  with_timeout "$timeout_dur" -- sqlite3 "${flags[@]}" "$path" "$sql"
}

run_duckdb() {
  require_cmd duckdb "install duckdb"
  local sql="$1"
  local path
  path="$(strip_scheme "$DSN")"
  local -a flags=()
  [[ "$mode" == "read-only" && -n "$path" && "$path" != ":memory:" ]] && flags+=(-readonly)
  case "$format" in
    json)  flags+=(-json) ;;
    csv)   flags+=(-csv) ;;
    tsv)   flags+=(-separator $'\t') ;;
    native|*) ;;
  esac
  if [[ -n "$path" && "$path" != ":memory:" ]]; then
    with_timeout "$timeout_dur" -- duckdb "${flags[@]}" "$path" -c "$sql"
  else
    with_timeout "$timeout_dur" -- duckdb "${flags[@]}" -c "$sql"
  fi
}

run_mongo() {
  require_cmd mongosh "install mongodb-shell"
  [[ "$mode" == "write" ]] || die "mongosh wrapper requires --write (mongo has no session-level read-only)"
  with_timeout "$timeout_dur" -- mongosh "$DSN" --quiet --eval "$1"
}

run_mssql() {
  require_cmd sqlcmd "install go-sqlcmd"
  local sql="$1"
  # Parse mssql://user:pw@host:port/db
  local rest="${DSN#*://}"
  local userpass="" hostdb="$rest"
  if [[ "$rest" == *@* ]]; then
    userpass="${rest%%@*}"
    hostdb="${rest#*@}"
  fi
  local user="" pass=""
  if [[ -n "$userpass" ]]; then
    user="${userpass%%:*}"
    [[ "$userpass" == *:* ]] && pass="${userpass#*:}"
  fi
  local host_port="${hostdb%%/*}"
  local db=""
  [[ "$hostdb" == */* ]] && db="${hostdb#*/}"
  local -a flags=(-b -h -1 -W -y 0 -S "tcp:$host_port")
  [[ -n "$user" ]] && flags+=(-U "$user")
  [[ -n "$pass" ]] && flags+=(-P "$pass")
  [[ -n "$db" ]]   && flags+=(-d "$db")
  case "$format" in
    csv) flags+=(-s ',') ;;
    tsv) flags+=(-s $'\t') ;;
    native|*) ;;
  esac
  with_timeout "$timeout_dur" -- sqlcmd "${flags[@]}" -Q "SET NOCOUNT ON; $sql"
}

run_oracle() {
  require_cmd sql "install sqlcl"
  local sql="$1"
  local rest="${DSN#oracle://}"
  local userpass="${rest%%@*}"
  local hostservice="${rest#*@}"
  local conn="${userpass}@//${hostservice}"
  local -a preamble=(
    "set echo off"
    "set feedback off"
    "set heading off"
    "set termout off"
    "whenever sqlerror exit failure rollback"
    "whenever oserror exit failure"
  )
  case "$format" in
    json) preamble+=("set sqlformat json") ;;
    csv)  preamble+=("set sqlformat csv") ;;
    native|tsv|*) ;;
  esac
  [[ "$mode" == "read-only" ]] && preamble+=("set readonly on")
  local script
  script="$(printf '%s;\n' "${preamble[@]}"; printf '%s;\nexit\n' "$sql")"
  printf '%s' "$script" | with_timeout "$timeout_dur" -- sql -S "$conn"
}

run_usql() {
  require_cmd usql "install usql"
  local sql="$1"
  local -a flags=(-w -v ON_ERROR_STOP=1)
  [[ "$no_rc" -eq 1 ]] && flags+=(-X)
  case "$format" in
    json) flags+=(-J) ;;
    csv)  flags+=(-C) ;;
    tsv)  flags+=(--field-separator $'\t') ;;
    native|*) ;;
  esac
  with_timeout "$timeout_dur" -- usql "${flags[@]}" -c "$sql" "$DSN"
}

# ---------------------------------------------------------------------------
# Subcommand → SQL helpers
# ---------------------------------------------------------------------------

build_schema_sql() {
  local pattern="${1:-}"
  case "$dialect" in
    postgres) [[ -n "$pattern" ]] && printf '\\d+ %s' "$pattern" || printf '\\dt+ public.*' ;;
    mysql)    [[ -n "$pattern" ]] && printf 'SHOW CREATE TABLE %s' "$pattern" || printf 'SHOW TABLES' ;;
    sqlite)   [[ -n "$pattern" ]] && printf '.schema %s' "$pattern" || printf '.schema' ;;
    duckdb)   [[ -n "$pattern" ]] && printf 'DESCRIBE %s' "$pattern" || printf 'SHOW TABLES' ;;
    mssql)    [[ -n "$pattern" ]] && printf "EXEC sp_help '%s'" "$pattern" || printf "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES" ;;
    oracle)   [[ -n "$pattern" ]] && printf 'DESCRIBE %s' "$pattern" || printf 'SELECT table_name FROM user_tables' ;;
    *)        die "schema subcommand not implemented for $dialect; use 'raw'" ;;
  esac
}

build_explain_sql() {
  local sql="$1"
  case "$dialect" in
    postgres) printf 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) %s' "$sql" ;;
    mysql)    printf 'EXPLAIN FORMAT=JSON %s' "$sql" ;;
    sqlite)   printf 'EXPLAIN QUERY PLAN %s' "$sql" ;;
    duckdb)   printf 'EXPLAIN ANALYZE %s' "$sql" ;;
    mssql)    printf 'SET SHOWPLAN_XML ON; %s' "$sql" ;;
    oracle)   printf 'EXPLAIN PLAN FOR %s; SELECT * FROM table(dbms_xplan.display)' "$sql" ;;
    *)        die "explain subcommand not implemented for $dialect; use 'raw'" ;;
  esac
}

dispatch_query() {
  local sql="$1"
  case "$dialect" in
    postgres) run_psql   "$sql" ;;
    mysql)    run_mysql  "$sql" ;;
    sqlite)   run_sqlite "$sql" ;;
    duckdb)   run_duckdb "$sql" ;;
    mongo)    run_mongo  "$sql" ;;
    mssql)    run_mssql  "$sql" ;;
    oracle)   run_oracle "$sql" ;;
    usql|*)   run_usql   "$sql" ;;
  esac
}

producer() {
  case "$subcommand" in
    query)
      [[ ${#args[@]} -ge 1 ]] || die "query: missing SQL"
      dispatch_query "${args[0]}"
      ;;
    schema)
      dispatch_query "$(build_schema_sql "${args[0]:-}")"
      ;;
    explain)
      [[ ${#args[@]} -ge 1 ]] || die "explain: missing SQL"
      dispatch_query "$(build_explain_sql "${args[0]}")"
      ;;
    raw)
      [[ ${#args[@]} -ge 1 ]] || die "raw: missing command (try: raw -- psql -c '...')"
      with_timeout "$timeout_dur" -- "${args[@]}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

set -o pipefail

if [[ -n "$output_file" ]]; then
  producer > "$output_file"
  printf 'wrote output to %s\n' "$output_file"
else
  producer 2>&1 | buffer_output --max-bytes "$max_bytes" --label "$dialect" --preview-lines 20
fi
