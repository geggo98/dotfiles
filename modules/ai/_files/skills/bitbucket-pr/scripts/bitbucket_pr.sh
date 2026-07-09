#!/bin/zsh
# Bitbucket Pull Request Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.1+) PR operations.
#
# Usage:
#   bitbucket_pr.sh list [--format json|tsv] [state]
#   bitbucket_pr.sh get <pr-id>
#   bitbucket_pr.sh create [--draft] <title> <source-branch> [destination-branch]   # description via stdin (optional)
#   bitbucket_pr.sh update <pr-id> [--title <new-title>] [--description-from-stdin]
#
# Hidden / dangerous operations (use raw `bb` if you really need them):
#   merge, decline, approve/unapprove, request-changes

if [ -n "${BASH_VERSION:-}" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/bitbucket_pr.sh) or with: zsh scripts/bitbucket_pr.sh"
  exit 1
fi
set -eEuo pipefail

. "${0:A:h}/_lib.sh"

BITBUCKET_CLI="${BITBUCKET_CLI:-bb}"
JQ_PATH="${JQ_PATH:-jq}"

cmd_list() {
  local format="json" state="OPEN"
  while (( $# > 0 )); do
    case "$1" in
      --format)
        (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }
        format="$2"; shift 2 ;;
      *)
        state="$1"; shift ;;
    esac
  done
  case "$format" in json|tsv) ;; *) log_error "Invalid --format '$format' (expected json|tsv)"; exit 1 ;; esac
  case "$state"  in OPEN|MERGED|DECLINED|SUPERSEDED) ;; *) log_error "Invalid state '$state' (expected OPEN|MERGED|DECLINED|SUPERSEDED)"; exit 1 ;; esac

  log_info "Listing $state pull requests (format=$format)..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr list --query "state=\"$state\"" "${BB_TARGET[@]}" --output "$format" 2>&1); then
    log_error "Failed to list PRs"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "pr-list-${state}" --ext "$format"
}

cmd_get() {
  local pr_id="$1"
  validate_numeric "$pr_id" "PR ID"

  log_info "Fetching PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" pr get "$pr_id" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to fetch PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi
  printf '%s\n' "$output" | buffer_output --label "pr-get-${pr_id}" --ext json
}

