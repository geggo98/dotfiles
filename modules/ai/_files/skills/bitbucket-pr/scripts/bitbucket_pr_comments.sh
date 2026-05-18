#!/usr/bin/env bash

set -euo pipefail

# Bitbucket PR Comments Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.0+) PR comment operations.
#
# Usage:
#   bitbucket_pr_comments.sh list    <pr-id>
#   bitbucket_pr_comments.sh get     <pr-id> <comment-id>
#   bitbucket_pr_comments.sh create  <pr-id> [--file PATH --line N] [--parent CID]   # body via stdin
#   bitbucket_pr_comments.sh update  <pr-id> <comment-id>                            # new body via stdin
#   bitbucket_pr_comments.sh resolve <pr-id> <comment-id>
#   bitbucket_pr_comments.sh reopen  <pr-id> <comment-id>
#
# Hidden / dangerous operations (use raw `bb` if needed): delete.

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
  local __varname="$1"
  if [ -t 0 ]; then
    log_error "This command expects comment body on stdin (e.g., echo \"text\" | $0 ...)"
    exit 1
  fi
  local __content
  __content=$(cat)
  if [ -z "$__content" ]; then
    log_error "Received empty content on stdin"
    exit 1
  fi
  printf -v "$__varname" '%s' "$__content"
}

cmd_list() {
  local pr_id="$1"
  validate_numeric "$pr_id" "PR ID"

  log_info "Fetching comments for PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment list --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch comments for PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output" | "$JQ_PATH" 'map({id, content, inline})'
}

cmd_get() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  log_info "Fetching comment #$comment_id from PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment get "$comment_id" --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch comment #$comment_id from PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi
  echo "$output" | "$JQ_PATH" -r '.content'
}

cmd_create() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local file="" line="" parent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)   [ $# -ge 2 ] || { log_error "--file requires PATH";   exit 1; }; file="$2";   shift 2 ;;
      --line)   [ $# -ge 2 ] || { log_error "--line requires N";      exit 1; }; line="$2";   shift 2 ;;
      --parent) [ $# -ge 2 ] || { log_error "--parent requires CID";  exit 1; }; parent="$2"; shift 2 ;;
      *) log_error "Unknown create flag: '$1'"; exit 1 ;;
    esac
  done
  [ -z "$line"   ] || validate_numeric "$line"   "line number"
  [ -z "$parent" ] || validate_numeric "$parent" "parent comment ID"
  if [ -n "$line" ] && [ -z "$file" ]; then
    log_error "--line requires --file (inline comments need a file path)"
    exit 1
  fi

  local body
  read_stdin_content body

  local -a args=(pr comment create --pullrequest "$pr_id" --comment "$body")
  [ -n "$file"   ] && args+=(--file   "$file")
  [ -n "$line"   ] && args+=(--line   "$line")
  [ -n "$parent" ] && args+=(--parent "$parent")

  log_info "Creating comment on PR #$pr_id${file:+ on $file${line:+:$line}}${parent:+ (reply to $parent)}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" --output json 2>&1); then
    log_error "Failed to create comment on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_update() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  local body
  read_stdin_content body

  log_info "Updating comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment update "$comment_id" \
                  --pullrequest "$pr_id" --comment "$body" --output json 2>&1); then
    log_error "Failed to update comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_resolve() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  log_info "Resolving comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment resolve "$comment_id" --pullrequest "$pr_id" 2>&1); then
    log_error "Failed to resolve comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_reopen() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  log_info "Reopening comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment reopen "$comment_id" --pullrequest "$pr_id" 2>&1); then
    log_error "Failed to reopen comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr_comments.sh <command> <pr-id> [args...]

Commands:
  list    <pr-id>                                       JSON array of {id,content,inline} for all comments
  get     <pr-id> <comment-id>                          Raw markdown of one comment
  create  <pr-id> [--file PATH --line N] [--parent CID] Body via stdin; --file/--line for inline; --parent for replies
  update  <pr-id> <comment-id>                          New body via stdin
  resolve <pr-id> <comment-id>                          Mark comment as resolved
  reopen  <pr-id> <comment-id>                          Reopen a resolved comment

Hidden (use raw bb if needed): delete.

Environment:
  BITBUCKET_CLI    Path to bb         (default: bb)
  JQ_PATH          Path to jq         (default: jq)

Exit codes: 0 success, 1 bad args, 2 missing CLI, 3 API/network failure, 4 not found.
EOF
}

main() {
  [ $# -ge 1 ] || { log_error "Missing command"; show_usage; exit 1; }
  case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

  check_prerequisites
  local command="$1"; shift
  [ $# -ge 1 ] || { log_error "$command requires at least <pr-id>"; show_usage; exit 1; }

  case "$command" in
    list)    cmd_list    "$@" ;;
    get)     [ $# -ge 2 ] || { log_error "get requires <pr-id> <comment-id>";     exit 1; }
             cmd_get     "$@" ;;
    create)  cmd_create  "$@" ;;
    update)  [ $# -ge 2 ] || { log_error "update requires <pr-id> <comment-id>";  exit 1; }
             cmd_update  "$@" ;;
    resolve) [ $# -ge 2 ] || { log_error "resolve requires <pr-id> <comment-id>"; exit 1; }
             cmd_resolve "$@" ;;
    reopen)  [ $# -ge 2 ] || { log_error "reopen requires <pr-id> <comment-id>";  exit 1; }
             cmd_reopen  "$@" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
