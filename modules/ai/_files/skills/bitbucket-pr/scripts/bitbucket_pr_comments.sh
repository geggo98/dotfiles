#!/bin/zsh
# Bitbucket PR Comments Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.1+) PR comment operations.
#
# Usage:
#   bitbucket_pr_comments.sh list    <pr-id> [--format json|tsv]
#   bitbucket_pr_comments.sh get     <pr-id> <comment-id>
#   bitbucket_pr_comments.sh create  <pr-id> [--file PATH --line N] [--parent CID]   # body via stdin
#   bitbucket_pr_comments.sh update  <pr-id> <comment-id>                            # new body via stdin
#   bitbucket_pr_comments.sh resolve <pr-id> <comment-id>
#   bitbucket_pr_comments.sh reopen  <pr-id> <comment-id>
#
# Hidden / dangerous operations (use raw `bb` if needed): delete.

if [ -n "${BASH_VERSION:-}" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/bitbucket_pr_comments.sh) or with: zsh scripts/bitbucket_pr_comments.sh"
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

  log_info "Fetching comments for PR #$pr_id (format=$format)..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment list --pullrequest "$pr_id" --output "$format" 2>&1); then
    log_error "Failed to fetch comments for PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi

  if [[ "$format" == "json" ]]; then
    # Keep the projection to {id, content, inline} for compactness on JSON.
    printf '%s\n' "$output" | "$JQ_PATH" 'map({id, content, inline})' \
      | buffer_output --label "comments-list-${pr_id}" --ext json
  else
    printf '%s\n' "$output" | buffer_output --label "comments-list-${pr_id}" --ext tsv
  fi
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
  printf '%s\n' "$output" | "$JQ_PATH" -r '.content' \
    | buffer_output --label "comments-get-${pr_id}-${comment_id}" --ext md
}

cmd_create() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local file="" line="" parent=""
  while (( $# > 0 )); do
    case "$1" in
      --file)   (( $# >= 2 )) || { log_error "--file requires PATH";   exit 1; }; file="$2";   shift 2 ;;
      --line)   (( $# >= 2 )) || { log_error "--line requires N";      exit 1; }; line="$2";   shift 2 ;;
      --parent) (( $# >= 2 )) || { log_error "--parent requires CID";  exit 1; }; parent="$2"; shift 2 ;;
      *) log_error "Unknown create flag: '$1'"; exit 1 ;;
    esac
  done
  [[ -z "$line"   ]] || validate_numeric "$line"   "line number"
  [[ -z "$parent" ]] || validate_numeric "$parent" "parent comment ID"
  if [[ -n "$line" ]] && [[ -z "$file" ]]; then
    log_error "--line requires --file (inline comments need a file path)"
    exit 1
  fi

  local body
  body="$(read_stdin_content)"

  local -a args=(pr comment create --pullrequest "$pr_id" --comment "$body")
  [[ -n "$file"   ]] && args+=(--file   "$file")
  [[ -n "$line"   ]] && args+=(--line   "$line")
  [[ -n "$parent" ]] && args+=(--parent "$parent")

  log_info "Creating comment on PR #$pr_id${file:+ on $file${line:+:$line}}${parent:+ (reply to $parent)}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" --output json 2>&1); then
    log_error "Failed to create comment on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "comments-create-${pr_id}" --ext json
}

cmd_update() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  local body
  body="$(read_stdin_content)"

  log_info "Updating comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment update "$comment_id" \
                  --pullrequest "$pr_id" --comment "$body" --output json 2>&1); then
    log_error "Failed to update comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "comments-update-${pr_id}-${comment_id}" --ext json
}

cmd_resolve() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  log_info "Resolving comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment resolve "$comment_id" --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to resolve comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "comments-resolve-${pr_id}-${comment_id}" --ext json
}

cmd_reopen() {
  local pr_id="$1" comment_id="$2"
  validate_numeric "$pr_id"      "PR ID"
  validate_numeric "$comment_id" "Comment ID"

  log_info "Reopening comment #$comment_id on PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr comment reopen "$comment_id" --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to reopen comment #$comment_id on PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "comments-reopen-${pr_id}-${comment_id}" --ext json
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr_comments.sh <command> <pr-id> [args...]

Commands:
  list    <pr-id> [--format json|tsv]                   JSON (default; filtered to {id,content,inline}) or TSV.
  get     <pr-id> <comment-id>                          Raw markdown of one comment
  create  <pr-id> [--file PATH --line N] [--parent CID] Body via stdin; --file/--line for inline; --parent for replies
  update  <pr-id> <comment-id>                          New body via stdin
  resolve <pr-id> <comment-id>                          Mark comment as resolved
  reopen  <pr-id> <comment-id>                          Reopen a resolved comment

Hidden (use raw bb if needed): delete.

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
  warn_if_no_bitbucket_remote
  local command="$1"; shift
  (( $# >= 1 )) || { log_error "$command requires at least <pr-id>"; show_usage; exit 1; }

  case "$command" in
    list)    cmd_list    "$@" ;;
    get)     (( $# >= 2 )) || { log_error "get requires <pr-id> <comment-id>";     exit 1; }
             cmd_get     "$@" ;;
    create)  cmd_create  "$@" ;;
    update)  (( $# >= 2 )) || { log_error "update requires <pr-id> <comment-id>";  exit 1; }
             cmd_update  "$@" ;;
    resolve) (( $# >= 2 )) || { log_error "resolve requires <pr-id> <comment-id>"; exit 1; }
             cmd_resolve "$@" ;;
    reopen)  (( $# >= 2 )) || { log_error "reopen requires <pr-id> <comment-id>";  exit 1; }
             cmd_reopen  "$@" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
