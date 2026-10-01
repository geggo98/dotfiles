#!/usr/bin/env bash
# db.sh — universal non-interactive SQL wrapper.
#
# Dispatches by DSN scheme to psql / mysql / sqlite3 / duckdb / mongosh /
# sqlcmd / sqlcl / usql, with secret resolution that keeps passwords out
# of the LLM context, a default 5-minute timeout, read-only by default,
# and output buffered through scripts/db-buffer.sh.

set -eEuo pipefail

# Captured for ensure_pkgs to re-exec us under `nix shell` when needed.
__ORIGINAL_ARGV=("$@")

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

Global options (before the subcommand; also accepted directly after it):
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

Secrets: the DSN password never goes on the client's command line (0600 file
or the tool's own env var instead), and all stdout/stderr is run through
scripts/redact.pl. A literal --dsn is still visible in *this* script's argv.
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
  ${CLAUDE_SKILL_DIR}/scripts/db.sh \
    --dsn-cmd 'vault kv get -field=dsn kv/db/prod' \
    query "SELECT id, email FROM users WHERE active LIMIT 50"

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
rest=()

need_value() { [[ $# -ge 2 ]] || die "option $1 needs a value"; }

# parse_opts <argv...>
# Consumes global options from the front; leaves the remainder in rest[].
# Only exact option names match, so SQL starting with "-- comment" is safe.
parse_opts() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dsn)              need_value "$@"; dsn_cli="$2";     shift 2 ;;
      --dsn-cmd)          need_value "$@"; dsn_cli_cmd="$2"; shift 2 ;;
      --dsn-file)         need_value "$@"; dsn_file="$2";    shift 2 ;;
      --dsn-env)          need_value "$@"; dsn_env="$2";     shift 2 ;;
      --timeout)          need_value "$@"; timeout_dur="$2"; shift 2 ;;
      --output-max-bytes) need_value "$@"; max_bytes="$2";   shift 2 ;;
      --output)           need_value "$@"; output_file="$2"; shift 2 ;;
      --format)           need_value "$@"; format="$2";      shift 2 ;;
      --read-only)        mode="read-only"; shift ;;
      --write)            mode="write";     shift ;;
      --no-rc)            no_rc=1;          shift ;;
      -h|--help)          usage; exit 0 ;;
      *)                  break ;;
    esac
  done
  rest=("$@")
}

parse_opts "$@"
set -- "${rest[@]+"${rest[@]}"}"
[[ $# -gt 0 ]] || die "no subcommand given (try --help)"
case "$1" in
  help)                    usage; exit 0 ;;
  query|schema|explain|raw) subcommand="$1"; shift ;;
  *)                       die "unknown option or subcommand: $1 (try --help)" ;;
esac
# `raw` forwards everything after it to the native command.
if [[ "$subcommand" == "raw" ]]; then
  # gtimeout would take a leading "--" for the command itself.
  [[ "${1-}" == "--" ]] && shift
  args=("$@")
else
  parse_opts "$@"
  [[ "${rest[0]-}" == "--" ]] && rest=("${rest[@]:1}")
  args=("${rest[@]+"${rest[@]}"}")
fi

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

# ---------------------------------------------------------------------------
# Redaction and credential hand-off
# ---------------------------------------------------------------------------

trap cleanup_temp_dirs EXIT
trap 'exit 143' TERM INT HUP
with_secret_tmpdir
secret_dir="$__SECRET_DIR"

parsed=0
parse_dsn "$DSN" && parsed=1
if [[ -n "$DSN_PASS" ]]; then
  add_redact_secret "$DSN_PASS"
  add_redact_secret "$DSN"
fi
need_parts() {
  [[ "$parsed" -eq 1 ]] || die "$dialect: DSN must be a URL like scheme://user:password@host:port/db"
}

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

# pgpass_escape: ":" and "\" are the field separator and escape in a .pgpass line
pgpass_escape() { local v="${1//\\/\\\\}"; printf '%s' "${v//:/\\:}"; }

# mycnf_quote: double-quoted value of a MySQL option file
mycnf_quote() { local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }

run_psql() {
  ensure_pkgs psql postgresql
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
  # Password through a 0600 .pgpass file; psql only understands the
  # postgres(ql):// schemes, so "pg://" is rewritten as well.
  local target="$DSN"
  if [[ "$parsed" -eq 1 ]]; then
    target="postgresql://${DSN_NOPASS#*://}"
    if [[ -n "$DSN_PASS" ]]; then
      ( umask 077; printf '*:*:*:*:%s\n' "$(pgpass_escape "$DSN_PASS")" > "$secret_dir/pgpass" )
      export PGPASSFILE="$secret_dir/pgpass"
    fi
  fi
  with_timeout "$timeout_dur" -- psql "${flags[@]}" -c "$sql" "$target"
}

