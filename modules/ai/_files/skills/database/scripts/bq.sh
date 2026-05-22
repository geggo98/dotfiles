#!/usr/bin/env bash
# bq.sh — Google BigQuery wrapper with mandatory cost cap.
#
# Always sets --maximum_bytes_billed. Default cap ≈ 1 EUR (200 GiB at
# on-demand $6.25/TiB). Raises emit a stderr warning; caps above ≈ 5 EUR
# (1 TiB) require --confirm-cost. Authentication is via gcloud
# Application Default Credentials — there is no secret-resolution chain.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

# Activated service-account keys live in an ephemeral CLOUDSDK_CONFIG that
# the cleanup helper removes when the script exits.
trap cleanup_temp_dirs EXIT

# 1 EUR ≈ 200 GiB at $6.25/TiB (0.92 USD/EUR). 200 * 2^30:
DEFAULT_CAP=214748364800     # ~200 GiB ~ 1 EUR
CONFIRM_THRESHOLD=1099511627776  # 1 TiB ~ 5 EUR

usage() {
  cat <<'EOF'
Usage:
  bq.sh [global-options] <subcommand> [args...]

Subcommands:
  query <sql>           Run a query (always with --maximum_bytes_billed)
  dry-run <sql>         Estimate bytes scanned + cost, no execution
  schema TABLE          bq show --schema --format=prettyjson TABLE
  ls [DATASET]          bq ls [DATASET]
  raw -- <args...>      Pass-through to bq under the timeout
  help                  This message

Global options:
  --project-id P        Or $GOOGLE_PROJECT / $GCP_PROJECT env, or derived
                        from the service-account JSON (see --credentials-file)
  --credentials-file P  Service-account JSON to activate ephemerally. Honors
                        $GOOGLE_APPLICATION_CREDENTIALS as the default.
                        The wrapper creates an isolated CLOUDSDK_CONFIG
                        tempdir, runs `gcloud auth activate-service-account`,
                        and cleans up on exit. User-global gcloud state is
                        not touched. Only service-account JSONs are accepted.
  --max-bytes-billed N  Default 214748364800 (≈ 200 GiB ≈ 1 EUR);
                        or $BQ_MAX_BYTES_BILLED env
  --location LOC        e.g. EU, US, europe-west3
  --use-legacy-sql      Default: --use_legacy_sql=false
  --timeout DURATION    Default 5m
  --output-max-bytes N  Default 32768; or $DB_OUTPUT_MAX_BYTES env
  --output FILE         Write all output to FILE; skip the buffer check
  --format FMT          prettyjson (default) | json | csv. prettyjson
                        produces multi-line indented JSON — the preview
                        emitted when output exceeds --output-max-bytes is
                        meaningful row-by-row instead of one long line.
  --no-dry-run          Skip pre-flight estimate (default: dry-run first)
  --confirm-cost        Required when --max-bytes-billed > ≈ 5 EUR
  -h, --help            This message

Examples:
  ${CLAUDE_SKILL_DIR}/scripts/bq.sh dry-run \
    'SELECT user_id FROM `prj.ds.events` WHERE day = "2026-05-01"'

  # Ephemeral service-account auth (no gcloud config side-effects):
  ${CLAUDE_SKILL_DIR}/scripts/bq.sh \
    --credentials-file ~/.config/sops-nix/secrets/my-sa.json \
    query 'SELECT 1 AS one'

  # Same via env var (e.g. set once in the agent's shell):
  GOOGLE_APPLICATION_CREDENTIALS=~/.config/sops-nix/secrets/my-sa.json \
    ${CLAUDE_SKILL_DIR}/scripts/bq.sh query 'SELECT 1 AS one'

  ${CLAUDE_SKILL_DIR}/scripts/bq.sh --max-bytes-billed 2199023255552 \
    --confirm-cost query 'SELECT count(*) FROM `prj.ds.big`'
EOF
}

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

project_id="${GOOGLE_PROJECT:-${GCP_PROJECT:-}}"
credentials_file="${GOOGLE_APPLICATION_CREDENTIALS:-}"
cap="${BQ_MAX_BYTES_BILLED:-$DEFAULT_CAP}"
location=""
legacy_sql="false"
timeout_dur="5m"
max_bytes="${DB_OUTPUT_MAX_BYTES:-32768}"
output_file=""
format="prettyjson"
do_dry_run=1
confirm_cost=0
subcommand=""
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)        project_id="$2"; shift 2 ;;
    --credentials-file)  credentials_file="$2"; shift 2 ;;
    --max-bytes-billed)  cap="$2"; shift 2 ;;
    --location)          location="$2"; shift 2 ;;
    --use-legacy-sql)    legacy_sql="true"; shift ;;
    --timeout)           timeout_dur="$2"; shift 2 ;;
    --output-max-bytes)  max_bytes="$2"; shift 2 ;;
    --output)            output_file="$2"; shift 2 ;;
    --format)            format="$2"; shift 2 ;;
    --no-dry-run)        do_dry_run=0; shift ;;
    --confirm-cost)      confirm_cost=1; shift ;;
    -h|--help|help)      usage; exit 0 ;;
    query|dry-run|schema|ls|raw)
                         subcommand="$1"; shift; args=("$@"); break ;;
    *)                   die "unknown option or subcommand: $1 (try --help)" ;;
  esac
done

[[ -n "$subcommand" ]] || die "no subcommand given (try --help)"

