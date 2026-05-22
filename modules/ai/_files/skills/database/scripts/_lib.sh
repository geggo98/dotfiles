# shellcheck shell=bash
# _lib.sh — sourced helpers for the `database` skill. Not directly executable.
#
# Provides: die, with_timeout, resolve_secret, buffer_output, human_bytes,
# detect_timeout, warn_once.
#
# Callers are expected to `set -eEuo pipefail` themselves and source this
# file with `. "$SCRIPT_DIR/_lib.sh"`.

# ---------------------------------------------------------------------------
# Error reporting
# ---------------------------------------------------------------------------

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# warn_once <key> <message>
# Print message to stderr at most once per process per key.
__WARNED_KEYS=" "
warn_once() {
  local key="$1"; shift
  case "$__WARNED_KEYS" in
    *" $key "*) return 0 ;;
  esac
  __WARNED_KEYS="${__WARNED_KEYS}${key} "
  printf 'warning: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Timeout
# ---------------------------------------------------------------------------

detect_timeout() {
  if command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  else
    return 1
  fi
}

# with_timeout <duration> -- <cmd> [args...]
#
# Runs the command under gtimeout/timeout, returning that tool's exit
# status (124 = killed by timeout). If neither tool is installed, runs
# the command directly and warns once.
with_timeout() {
  local duration="$1"
  shift
  [[ "${1:-}" == "--" ]] || die "with_timeout: expected '--' after duration"
  shift

  local to_bin
  if to_bin="$(detect_timeout)"; then
    "$to_bin" "$duration" "$@"
  else
    warn_once timeout "neither gtimeout nor timeout on PATH; running without timeout (asked for ${duration})"
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Secret resolution
# ---------------------------------------------------------------------------

# resolve_secret <flags...>
#
# Walk a precedence chain and print the first non-empty secret to stdout.
# The resolved value is never echoed to stderr. Literal sources warn
# once on stderr (only the source *name* is shown — never the value).
#
# Flags (any subset; checked in this order):
#   --cli-cmd CMD         Run CMD with sh -c; use its stdout.       (silent)
#   --cli-file PATH       Read file at PATH (mode 600 expected).    (warn if !600)
#   --cli-literal VALUE   Use VALUE as-is.                          (warns about CLI)
#   --env-cmd NAME        Look up env var NAME, treat as shell cmd. (silent)
#   --env NAME            Look up env var NAME, use value as-is.    (warns about env)
#   --file PATH           Same as --cli-file but for a default path.(warn if !600)
#
# Empty result is allowed (caller decides what to do).
resolve_secret() {
  local cli_cmd="" cli_file="" cli_literal="" env_cmd_name="" env_name="" file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli-cmd)     cli_cmd="$2";     shift 2 ;;
      --cli-file)    cli_file="$2";    shift 2 ;;
      --cli-literal) cli_literal="$2"; shift 2 ;;
      --env-cmd)     env_cmd_name="$2"; shift 2 ;;
      --env)         env_name="$2";    shift 2 ;;
      --file)        file="$2";        shift 2 ;;
      *) die "resolve_secret: unknown flag: $1" ;;
    esac
  done

  if [[ -n "$cli_cmd" ]]; then
    sh -c "$cli_cmd"
    return
  fi
  if [[ -n "$cli_file" ]]; then
    __read_secret_file "$cli_file"
    return
  fi
  if [[ -n "$cli_literal" ]]; then
    # Only warn when the value plausibly carries credentials (host part or
    # explicit password/token kv-pair). Local paths and in-memory DSNs are
    # harmless and shouldn't trigger noise.
    case "$cli_literal" in
      *@*|*password=*|*pwd=*|*token=*|*secret=*)
        warn_once "literal-cli" "literal secret passed on CLI — visible in shell history" ;;
    esac
    printf '%s' "$cli_literal"
    return
  fi
  if [[ -n "$env_cmd_name" ]]; then
    local cmd="${!env_cmd_name-}"
    if [[ -n "$cmd" ]]; then
      sh -c "$cmd"
      return
    fi
  fi
  if [[ -n "$env_name" ]]; then
    local val="${!env_name-}"
    if [[ -n "$val" ]]; then
      case "$val" in
        *@*|*password=*|*pwd=*|*token=*|*secret=*)
          warn_once "literal-env-${env_name}" "secret read from \$${env_name} (env var); prefer ${env_name}_CMD with an executable provider" ;;
      esac
      printf '%s' "$val"
      return
    fi
  fi
  if [[ -n "$file" && -r "$file" ]]; then
    __read_secret_file "$file"
    return
  fi
  return 0
}

