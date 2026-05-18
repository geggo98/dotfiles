#!/usr/bin/env bash

set -euo pipefail

# Bitbucket Pull Request Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.0+) PR operations.
#
# Usage:
#   bitbucket_pr.sh list [state]
#   bitbucket_pr.sh get <pr-id>
#   bitbucket_pr.sh create <title> <source-branch> [destination-branch]   # description via stdin (optional)
#   bitbucket_pr.sh update <pr-id> [--title <new-title>] [--description-from-stdin]
#
# Hidden / dangerous operations (use raw `bb` if you really need them):
#   merge, decline, approve/unapprove, request-changes

BITBUCKET_CLI="${BITBUCKET_CLI:-bb}"
JQ_PATH="${JQ_PATH:-jq}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_error()   { echo -e "${RED}Error: $1${NC}" >&2; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_info()    { echo -e "${YELLOW}Info: $1${NC}" >&2; }

check_prerequisites() {
  local missing=()
  command -v "$BITBUCKET_CLI" >/dev/null 2>&1 || missing+=("Bitbucket CLI ('$BITBUCKET_CLI')")
  command -v "$JQ_PATH"       >/dev/null 2>&1 || missing+=("jq ('$JQ_PATH')")
  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing prerequisites:"
    for tool in "${missing[@]}"; do echo "  - $tool" >&2; done
    exit 2
  fi
}

validate_numeric() {
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    log_error "Invalid $2: '$1' (must be numeric)"
    exit 1
  fi
}

read_stdin_content() {
  # Read all of stdin into the named variable. Caller must check whether
  # stdin was a TTY before invoking (so we never hang waiting for input).
  local __varname="$1"
  local __content
  __content=$(cat)
  if [ -z "$__content" ]; then
    log_error "Received empty content on stdin"
    exit 1
  fi
  printf -v "$__varname" '%s' "$__content"
}

cmd_list() {
  local state="${1:-OPEN}"
  case "$state" in
    OPEN|MERGED|DECLINED|SUPERSEDED) ;;
    *) log_error "Invalid state '$state' (expected OPEN/MERGED/DECLINED/SUPERSEDED)"; exit 1 ;;
  esac

  log_info "Listing $state pull requests..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr list --query "state=\"$state\"" --output json 2>&1); then
    log_error "Failed to list PRs"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_get() {
  local pr_id="$1"
  validate_numeric "$pr_id" "PR ID"

  log_info "Fetching PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr get "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi
  echo "$output"
}

cmd_create() {
  local title="$1" source_branch="$2" dest_branch="${3:-}"
  [ -n "$title" ]         || { log_error "Title is required"; exit 1; }
  [ -n "$source_branch" ] || { log_error "Source branch is required"; exit 1; }

  local -a args=(pr create --title "$title" --source "$source_branch")
  [ -n "$dest_branch" ] && args+=(--destination "$dest_branch")

  if [ ! -t 0 ]; then
    local description
    read_stdin_content description
    args+=(--description "$description")
  fi

  log_info "Creating PR '$title' from $source_branch${dest_branch:+ to $dest_branch}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" --output json 2>&1); then
    log_error "Failed to create PR"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_update() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local new_title="" want_stdin_desc=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)
        [ $# -ge 2 ] || { log_error "--title requires a value"; exit 1; }
        new_title="$2"; shift 2 ;;
      --description-from-stdin)
        want_stdin_desc=true; shift ;;
      *)
        log_error "Unknown update flag: '$1'"
        exit 1 ;;
    esac
  done

  if [ -z "$new_title" ] && [ "$want_stdin_desc" = false ]; then
    log_error "update requires at least --title <t> or --description-from-stdin"
    exit 1
  fi

  local -a args=(pr update "$pr_id")
  [ -n "$new_title" ] && args+=(--title "$new_title")
  if [ "$want_stdin_desc" = true ]; then
    if [ -t 0 ]; then
      log_error "--description-from-stdin expects content on stdin"
      exit 1
    fi
    local description
    read_stdin_content description
    args+=(--description "$description")
  fi

  log_info "Updating PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" --output json 2>&1); then
    log_error "Failed to update PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr.sh <command> [args...]

Commands:
  list [state]                                List PRs (state: OPEN|MERGED|DECLINED|SUPERSEDED, default OPEN)
  get <pr-id>                                 Show one PR as JSON
  create <title> <source-branch> [dest]       Create a PR; description optional via stdin
  update <pr-id> [--title T] [--description-from-stdin]
                                              Update title and/or description (description via stdin)

Hidden (use raw bb if needed): merge, decline, approve, unapprove, request-changes.

Environment:
  BITBUCKET_CLI    Path to bb         (default: bb)
  JQ_PATH          Path to jq         (default: jq)

Exit codes: 0 success, 1 bad args, 2 missing CLI, 3 API/network failure, 4 PR not found.
EOF
}

main() {
  [ $# -ge 1 ] || { log_error "Missing command"; show_usage; exit 1; }
  case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

  check_prerequisites
  local command="$1"; shift

  case "$command" in
    list)   cmd_list   "$@" ;;
    get)    [ $# -ge 1 ] || { log_error "get requires <pr-id>"; exit 1; }
            cmd_get    "$@" ;;
    create) [ $# -ge 2 ] || { log_error "create requires <title> <source-branch>"; exit 1; }
            cmd_create "$@" ;;
    update) [ $# -ge 1 ] || { log_error "update requires <pr-id>"; exit 1; }
            cmd_update "$@" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
