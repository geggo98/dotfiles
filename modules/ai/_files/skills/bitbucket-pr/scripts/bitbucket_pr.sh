#!/bin/zsh
# Bitbucket Pull Request Script
# Wraps stable bb (gildas/bitbucket-cli v0.18.1+) PR operations.
#
# Usage:
#   bitbucket_pr.sh list [--format json|tsv] [state]
#   bitbucket_pr.sh get <pr-id>
#   bitbucket_pr.sh create [--draft] [--reviewer ID]... <title> <source-branch> [destination-branch]   # description via stdin (optional)
#   bitbucket_pr.sh update <pr-id> [--title <new-title>] [--description-from-stdin] [--add-reviewer ID]... [--remove-reviewer ID]...
#   bitbucket_pr.sh status (--pr ID|--commit SHA|--branch NAME) [--all-commits] [--history]
#                          [--format table|json|tsv] [--watch [--interval DUR] [--deadline DUR]] [--exit-code]
#
# Reviewers do NOT go through bb: bb's --reviewer/--add-reviewer flags resolve
# values by enumerating the ENTIRE workspace member list client-side, which
# hangs (and hits HTTP 429) on very large workspaces like `check24` — for names
# AND uuids alike. Instead this wrapper creates/updates the PR with bb (no
# reviewer flags) and sets reviewers via the REST API through the companion
# `bitbucket_pr_reviewers.py` helper (account_id/uuid only). Every bb and helper
# invocation runs under a timeout guard (see $BB_TIMEOUT) so nothing can hang.
#
# Build/pipeline status also bypasses bb entirely — bb has no command for it
# (checked v0.18.2/v0.18.6) and `bb pipeline` queries the wrong API (Bitbucket
# Pipelines, not a Jenkins-via-webhook CI — see SKILL.md §13). `status` talks
# to the commit-statuses REST API through the companion
# `bitbucket_pr_status.py` helper.
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
REVIEWERS_PY="${REVIEWERS_PY:-${0:A:h}/bitbucket_pr_reviewers.py}"
STATUS_PY="${STATUS_PY:-${0:A:h}/bitbucket_pr_status.py}"

# Timeout guard: wrap every bb / helper call so a hang (e.g. bb enumerating a
# huge workspace) fails fast instead of blocking forever. Prefer gtimeout (the
# GNU coreutils name on macOS), fall back to timeout; if neither exists, run
# unguarded. Override the budget with $BB_TIMEOUT (a `timeout` DURATION).
# BB_TIMEOUT_EXPLICIT records whether the caller set it (vs. the default
# below) — cmd_status needs that distinction to decide whether it may widen
# the guard on its own for --watch.
BB_TIMEOUT_EXPLICIT="${BB_TIMEOUT:+1}"
BB_TIMEOUT="${BB_TIMEOUT:-120s}"
BB_TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then
  BB_TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  BB_TIMEOUT_CMD="timeout"
fi
BB_PREFIX=()
[[ -n "$BB_TIMEOUT_CMD" ]] && BB_PREFIX=("$BB_TIMEOUT_CMD" "$BB_TIMEOUT")

# Reviewer buffers, filled by the create/update parsers, consumed by route_reviewers.
REV_ADD=()
REV_REMOVE=()

# report_bb_failure <rc> <exit-code> <action> <output> — print a diagnostic and
# exit. Call from the PARENT shell (never inside $(...)), so exit propagates.
report_bb_failure() {
  local rc="$1" code="$2" action="$3" out="$4"
  if (( rc == 124 )); then
    log_error "bb timed out after ${BB_TIMEOUT} while trying to ${action} (guard \$BB_TIMEOUT). A hang here usually means bb is enumerating a very large workspace."
  else
    log_error "Failed to ${action}"
    [[ -n "$out" ]] && log_error "Bitbucket CLI output: $out"
  fi
  exit "$code"
}