# ---------------------------------------------------------------------------
# Cost cap validation (run before PATH checks so it works during testing)
# ---------------------------------------------------------------------------

if ! [[ "$cap" =~ ^[0-9]+$ ]]; then
  die "--max-bytes-billed must be a positive integer; got: $cap"
fi
if (( cap <= 0 )); then
  die "--max-bytes-billed must be > 0 (unlimited is never acceptable for an agent)"
fi
if (( cap > CONFIRM_THRESHOLD )) && (( confirm_cost == 0 )); then
  die "cap ${cap} bytes ($(human_bytes "$cap")) exceeds ~5 EUR safety threshold; pass --confirm-cost to allow"
fi
if (( cap > DEFAULT_CAP )); then
  cost_eur="$(awk -v b="$cap" 'BEGIN { printf "%.2f", b / 1099511627776 * 6.25 * 0.92 }')"
  warn_once "cap-raised" "BigQuery cap raised to $(human_bytes "$cap") (~ €${cost_eur})"
fi

require_cmd bq "install google-cloud-sdk"
require_cmd jq "install jq"

# ---------------------------------------------------------------------------
# Ephemeral service-account auth (if a key file was given)
# ---------------------------------------------------------------------------
#
# Triggered by --credentials-file or $GOOGLE_APPLICATION_CREDENTIALS. The
# helper builds an isolated CLOUDSDK_CONFIG tempdir, activates the service
# account inside it, and registers cleanup. If --project-id was omitted,
# we fall back to the project_id field of the key file.

if [[ -n "$credentials_file" ]]; then
  derived_project="$(setup_gcloud_service_account "$credentials_file")"
  [[ -z "$project_id" && -n "$derived_project" ]] && project_id="$derived_project"
fi

# ---------------------------------------------------------------------------
# Common bq flags
# ---------------------------------------------------------------------------

bq_global=(--quiet)
[[ -n "$project_id" ]] && bq_global+=(--project_id="$project_id")
[[ -n "$location" ]]   && bq_global+=(--location="$location")

# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------

dry_run_bytes() {
  local sql="$1"
  local json
  if ! json="$(with_timeout "$timeout_dur" -- bq "${bq_global[@]}" query \
      --use_legacy_sql="$legacy_sql" --dry_run --format=json "$sql" 2>&1)"; then
    printf '%s\n' "$json" >&2
    return 1
  fi
  printf '%s' "$json" | jq -r '.statistics.totalBytesProcessed // "0"'
}

estimate_cost_eur() {
  awk -v b="$1" 'BEGIN { printf "%.4f", b / 1099511627776 * 6.25 * 0.92 }'
}

# ---------------------------------------------------------------------------
# Subcommand runners
# ---------------------------------------------------------------------------

run_dry_run() {
  [[ ${#args[@]} -ge 1 ]] || die "dry-run: missing SQL"
  local sql="${args[0]}"
  local bytes eur
  bytes="$(dry_run_bytes "$sql")"
  eur="$(estimate_cost_eur "$bytes")"
  printf 'estimated bytes: %s (%s)\n' "$bytes" "$(human_bytes "$bytes")"
  printf 'estimated cost:  ≈ €%s\n' "$eur"
  printf 'cap:             %s bytes (%s)\n' "$cap" "$(human_bytes "$cap")"
  if (( bytes > cap )); then
    printf 'over cap by:     %s bytes\n' "$((bytes - cap))" >&2
    return 1
  fi
}

run_query() {
  [[ ${#args[@]} -ge 1 ]] || die "query: missing SQL"
  local sql="${args[0]}"

  if (( do_dry_run == 1 )); then
    local bytes eur
    bytes="$(dry_run_bytes "$sql")"
    eur="$(estimate_cost_eur "$bytes")"
    if (( bytes > cap )); then
      die "dry-run estimate ${bytes} bytes ($(human_bytes "$bytes"), ≈ €${eur}) exceeds cap ${cap} ($(human_bytes "$cap")). Raise --max-bytes-billed or narrow the query."
    fi
    if (( bytes * 2 > cap )); then
      warn_once "near-cap" "dry-run estimate $(human_bytes "$bytes") (≈ €${eur}) is >50% of cap $(human_bytes "$cap")"
    fi
  fi

  with_timeout "$timeout_dur" -- bq "${bq_global[@]}" query \
    --use_legacy_sql="$legacy_sql" \
    --maximum_bytes_billed="$cap" \
    --format="$format" \
    "$sql"
}

run_schema() {
  [[ ${#args[@]} -ge 1 ]] || die "schema: missing TABLE"
  with_timeout "$timeout_dur" -- bq "${bq_global[@]}" show \
    --schema --format=prettyjson "${args[0]}"
}

run_ls() {
  with_timeout "$timeout_dur" -- bq "${bq_global[@]}" ls "${args[@]}"
}

run_raw() {
  [[ ${#args[@]} -ge 1 ]] || die "raw: missing args (try: raw -- show --schema myproject:mydataset.mytable)"
  with_timeout "$timeout_dur" -- bq "${bq_global[@]}" "${args[@]}"
}

producer() {
  case "$subcommand" in
    query)   run_query ;;
    dry-run) run_dry_run ;;
    schema)  run_schema ;;
    ls)      run_ls ;;
    raw)     run_raw ;;
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
  producer 2>&1 | buffer_output --max-bytes "$max_bytes" --label "bq:${subcommand}" --preview-lines 20
fi