run_mysql() {
  ensure_pkgs mysql mysql-client
  need_parts
  local sql="$1"
  local -a flags=(--batch --skip-column-names --connect-timeout=10)
  [[ "$mode" == "read-only" ]] && sql="SET SESSION TRANSACTION READ ONLY; $sql"
  case "$format" in
    csv|tsv|json|native|*) : ;;  # mysql -B is TSV; no native JSON/CSV
  esac
  [[ -z "$DSN_QUERY" ]] || warn_once mysql-query "mysql: DSN query parameters are not passed to the client"
  # mysql has no --uri (that is MySQL Shell) and rejects it with an error
  # that echoes the whole argument. Credentials go through an option file.
  # --defaults-file / --defaults-extra-file must be the first option.
  local host="${DSN_HOST#[}"; host="${host%]}"
  local cnf="$secret_dir/my.cnf"
  (
    umask 077
    {
      printf '[client]\n'
      [[ -n "$DSN_USER" ]] && printf 'user=%s\n' "$(mycnf_quote "$DSN_USER")"
      [[ -n "$DSN_PASS" ]] && printf 'password=%s\n' "$(mycnf_quote "$DSN_PASS")"
      [[ -n "$host" ]]     && printf 'host=%s\n' "$(mycnf_quote "$host")"
      [[ -n "$DSN_PORT" ]] && printf 'port=%s\n' "$DSN_PORT"
    } > "$cnf"
  )
  local cfg="--defaults-extra-file=$cnf"
  [[ "$no_rc" -eq 1 ]] && cfg="--defaults-file=$cnf"
  with_timeout "$timeout_dur" -- mysql "$cfg" "${flags[@]}" -e "$sql" ${DSN_DB:+"$DSN_DB"}
}

run_sqlite() {
  ensure_pkgs sqlite3 sqlite-interactive
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
  ensure_pkgs duckdb duckdb
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
  ensure_pkgs mongosh mongosh
  [[ "$mode" == "write" ]] || die "mongosh wrapper requires --write (mongo has no session-level read-only)"
  # The URI travels in the environment: `mongosh <uri>` would put it in argv.
  export DB_MONGO_URI="$DSN"
  with_timeout "$timeout_dur" -- mongosh --nodb --quiet \
    --eval "db = connect(process.env.DB_MONGO_URI); $1"
}

run_mssql() {
  ensure_pkgs sqlcmd go-sqlcmd
  need_parts
  local sql="$1"
  local server="tcp:${DSN_HOST}${DSN_PORT:+,$DSN_PORT}"
  local -a flags=(-b -h -1 -W -y 0 -S "$server")
  [[ -n "$DSN_USER" ]] && flags+=(-U "$DSN_USER")
  [[ -n "$DSN_DB" ]]   && flags+=(-d "$DSN_DB")
  # go-sqlcmd reads the password from SQLCMDPASSWORD; -P would show in argv.
  [[ -n "$DSN_PASS" ]] && export SQLCMDPASSWORD="$DSN_PASS"
  case "$format" in
    csv) flags+=(-s ',') ;;
    tsv) flags+=(-s $'\t') ;;
    native|*) ;;
  esac
  with_timeout "$timeout_dur" -- sqlcmd "${flags[@]}" -Q "SET NOCOUNT ON; $sql"
}

run_oracle() {
  export NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
  ensure_pkgs sqlcl sqlcl
  need_parts
  local sql="$1"
  # The connect line goes through stdin; a connect string in argv would show
  # in `ps`. The password is quoted so "@" and "/" in it survive.
  local pw="${DSN_PASS//\"/\"\"}"
  local conn="connect ${DSN_USER}/\"${pw}\"@//${DSN_HOST}${DSN_PORT:+:$DSN_PORT}${DSN_DB:+/$DSN_DB}"
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
  script="$(printf '%s\n' "$conn"; printf '%s;\n' "${preamble[@]}"; printf '%s;\nexit\n' "$sql")"
  printf '%s' "$script" | with_timeout "$timeout_dur" -- sqlcl -S /nolog
}

run_usql() {
  ensure_pkgs usql usql
  local sql="$1"
  local -a flags=(-w -v ON_ERROR_STOP=1)
  [[ "$no_rc" -eq 1 ]] && flags+=(-X)
  case "$format" in
    json) flags+=(-J) ;;
    csv)  flags+=(-C) ;;
    tsv)  flags+=(--field-separator $'\t') ;;
    native|*) ;;
  esac
  # Password through a 0600 pass file (protocol:host:port:db:user:password).
  local target="$DSN"
  if [[ "$parsed" -eq 1 ]]; then
    target="$DSN_NOPASS"
    if [[ -n "$DSN_PASS" ]]; then
      ( umask 077; printf '*:*:*:*:*:%s
' "$(pgpass_escape "$DSN_PASS")" > "$secret_dir/usqlpass" )
      export USQLPASS="$secret_dir/usqlpass"
    fi
  fi
  with_timeout "$timeout_dur" -- usql "${flags[@]}" -c "$sql" "$target"
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

# Every byte the wrapper emits is filtered, results and errors alike: we
# cannot reliably tell the two apart.
if [[ -n "$output_file" ]]; then
  rc=0
  producer 2>"$secret_dir/stderr" | redact_stream > "$output_file" || rc=$?
  redact_stream < "$secret_dir/stderr" >&2
  [[ "$rc" -eq 0 ]] || exit "$rc"
  printf 'wrote output to %s\n' "$output_file"
else
  producer 2>&1 | redact_stream | buffer_output --max-bytes "$max_bytes" --label "$dialect" --preview-lines 20
fi
