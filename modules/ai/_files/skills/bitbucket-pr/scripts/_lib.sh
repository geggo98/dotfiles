# _lib.sh — sourced helpers for bitbucket-pr scripts (zsh).
# Not directly executable. Callers `set -eEuo pipefail` and
# `. "${0:A:h}/_lib.sh"`.

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

log_error()   { printf '%sError: %s%s\n' "$RED"    "$1" "$NC" >&2; }
log_info()    { printf '%sInfo: %s%s\n'  "$YELLOW" "$1" "$NC" >&2; }
log_success() { printf '%s%s%s\n'        "$GREEN"  "$1" "$NC"; }

check_prerequisites() {
  local -a missing=()
  command -v "${BITBUCKET_CLI:-bb}" >/dev/null 2>&1 || missing+=("bb (\$BITBUCKET_CLI=${BITBUCKET_CLI:-bb})")
  command -v "${JQ_PATH:-jq}"       >/dev/null 2>&1 || missing+=("jq (\$JQ_PATH=${JQ_PATH:-jq})")
  if (( ${#missing[@]} > 0 )); then
    log_error "Missing prerequisites:"
    local m
    for m in "${missing[@]}"; do
      printf '  - %s\n' "$m" >&2
    done
    exit 2
  fi
}

# warn_if_no_bitbucket_remote — non-fatal heads-up. `bb` resolves the
# workspace/repository from the git remote of $PWD (its --workspace/--repository
# default to "determined from the git configuration"); from a directory with no
# bitbucket.org remote it fails with "Error: Argument repository is missing".
# Always returns 0 — it only warns, never blocks. Run the scripts from inside the
# target repo's working tree, not from the skill directory.
warn_if_no_bitbucket_remote() {
  command -v git >/dev/null 2>&1 || return 0
  local remotes
  remotes=$(git remote -v 2>/dev/null) || true
  if [[ "$remotes" != *bitbucket.org* ]]; then
    log_info "No bitbucket.org git remote in $PWD — bb derives the workspace/repository from the current directory's git remote. Run this from inside the target repo's working tree (do not cd into the skill directory), or pass --workspace/--repository (or set profile defaults)."
  fi
  return 0
}

validate_numeric() {
  [[ "$1" =~ ^[0-9]+$ ]] || { log_error "Invalid $2: '$1' (must be numeric)"; exit 1; }
}

# read_stdin_content — prints stdin content to stdout; exits 1 on TTY/empty.
# Usage:  body="$(read_stdin_content)"
read_stdin_content() {
  if [ -t 0 ]; then
    log_error "This command expects content on stdin (e.g., echo \"text\" | $0 ...)"
    exit 1
  fi
  local content; content=$(cat)
  [[ -n "$content" ]] || { log_error "Received empty content on stdin"; exit 1; }
  printf '%s' "$content"
}

human_bytes() {
  awk -v n="$1" 'BEGIN {
    split("B KiB MiB GiB",u," "); i=1
    while (n>=1024 && i<4){n/=1024; i++}
    if(i==1) printf "%d %s",n,u[i]; else printf "%.1f %s",n,u[i]
  }'
}

# buffer_output --label LABEL --ext EXT [--max-bytes N] [--preview-lines N]
#
# Reads stdin into a tempfile. If the file's size is at most --max-bytes
# (default BB_OUTPUT_MAX_BYTES or 32768), prints it and removes the tempfile.
# Otherwise prints a short header (size, lines, full path) and a preview of
# the first --preview-lines lines (default 10), leaving the file on disk for
# the caller (or agent) to inspect.
#
# Tempfile path: ${TMPDIR:-/tmp}/bb-<label>.XXXXXX.<ext>
buffer_output() {
  local max_bytes="${BB_OUTPUT_MAX_BYTES:-32768}"
  local label="output" ext="json" preview=10
  while (( $# > 0 )); do
    case "$1" in
      --label)         label="$2";     shift 2 ;;
      --ext)           ext="$2";       shift 2 ;;
      --max-bytes)     max_bytes="$2"; shift 2 ;;
      --preview-lines) preview="$2";   shift 2 ;;
      *) log_error "buffer_output: unknown flag $1"; return 1 ;;
    esac
  done

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/bb-${label}.XXXXXX")" || return 1
  mv "$tmp" "${tmp}.${ext}"
  tmp="${tmp}.${ext}"
  cat > "$tmp"

  local size
  size=$(wc -c < "$tmp" | tr -d ' ')
  if (( size <= max_bytes )); then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi

  local lines
  lines=$(wc -l < "$tmp" | tr -d ' ')
  printf -- '--- %s truncated: %s (%s bytes, %s lines); max %s ---\n' \
    "$label" "$(human_bytes "$size")" "$size" "$lines" "$(human_bytes "$max_bytes")"
  printf 'full output written to: %s\n' "$tmp"
  printf 'preview (first %s lines):\n' "$preview"
  head -n "$preview" "$tmp"
  printf -- '--- end preview ---\n'
}