# resolve_ws_repo is defined in _lib.sh (shared with cmd_status below).

# route_reviewers <pr-id> <workspace/slug> — apply REV_ADD/REV_REMOVE to a PR via
# the REST helper (account_id/uuid only). Runs directly (not in $(...)), so it
# may exit; propagates the helper's skill exit code on failure.
route_reviewers() {
  local pr_id="$1" ws_repo="$2"
  command -v uv >/dev/null 2>&1 || { log_error "uv not found — required to set reviewers via REST (${REVIEWERS_PY##*/} runs under 'uv run')."; exit 2; }
  [[ -x "$REVIEWERS_PY" ]] || { log_error "Reviewer helper not found or not executable: $REVIEWERS_PY"; exit 2; }
  local -a pyargs=(set --pr "$pr_id" --repo "$ws_repo")
  local r
  for r in "${REV_ADD[@]}";    do pyargs+=(--add "$r");    done
  for r in "${REV_REMOVE[@]}"; do pyargs+=(--remove "$r"); done
  local rc=0
  "${BB_PREFIX[@]}" "$REVIEWERS_PY" "${pyargs[@]}" || rc=$?
  if (( rc != 0 )); then
    (( rc == 124 )) && log_error "Reviewer REST call timed out after ${BB_TIMEOUT} (guard \$BB_TIMEOUT)."
    exit "$rc"
  fi
}

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
  local output rc=0
  output=$("${BB_PREFIX[@]}" "$BITBUCKET_CLI" pr list --query "state=\"$state\"" "${BB_TARGET[@]}" --output "$format" 2>&1) || rc=$?
  (( rc == 0 )) || report_bb_failure "$rc" 3 "list PRs" "$output"
  printf '%s\n' "$output" | buffer_output --label "pr-list-${state}" --ext "$format"
}

cmd_get() {
  local pr_id="$1"
  validate_numeric "$pr_id" "PR ID"

  log_info "Fetching PR #$pr_id..."
  local output rc=0
  output=$("${BB_PREFIX[@]}" "$BITBUCKET_CLI" pr get "$pr_id" "${BB_TARGET[@]}" --output json 2>&1) || rc=$?
  (( rc == 0 )) || report_bb_failure "$rc" 4 "fetch PR #$pr_id" "$output"
  printf '%s\n' "$output" | buffer_output --label "pr-get-${pr_id}" --ext json
}

