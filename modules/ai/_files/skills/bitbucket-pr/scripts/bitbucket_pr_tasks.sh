#!/bin/zsh
# Bitbucket PR Tasks Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.1+) PR task operations.
# Tasks are work items attached to a PR or to a specific comment; in v0.18.0
# they can be marked RESOLVED/UNRESOLVED via `bb pr task update --state`.
#
# NOTE: `bb pr task update --help` claims --state can be needs_work/complete/
# pending, but those are WRONG — the Bitbucket Cloud API only accepts
# RESOLVED/UNRESOLVED. Do not change the resolve/reopen mapping below to match
# the help text.
#
# Usage:
#   bitbucket_pr_tasks.sh list    <pr-id> [--format json|tsv]
#   bitbucket_pr_tasks.sh get     <pr-id> <task-id>
#   bitbucket_pr_tasks.sh create  <pr-id> [--comment <comment-id>]   # content via stdin
#   bitbucket_pr_tasks.sh update  <pr-id> <task-id>                  # new content via stdin
#   bitbucket_pr_tasks.sh resolve <pr-id> <task-id>
#   bitbucket_pr_tasks.sh reopen  <pr-id> <task-id>
#
# Hidden / dangerous operations (use raw `bb` if needed): delete.

if [ -n "${BASH_VERSION:-}" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/bitbucket_pr_tasks.sh) or with: zsh scripts/bitbucket_pr_tasks.sh"
  exit 1
fi
set -eEuo pipefail

. "${0:A:h}/_lib.sh"

BITBUCKET_CLI="${BITBUCKET_CLI:-bb}"
JQ_PATH="${JQ_PATH:-jq}"

cmd_list() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local format="json"
  while (( $# > 0 )); do
    case "$1" in
      --format)
        (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }
        format="$2"; shift 2 ;;
      *) log_error "Unknown list flag: '$1'"; exit 1 ;;
    esac
  done
  case "$format" in json|tsv) ;; *) log_error "Invalid --format '$format' (expected json|tsv)"; exit 1 ;; esac

  log_info "Fetching tasks for PR #$pr_id (format=$format)..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task list --pullrequest "$pr_id" "${BB_TARGET[@]}" --output "$format" 2>&1); then
    log_error "Failed to fetch tasks for PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "tasks-list-${pr_id}" --ext "$format"
}

cmd_get() {
  local pr_id="$1" task_id="$2"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  log_info "Fetching task #$task_id from PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task get "$task_id" --pullrequest "$pr_id" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to fetch task #$task_id from PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi
  printf '%s\n' "$output" | buffer_output --label "tasks-get-${pr_id}-${task_id}" --ext json
}

cmd_create() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local comment_id=""
  while (( $# > 0 )); do
    case "$1" in
      --comment)
        (( $# >= 2 )) || { log_error "--comment requires <comment-id>"; exit 1; }
        comment_id="$2"; shift 2 ;;
      *)
        log_error "Unknown create flag: '$1'"
        exit 1 ;;
    esac
  done
  [[ -z "$comment_id" ]] || validate_numeric "$comment_id" "comment ID"

  local content
  content="$(read_stdin_content)"

  local -a args=(pr task create --pullrequest "$pr_id" --content "$content")
  [[ -n "$comment_id" ]] && args+=(--comment "$comment_id")

  log_info "Creating task on PR #$pr_id${comment_id:+ (attached to comment $comment_id)}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to create task on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "tasks-create-${pr_id}" --ext json
}

cmd_update() {
  local pr_id="$1" task_id="$2"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  local content
  content="$(read_stdin_content)"

  log_info "Updating task #$task_id content on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task update "$task_id" \
                  --pullrequest "$pr_id" --content "$content" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to update task #$task_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "tasks-update-${pr_id}-${task_id}" --ext json
}

cmd_set_state() {
  local pr_id="$1" task_id="$2" state="$3"
  validate_numeric "$pr_id"   "PR ID"
  validate_numeric "$task_id" "Task ID"

  log_info "Setting task #$task_id on PR #$pr_id to $state..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr task update "$task_id" \
                  --pullrequest "$pr_id" --state "$state" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to set task #$task_id state to $state on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  local label_state
  label_state="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$output" | buffer_output --label "tasks-${label_state}-${pr_id}-${task_id}" --ext json
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr_tasks.sh <command> <pr-id> [args...]

Commands:
  list    <pr-id> [--format json|tsv]          JSON (default; formatted) or TSV (compact).
  get     <pr-id> <task-id>                    JSON of one task
  create  <pr-id> [--comment <comment-id>]     Content via stdin; --comment attaches to a comment
  update  <pr-id> <task-id>                    New content via stdin (text only — does not change state)
  resolve <pr-id> <task-id>                    Mark task as RESOLVED (done)
  reopen  <pr-id> <task-id>                    Mark task as UNRESOLVED (reopen)

Hidden (use raw bb if needed): delete.

Repo targeting (any command; default: workspace/repository derived from the current git remote):
  --repo <workspace>/<slug>            Operate on a specific repo (e.g. a slug from \`bitbucket_jira.sh repos\`),
                                       even one not cloned locally. Suppresses the no-remote warning.
  --workspace <W> --repository <R>     Same target, as bb's native flag pair.

Environment:
  BITBUCKET_CLI         Path to bb               (default: bb)
  JQ_PATH               Path to jq               (default: jq)
  BB_OUTPUT_MAX_BYTES   Spill output > N bytes to a tempfile (default: 32768)

Exit codes: 0 success, 1 bad args, 2 missing CLI, 3 API/network failure, 4 not found.
EOF
}

main() {
  (( $# >= 1 )) || { log_error "Missing command"; show_usage; exit 1; }
  case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

  check_prerequisites
  parse_repo_target "$@"; set -- "${BB_REST_ARGS[@]}"
  (( BB_TARGET_EXPLICIT )) || warn_if_no_bitbucket_remote
  (( $# >= 1 )) || { log_error "Missing command"; show_usage; exit 1; }
  local command="$1"; shift
  (( $# >= 1 )) || { log_error "$command requires at least <pr-id>"; show_usage; exit 1; }

  case "$command" in
    list)    cmd_list    "$@" ;;
    get)     (( $# >= 2 )) || { log_error "get requires <pr-id> <task-id>";     exit 1; }
             cmd_get     "$@" ;;
    create)  cmd_create  "$@" ;;
    update)  (( $# >= 2 )) || { log_error "update requires <pr-id> <task-id>";  exit 1; }
             cmd_update  "$@" ;;
    # bb's --state help lies (needs_work/complete/pending); the Cloud API only
    # accepts RESOLVED/UNRESOLVED — do not change these to match the help text.
    resolve) (( $# >= 2 )) || { log_error "resolve requires <pr-id> <task-id>"; exit 1; }
             cmd_set_state "$1" "$2" "RESOLVED" ;;
    reopen)  (( $# >= 2 )) || { log_error "reopen requires <pr-id> <task-id>";  exit 1; }
             cmd_set_state "$1" "$2" "UNRESOLVED" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
