#!/usr/bin/env bash

set -euo pipefail

# Bitbucket PR Tasks Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.0+) PR task operations.
# Tasks are work items attached to a PR or to a specific comment; in v0.18.0
# they can be marked RESOLVED/UNRESOLVED via `bb pr task update --state`.
#
# Usage:
#   bitbucket_pr_tasks.sh list    <pr-id>
#   bitbucket_pr_tasks.sh get     <pr-id> <task-id>
#   bitbucket_pr_tasks.sh create  <pr-id> [--comment <comment-id>]   # content via stdin
#   bitbucket_pr_tasks.sh update  <pr-id> <task-id>                  # new content via stdin
#   bitbucket_pr_tasks.sh resolve <pr-id> <task-id>
#   bitbucket_pr_tasks.sh reopen  <pr-id> <task-id>
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
    log_error "This command expects task content on stdin (e.g., echo \"text\" | $0 ...)"
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

  log_info "Fetching tasks for PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task list --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch tasks for PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_get() {
  local pr_id="$1" task_id="$2"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  log_info "Fetching task #$task_id from PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task get "$task_id" --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch task #$task_id from PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi
  echo "$output"
}

cmd_create() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local comment_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --comment)
        [ $# -ge 2 ] || { log_error "--comment requires <comment-id>"; exit 1; }
        comment_id="$2"; shift 2 ;;
      *)
        log_error "Unknown create flag: '$1'"
        exit 1 ;;
    esac
  done
  [ -z "$comment_id" ] || validate_numeric "$comment_id" "comment ID"

  local content
  read_stdin_content content

  local -a args=(pr task create --pullrequest "$pr_id" --content "$content")
  [ -n "$comment_id" ] && args+=(--comment "$comment_id")

  log_info "Creating task on PR #$pr_id${comment_id:+ (attached to comment $comment_id)}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" --output json 2>&1); then
    log_error "Failed to create task on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_update() {
  local pr_id="$1" task_id="$2"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  local content
  read_stdin_content content

  log_info "Updating task #$task_id content on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task update "$task_id" \
                  --pullrequest "$pr_id" --content "$content" --output json 2>&1); then
    log_error "Failed to update task #$task_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

cmd_set_state() {
  local pr_id="$1" task_id="$2" state="$3"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  log_info "Setting task #$task_id on PR #$pr_id to $state..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task update "$task_id" \
                  --pullrequest "$pr_id" --state "$state" --output json 2>&1); then
    log_error "Failed to set task #$task_id state to $state on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  echo "$output"
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr_tasks.sh <command> <pr-id> [args...]

Commands:
  list    <pr-id>                              JSON array of all tasks on a PR
  get     <pr-id> <task-id>                    JSON of one task
  create  <pr-id> [--comment <comment-id>]     Content via stdin; --comment attaches to a comment
  update  <pr-id> <task-id>                    New content via stdin (text only — does not change state)
  resolve <pr-id> <task-id>                    Mark task as RESOLVED (done)
  reopen  <pr-id> <task-id>                    Mark task as UNRESOLVED (reopen)

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
    get)     [ $# -ge 2 ] || { log_error "get requires <pr-id> <task-id>";     exit 1; }
             cmd_get     "$@" ;;
    create)  cmd_create  "$@" ;;
    update)  [ $# -ge 2 ] || { log_error "update requires <pr-id> <task-id>";  exit 1; }
             cmd_update  "$@" ;;
    resolve) [ $# -ge 2 ] || { log_error "resolve requires <pr-id> <task-id>"; exit 1; }
             cmd_set_state "$1" "$2" "RESOLVED" ;;
    reopen)  [ $# -ge 2 ] || { log_error "reopen requires <pr-id> <task-id>";  exit 1; }
             cmd_set_state "$1" "$2" "UNRESOLVED" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