cmd_create() {
  # --draft / --reviewer may appear anywhere among the positional args; everything
  # else is collected positionally as <title> <source-branch> [destination-branch].
  # Use a literal `--` before a title that legitimately starts with a dash.
  local draft=false
  local -a pos=() reviewers=()
  while (( $# > 0 )); do
    case "$1" in
      --draft) draft=true; shift ;;
      --reviewer)
        (( $# >= 2 )) || { log_error "--reviewer requires an account_id, uuid, or 'default'"; exit 1; }
        local __v="$2" __p
        for __p in "${(@s:,:)__v}"; do [[ -n "$__p" ]] && reviewers+=("$__p"); done
        shift 2 ;;
      --)      shift; while (( $# > 0 )); do pos+=("$1"); shift; done ;;
      -*)      log_error "Unknown create flag: '$1' (did you mean --draft or --reviewer?)"; exit 1 ;;
      *)       pos+=("$1"); shift ;;
    esac
  done

  local title="${pos[1]:-}" source_branch="${pos[2]:-}" dest_branch="${pos[3]:-}"
  [[ -n "$title" ]]         || { log_error "Title is required";         exit 1; }
  [[ -n "$source_branch" ]] || { log_error "Source branch is required"; exit 1; }

  # Drop the 'default' sentinel — Bitbucket auto-applies the repo's default
  # reviewers on every PR, so creating without reviewers already covers it.
  local -a rev_clean=()
  local saw_default=false r
  for r in "${reviewers[@]}"; do
    if [[ "$r" == default ]]; then saw_default=true; else rev_clean+=("$r"); fi
  done
  [[ "$saw_default" == true ]] && log_info "Ignoring reviewer 'default': Bitbucket applies the repo's default reviewers automatically."
  reviewers=("${rev_clean[@]}")

  local -a args=(pr create --title "$title" --source "$source_branch")
  [[ -n "$dest_branch" ]] && args+=(--destination "$dest_branch")
  [[ "$draft" == true ]]  && args+=(--draft)

  # Description is optional. When stdin is piped, use it; empty stdin (e.g.
  # </dev/null in a non-interactive run) means "no description", not an error.
  if [ ! -t 0 ]; then
    local description
    description="$(cat)"
    [[ -n "$description" ]] && args+=(--description "$description")
  fi

  local draft_note=""; [[ "$draft" == true ]] && draft_note="draft "
  log_info "Creating ${draft_note}PR '$title' from $source_branch${dest_branch:+ to $dest_branch}..."
  # Capture stdout (the PR JSON we parse for .id) and stderr separately, so a
  # stray bb log line on stderr cannot corrupt the JSON we read the id from.
  local output rc=0 errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/bb-create-err.XXXXXX")"
  output=$("${BB_PREFIX[@]}" "$BITBUCKET_CLI" "${args[@]}" "${BB_TARGET[@]}" --output json 2>"$errfile") || rc=$?
  if (( rc != 0 )); then
    local errout; errout="$(cat "$errfile")"; rm -f "$errfile"
    report_bb_failure "$rc" 3 "create PR" "$errout"
  fi
  rm -f "$errfile"
  printf '%s\n' "$output" | buffer_output --label "pr-create" --ext json

  # Reviewers via REST (bb's own --reviewer would hang on large workspaces).
  if (( ${#reviewers[@]} > 0 )); then
    local pr_id ws_repo wr_rc=0
    pr_id="$("$JQ_PATH" -r '.id // empty' <<< "$output" 2>/dev/null || true)"
    [[ -n "$pr_id" ]] || { log_error "Created the PR but could not read its id from bb output; reviewers not set. Add them with: bitbucket_pr.sh update <id> --add-reviewer <account_id>"; exit 3; }
    ws_repo="$(resolve_ws_repo)" || wr_rc=$?
    (( wr_rc == 0 )) || exit 1
    log_info "Setting ${#reviewers[@]} reviewer(s) on PR #$pr_id via REST..."
    REV_ADD=("${reviewers[@]}"); REV_REMOVE=()
    route_reviewers "$pr_id" "$ws_repo"
  fi
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
        (( $# >= 2 )) || { log_error "--add-reviewer requires an account_id or uuid"; exit 1; }
        local __va="$2" __pa
        for __pa in "${(@s:,:)__va}"; do [[ -n "$__pa" ]] && add_reviewers+=("$__pa"); done
        shift 2 ;;
      --remove-reviewer)
        (( $# >= 2 )) || { log_error "--remove-reviewer requires an account_id or uuid"; exit 1; }
        local __vr="$2" __pr
        for __pr in "${(@s:,:)__vr}"; do [[ -n "$__pr" ]] && remove_reviewers+=("$__pr"); done
        shift 2 ;;
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

  # Title / description via bb (no reviewer flags — those hang on big workspaces).
  if [[ -n "$new_title" ]] || [[ "$want_stdin_desc" == true ]]; then
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
    log_info "Updating PR #$pr_id..."
    local output rc=0
    output=$("${BB_PREFIX[@]}" "$BITBUCKET_CLI" "${args[@]}" "${BB_TARGET[@]}" --output json 2>&1) || rc=$?
    (( rc == 0 )) || report_bb_failure "$rc" 3 "update PR #$pr_id" "$output"
    printf '%s\n' "$output" | buffer_output --label "pr-update-${pr_id}" --ext json
  fi

  # Reviewers via REST.
  if (( ${#add_reviewers[@]} > 0 )) || (( ${#remove_reviewers[@]} > 0 )); then
    local ws_repo wr_rc=0
    ws_repo="$(resolve_ws_repo)" || wr_rc=$?
    (( wr_rc == 0 )) || exit 1
    log_info "Updating reviewers on PR #$pr_id via REST (+${#add_reviewers[@]}/-${#remove_reviewers[@]})..."
    REV_ADD=("${add_reviewers[@]}"); REV_REMOVE=("${remove_reviewers[@]}")
    route_reviewers "$pr_id" "$ws_repo"
  fi
}

# cmd_status <args...> — forward to bitbucket_pr_status.py's `get` subcommand,
# resolving --repo from an explicit --repo/--workspace target (already parsed
# by parse_repo_target into BB_WS/BB_REPO) or the current git remote, via the
# shared resolve_ws_repo(). Needs neither bb nor jq — it is a pure REST client.
#
# Sizing the timeout guard: an ordinary query is bounded like every other call
# in this script ($BB_TIMEOUT, default 120s). --watch can run up to its own
# --deadline (default 15m) polling; the flat 120s guard would kill it mid-poll
# and read as an unrelated failure. So under --watch, and only when the caller
# did NOT set $BB_TIMEOUT explicitly, the guard is widened to deadline + 60s —
# the Python side's own --deadline always fires first, gtimeout is only the
# backstop against a genuine hang (e.g. a dead network connection). An
# explicit $BB_TIMEOUT is trusted and never overridden here.
cmd_status() {
  command -v uv >/dev/null 2>&1 || { log_error "uv not found — required to run bitbucket_pr_status.py (runs under 'uv run')."; exit 2; }
  [[ -x "$STATUS_PY" ]] || { log_error "Status helper not found or not executable: $STATUS_PY"; exit 2; }

  local ws_repo wr_rc=0
  ws_repo="$(resolve_ws_repo)" || wr_rc=$?
  (( wr_rc == 0 )) || exit 1

  local -a prefix=("${BB_PREFIX[@]}")
  if [[ -z "$BB_TIMEOUT_EXPLICIT" && -n "$BB_TIMEOUT_CMD" ]]; then
    local watching=false deadline="900" i
    for (( i = 1; i <= $#; i++ )); do
      case "${@[i]}" in
        --watch)    watching=true ;;
        --deadline) (( i < $# )) && deadline="${@[i+1]}" ;;
      esac
    done
    if [[ "$watching" == true ]]; then
      local guard_secs
      guard_secs="$(_bb_duration_seconds "$deadline")" || { log_error "Invalid --deadline '$deadline'"; exit 1; }
      prefix=("$BB_TIMEOUT_CMD" "$(( guard_secs + 60 ))")
    fi
  fi

  local rc=0
  "${prefix[@]}" "$STATUS_PY" get "$@" --repo "$ws_repo" || rc=$?
  if (( rc == 124 )); then
    log_error "Status query timed out under the guard (\$BB_TIMEOUT, or --deadline+60s under --watch). Raise \$BB_TIMEOUT if you need a wider margin."
  fi
  exit "$rc"
}

show_usage() {
  cat >&2 <<EOF
Usage: bitbucket_pr.sh <command> [args...]

Commands:
  list [--format json|tsv] [state]              List PRs. state: OPEN|MERGED|DECLINED|SUPERSEDED (default OPEN).
                                                --format defaults to json (formatted); tsv is ~10x smaller for browsing.
  get <pr-id>                                   Show one PR as JSON
  create [--draft] [--reviewer ID]... <title> <source-branch> [dest]
                                                Create a PR (optionally as a draft); description optional via stdin.
                                                --reviewer is optional and repeatable (also comma-separated). ID must be an
                                                Atlassian account_id (e.g. 557058:... or a 24-hex legacy id) or a uuid ({...}).
                                                Plain names are NOT accepted (bb resolves them by enumerating the whole
                                                workspace, which hangs on large ones). 'default' is ignored — Bitbucket adds
                                                the repo's default reviewers automatically. Reviewers are set via the REST
                                                helper, not bb. Note: bb cannot read back or toggle draft state.
  update <pr-id> [--title T] [--description-from-stdin] [--add-reviewer ID]... [--remove-reviewer ID]...
                                                Update title and/or description (description via stdin), and/or
                                                add/remove reviewers (repeatable, also comma-separated; ID as for create,
                                                applied via the REST helper).
  status (--pr ID|--commit SHA|--branch NAME) [--all-commits] [--history] [--format table|json|tsv]
         [--watch [--interval DUR] [--deadline DUR] [--no-require-overall]] [--exit-code|--no-exit-code]
                                                Build/pipeline status (Jenkins commit statuses) — bb has no command for
                                                this and \`bb pipeline\` queries the wrong API (see SKILL.md §13). Default
                                                target for --pr is the PR's head commit only; --all-commits shows every
                                                commit ever pushed to the PR. --watch polls until every stage is terminal
                                                or --deadline (default 15m) is hit. Full flag reference:
                                                \`${0:t} status --help\` is NOT available — see bitbucket_pr_status.py --help.

Hidden (use raw bb if needed): merge, decline, approve, unapprove, request-changes.

Repo targeting (any command; default: workspace/repository derived from the current git remote):
  --repo <workspace>/<slug>            Operate on a specific repo (e.g. a slug from \`bitbucket_jira.sh repos\`),
                                       even one not cloned locally. Suppresses the no-remote warning.
  --workspace <W> --repository <R>     Same target, as bb's native flag pair.

Finding an account_id/uuid for --reviewer: \`bitbucket_pr.sh get <id>\` or raw \`bb pr get <id>\`
list them under reviewers/participants; \`bb user me\` shows your own.

Environment:
  BITBUCKET_CLI         Path to bb               (default: bb)
  JQ_PATH               Path to jq               (default: jq)
  BB_TIMEOUT            Timeout guard per bb/helper call (default: 120s; a \`timeout\` DURATION).
                        Under \`status --watch\`, auto-widened to --deadline+60s unless set explicitly.
  BB_OUTPUT_MAX_BYTES   Spill output > N bytes to a tempfile (default: 32768)
  BITBUCKET_USER / BITBUCKET_APP_PASSWORD   Override the REST credentials (else bb's config-cli.yml profile)

Exit codes: 0 success, 1 bad args, 2 missing prereq (bb/uv/helper), 3 API/network failure, 4 PR not found.
status additionally supports --exit-code (10 red, 11 in-progress/deadline, 12 no statuses) — see SKILL.md §6/§13.
EOF
}

main() {
  (( $# >= 1 )) || { log_error "Missing command"; show_usage; exit 1; }
  case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

  parse_repo_target "$@"; set -- "${BB_REST_ARGS[@]}"
  (( BB_TARGET_EXPLICIT )) || warn_if_no_bitbucket_remote
  (( $# >= 1 )) || { log_error "Missing command"; show_usage; exit 1; }
  local command="$1"; shift

  case "$command" in
    list)   check_prerequisites; cmd_list   "$@" ;;
    get)    check_prerequisites
            (( $# >= 1 )) || { log_error "get requires <pr-id>"; exit 1; }
            cmd_get    "$@" ;;
    create) check_prerequisites
            (( $# >= 2 )) || { log_error "create requires <title> <source-branch>"; exit 1; }
            cmd_create "$@" ;;
    update) check_prerequisites
            (( $# >= 1 )) || { log_error "update requires <pr-id>"; exit 1; }
            cmd_update "$@" ;;
    status) cmd_status "$@" ;;   # needs neither bb nor jq — pure REST
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