__read_secret_file() {
  local path="$1"
  [[ -r "$path" ]] || die "secret file not readable: $path"
  local mode
  if command -v stat >/dev/null 2>&1; then
    # macOS: stat -f %Lp; GNU: stat -c %a. Try both.
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null || true)"
    if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
      warn_once "perm-${path}" "secret file mode is ${mode}; recommend chmod 600 ${path}"
    fi
  fi
  # Strip trailing newline only; preserve internal whitespace.
  local content
  content="$(cat "$path")"
  printf '%s' "$content"
}

# ---------------------------------------------------------------------------
# Output buffering
# ---------------------------------------------------------------------------

# human_bytes <integer>
# Emit a short human-readable byte count (1024-based).
human_bytes() {
  awk -v n="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ")
    i = 1
    while (n >= 1024 && i < 6) { n /= 1024; i++ }
    if (i == 1) { printf "%d %s", n, u[i] } else { printf "%.1f %s", n, u[i] }
  }'
}

# buffer_output --max-bytes N --label TEXT --preview-lines N
#
# Reads stdin to a tempfile in $TMPDIR. If size <= N, prints the file
# content to stdout and deletes the file. Otherwise prints a short
# header + path + preview, and leaves the file on disk for the caller.
#
# Caller is responsible for `set -o pipefail` if it wants the producer's
# exit code to propagate through the pipeline.
buffer_output() {
  local max_bytes="${DB_OUTPUT_MAX_BYTES:-32768}"
  local label="output"
  local preview_lines=20

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-bytes)     max_bytes="$2";     shift 2 ;;
      --label)         label="$2";         shift 2 ;;
      --preview-lines) preview_lines="$2"; shift 2 ;;
      *) die "buffer_output: unknown flag: $1" ;;
    esac
  done

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/db-out.XXXXXX")"
  cat > "$tmp"

  local size
  size="$(wc -c < "$tmp" | tr -d ' ')"

  if (( size <= max_bytes )); then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi

  local lines
  lines="$(wc -l < "$tmp" | tr -d ' ')"

  {
    printf -- '--- %s truncated: %s (%s bytes, %s lines); max %s ---\n' \
      "$label" "$(human_bytes "$size")" "$size" "$lines" "$(human_bytes "$max_bytes")"
    printf 'full output written to: %s\n' "$tmp"
    printf 'preview (first %s lines):\n' "$preview_lines"
    head -n "$preview_lines" "$tmp"
    printf -- '--- end preview ---\n'
  }
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# require_cmd <name> [hint]
# Die with a friendly message if the named command is missing on PATH.
require_cmd() {
  local name="$1"
  local hint="${2-}"
  if ! command -v "$name" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die "$name not found on PATH ($hint)"
    else
      die "$name not found on PATH"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Tempdir cleanup registry
# ---------------------------------------------------------------------------
#
# Callers wanting auto-cleaned tempdirs append paths to __CLEANUP_DIRS and
# arrange `trap cleanup_temp_dirs EXIT`. Helpers like
# setup_gcloud_service_account rely on this.

__CLEANUP_DIRS=()

cleanup_temp_dirs() {
  local d
  for d in "${__CLEANUP_DIRS[@]-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}

# ---------------------------------------------------------------------------
# gcloud service-account activation (ephemeral, side-effect-free)
# ---------------------------------------------------------------------------
#
# setup_gcloud_service_account <key-file>
#
# Validates that <key-file> is a service-account JSON, creates an isolated
# CLOUDSDK_CONFIG tempdir (so user-global gcloud state is untouched),
# activates the service account quietly, and registers the tempdir for
# cleanup via cleanup_temp_dirs. Exports CLOUDSDK_CONFIG so subsequent
# `gcloud` and `bq` invocations in the same process tree pick it up.
# Prints the project_id from the JSON on stdout so callers can use it
# as a fallback when --project-id was not given.
setup_gcloud_service_account() {
  local key_file="$1"
  [[ -r "$key_file" ]] || die "credentials file not readable: $key_file"
  require_cmd jq     "needed to validate service-account JSON"
  require_cmd gcloud "install google-cloud-sdk"

  local key_type
  key_type="$(jq -r '.type // empty' "$key_file" 2>/dev/null || true)"
  if [[ "$key_type" != "service_account" ]]; then
    die "credentials file is not a service-account JSON (type='${key_type:-?}'); only service accounts are auto-activated"
  fi

  local cfg
  cfg="$(mktemp -d "${TMPDIR:-/tmp}/gcloud-svc.XXXXXX")"
  __CLEANUP_DIRS+=("$cfg")
  export CLOUDSDK_CONFIG="$cfg"

  if ! gcloud auth activate-service-account --key-file="$key_file" --quiet >/dev/null 2>&1; then
    die "gcloud auth activate-service-account failed for $key_file (check key permissions / network)"
  fi

  jq -r '.project_id // empty' "$key_file" 2>/dev/null || true
}