cmd_create() {
  # --draft may appear anywhere among the positional args; everything else is
  # collected positionally as <title> <source-branch> [destination-branch].
  # Use a literal `--` before a title that legitimately starts with a dash.
  local draft=false
  local -a pos=() reviewers=()
  while (( $# > 0 )); do
    case "$1" in
      --draft) draft=true; shift ;;
      --reviewer)
        (( $# >= 2 )) || { log_error "--reviewer requires a value (name, nickname, Account ID, UUID, or 'default')"; exit 1; }
        reviewers+=("$2"); shift 2 ;;
      --)      shift; while (( $# > 0 )); do pos+=("$1"); shift; done ;;
      -*)      log_error "Unknown create flag: '$1' (did you mean --draft or --reviewer?)"; exit 1 ;;
      *)       pos+=("$1"); shift ;;
    esac
  done

  local title="${pos[1]:-}" source_branch="${pos[2]:-}" dest_branch="${pos[3]:-}"
  [[ -n "$title" ]]         || { log_error "Title is required";         exit 1; }
  [[ -n "$source_branch" ]] || { log_error "Source branch is required"; exit 1; }

  local -a args=(pr create --title "$title" --source "$source_branch")
  [[ -n "$dest_branch" ]] && args+=(--destination "$dest_branch")
  [[ "$draft" == true ]]  && args+=(--draft)
  # bb accepts --reviewer multiple times (and comma-separated values, and the
  # sentinel `default` as the first reviewer); pass each collected value verbatim.
  local r
  for r in "${reviewers[@]}"; do args+=(--reviewer "$r"); done

  if [ ! -t 0 ]; then
    local description
    description="$(read_stdin_content)"
    args+=(--description "$description")
  fi

  local draft_note=""; [[ "$draft" == true ]] && draft_note="draft "
  local reviewer_note=""; (( ${#reviewers[@]} > 0 )) && reviewer_note=" (reviewers: ${(j:, :)reviewers})"
  log_info "Creating ${draft_note}PR '$title' from $source_branch${dest_branch:+ to $dest_branch}${reviewer_note}..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to create PR"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "pr-create" --ext json
}

cmd_update() {
  local pr_id="$1"; shift
  validate_numeric "$pr_id" "PR ID"

  local new_title="" want_stdin_desc=false
  local -a add_reviewers=() remove_reviewers=()
  while (( $# > 0 )); do
    case "$1" in
      --title)
        (( $# >= 2 )) || { log_error "--title requires a value"; exit 1; }
        new_title="$2"; shift 2 ;;
      --description-from-stdin)
        want_stdin_desc=true; shift ;;
      --add-reviewer)
        (( $# >= 2 )) || { log_error "--add-reviewer requires a value (name, nickname, Account ID, or UUID)"; exit 1; }
        add_reviewers+=("$2"); shift 2 ;;
      --remove-reviewer)
        (( $# >= 2 )) || { log_error "--remove-reviewer requires a value (name, nickname, Account ID, or UUID)"; exit 1; }
        remove_reviewers+=("$2"); shift 2 ;;
      *)
        log_error "Unknown update flag: '$1'"
        exit 1 ;;
    esac
  done

  if [[ -z "$new_title" ]] && [[ "$want_stdin_desc" == false ]] \
     && (( ${#add_reviewers[@]} == 0 )) && (( ${#remove_reviewers[@]} == 0 )); then
    log_error "update requires at least --title <t>, --description-from-stdin, --add-reviewer, or --remove-reviewer"
    exit 1
  fi

  local -a args=(pr update "$pr_id")
  [[ -n "$new_title" ]] && args+=(--title "$new_title")
  if [[ "$want_stdin_desc" == true ]]; then
    if [ -t 0 ]; then
      log_error "--description-from-stdin expects content on stdin"
      exit 1
    fi
    local description
    description="$(read_stdin_content)"
    args+=(--description "$description")
  fi
  # bb accepts --add-reviewer / --remove-reviewer multiple times (and
  # comma-separated values); pass each collected value verbatim.
  local r
  for r in "${add_reviewers[@]}";    do args+=(--add-reviewer "$r");    done
  for r in "${remove_reviewers[@]}"; do args+=(--remove-reviewer "$r"); done

  log_info "Updating PR #$pr_id..."
  local output
  if ! output=$("$BITBUCKET_CLI" "${args[@]}" "${BB_TARGET[@]}" --output json 2>&1); then
    log_error "Failed to update PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi
  printf '%s\n' "$output" | buffer_output --label "pr-update-${pr_id}" --ext json
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr.sh <command> [args...]

Commands:
  list [--format json|tsv] [state]              List PRs. state: OPEN|MERGED|DECLINED|SUPERSEDED (default OPEN).
                                                --format defaults to json (formatted); tsv is ~10x smaller for browsing.
  get <pr-id>                                   Show one PR as JSON
  create [--draft] [--reviewer R]... <title> <source-branch> [dest]
                                                Create a PR (optionally as a draft); description optional via stdin.
                                                --reviewer is optional and repeatable (also comma-separated). R = name,
                                                nickname, Account ID, or UUID; use 'default' as the first reviewer to pull
                                                the repo/project default reviewers.
                                                Note: bb cannot read back or toggle draft state (get/list/update omit it);
                                                verify via the REST API if needed.
  update <pr-id> [--title T] [--description-from-stdin] [--add-reviewer R]... [--remove-reviewer R]...
                                                Update title and/or description (description via stdin), and/or
                                                add/remove reviewers (repeatable, also comma-separated; R as above).

Hidden (use raw bb if needed): merge, decline, approve, unapprove, request-changes.

Repo targeting (any command; default: workspace/repository derived from the current git remote):
  --repo <workspace>/<slug>            Operate on a specific repo (e.g. a slug from \`bitbucket_jira.sh repos\`),
                                       even one not cloned locally. Suppresses the no-remote warning.
  --workspace <W> --repository <R>     Same target, as bb's native flag pair.

Environment:
  BITBUCKET_CLI         Path to bb               (default: bb)
  JQ_PATH               Path to jq               (default: jq)
  BB_OUTPUT_MAX_BYTES   Spill output > N bytes to a tempfile (default: 32768)

Exit codes: 0 success, 1 bad args, 2 missing CLI, 3 API/network failure, 4 PR not found.
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

  case "$command" in
    list)   cmd_list   "$@" ;;
    get)    (( $# >= 1 )) || { log_error "get requires <pr-id>"; exit 1; }
            cmd_get    "$@" ;;
    create) (( $# >= 2 )) || { log_error "create requires <title> <source-branch>"; exit 1; }
            cmd_create "$@" ;;
    update) (( $# >= 1 )) || { log_error "update requires <pr-id>"; exit 1; }
            cmd_update "$@" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
