#!/bin/zsh
# Bitbucket ⇄ JIRA bridge.
# Finds the Bitbucket PRs / branches / repositories that JIRA links to an issue,
# via Jira's dev-status REST endpoint — something the repo-local `bb` CLI cannot
# do (it only sees the current directory's git remote). Works from ANY CWD; it
# talks to the Jira REST API directly and does NOT touch git or `bb`.
#
# Usage:
#   bitbucket_jira.sh id       <issue-key|issue-id> [--format json|tsv]
#   bitbucket_jira.sh prs      <issue-key|issue-id> [--state OPEN|MERGED|DECLINED] [--no-resolve-repo] [--application-type T] [--format json|tsv]
#   bitbucket_jira.sh branches <issue-key|issue-id> [--application-type T] [--format json|tsv]
#   bitbucket_jira.sh repos    <issue-key|issue-id> [--application-type T] [--format json|tsv]
#   bitbucket_jira.sh whoami                         [--format json|tsv]
#
# Chain into the bb wrappers (the linked repo is usually NOT cloned locally):
#   slug=$(bitbucket_jira.sh repos VUKFZIF-2978 --format tsv | head -1 | cut -f3)
#   bitbucket_pr_comments.sh list <pr-id> --repo "$slug"
#
# Credentials (env wins; otherwise read from $SOPS_SECRETS_DIR files):
#   JIRA_URL        | jira_url
#   JIRA_USERNAME   | jira_username
#   JIRA_API_TOKEN  → ATLASSIAN_API_TOKEN | jira_api_token → atlassian_c24_bitbucket_api_token
# Auth is HTTP Basic ("$JIRA_USERNAME:$JIRA_API_TOKEN") against the Jira site.

if [ -n "${BASH_VERSION:-}" ]; then
  echo >&2 "ERROR: This script requires zsh but is running under bash."
  echo >&2 "Run it directly (./scripts/bitbucket_jira.sh) or with: zsh scripts/bitbucket_jira.sh"
  exit 1
fi
set -eEuo pipefail

. "${0:A:h}/_lib.sh"

SCRIPT_NAME="${0:t}"
JQ_PATH="${JQ_PATH:-jq}"
CURL_PATH="${CURL_PATH:-curl}"
APPLICATION_TYPE="${JIRA_DEV_APPLICATION_TYPE:-bitbucket}"
SOPS_SECRETS_DIR="${SOPS_SECRETS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/sops-nix/secrets}"

# Globals populated by helpers.
JIRA_BODY=""        # last successful response body
RESOLVED_ID=""      # numeric issue id
RESOLVED_KEY=""     # issue key (empty if input was already numeric)
RESOLVED_SUMMARY="" # issue summary (empty if input was already numeric)

# --- prerequisites & credentials ------------------------------------------

check_prerequisites_jira() {
  local -a missing=()
  command -v "${CURL_PATH}" >/dev/null 2>&1 || missing+=("curl (\$CURL_PATH=${CURL_PATH})")
  command -v "${JQ_PATH}"   >/dev/null 2>&1 || missing+=("jq (\$JQ_PATH=${JQ_PATH})")
  if (( ${#missing[@]} > 0 )); then
    log_error "Missing prerequisites:"
    local m; for m in "${missing[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 2
  fi
}

# resolve_secret VAR file1 [file2 ...] — if $VAR is empty, fill it from the first
# readable, non-empty file under $SOPS_SECRETS_DIR. Mirrors load_from_secret in
# modules/_files/shell/load-secrets.sh.
resolve_secret() {
  local var="$1"; shift
  [[ -n "${(P)var:-}" ]] && return 0
  local f val
  for f in "$@"; do
    if [[ -r "$SOPS_SECRETS_DIR/$f" ]]; then
      val="$(<"$SOPS_SECRETS_DIR/$f")"
      if [[ -n "$val" ]]; then typeset -g "$var=$val"; return 0; fi
    fi
  done
  return 0
}

load_credentials() {
  resolve_secret JIRA_URL      jira_url
  resolve_secret JIRA_USERNAME jira_username
  if [[ -z "${JIRA_API_TOKEN:-}" && -n "${ATLASSIAN_API_TOKEN:-}" ]]; then
    JIRA_API_TOKEN="$ATLASSIAN_API_TOKEN"
  fi
  resolve_secret JIRA_API_TOKEN jira_api_token atlassian_c24_bitbucket_api_token

  local -a missing=()
  [[ -n "${JIRA_URL:-}" ]]       || missing+=("JIRA_URL (or file jira_url)")
  [[ -n "${JIRA_USERNAME:-}" ]]  || missing+=("JIRA_USERNAME (or file jira_username)")
  [[ -n "${JIRA_API_TOKEN:-}" ]] || missing+=("JIRA_API_TOKEN / ATLASSIAN_API_TOKEN (or file jira_api_token / atlassian_c24_bitbucket_api_token)")
  if (( ${#missing[@]} > 0 )); then
    log_error "Missing Jira credentials:"
    local m; for m in "${missing[@]}"; do printf '  - %s\n' "$m" >&2; done
    printf 'Set them in the environment, or place sops-nix files in: %s\n' "$SOPS_SECRETS_DIR" >&2
    exit 2
  fi

  while [[ "$JIRA_URL" == */ ]]; do JIRA_URL="${JIRA_URL%/}"; done
  [[ "$JIRA_URL" == http://* || "$JIRA_URL" == https://* ]] || JIRA_URL="https://$JIRA_URL"
}

# --- HTTP -----------------------------------------------------------------

jira_err_snippet() {
  local f="$1" pretty
  [[ -s "$f" ]] || return 0
  if pretty="$("$JQ_PATH" -C . "$f" 2>/dev/null)"; then
    printf '%s\n' "$pretty" | head -n 20 >&2
  else
    head -n 20 "$f" >&2
  fi
}

# jira_get <url> — prints the response body on 2xx; logs + exits otherwise.
# Exit codes match the skill scheme: 3 = API/auth/network, 4 = not found.
jira_get() {
  local url="$1" body_file err_file http_code curl_rc=0
  body_file="$(mktemp "${TMPDIR:-/tmp}/bb-jira.XXXXXX")" || { log_error "mktemp failed"; exit 3; }
  err_file="${body_file}.err"
  http_code="$("$CURL_PATH" -sS --connect-timeout 10 --max-time 60 --retry 2 \
      -u "${JIRA_USERNAME}:${JIRA_API_TOKEN}" \
      -H "Accept: application/json" \
      -w '%{http_code}' -o "$body_file" \
      "$url" 2>"$err_file")" || curl_rc=$?
  if (( curl_rc != 0 )); then
    log_error "curl failed (exit $curl_rc) requesting $url"
    [[ -s "$err_file" ]] && head -n 5 "$err_file" >&2
    rm -f "$body_file" "$err_file"
    exit 3
  fi
  case "$http_code" in
    2[0-9][0-9])
      cat "$body_file"; rm -f "$body_file" "$err_file"; return 0 ;;
    401|403)
      log_error "Jira authentication failed (HTTP $http_code). Check JIRA_USERNAME + token; run '$SCRIPT_NAME whoami' to verify the account behind the token."
      jira_err_snippet "$body_file"; rm -f "$body_file" "$err_file"; exit 3 ;;
    404)
      log_error "Jira resource not found (HTTP 404): $url"
      rm -f "$body_file" "$err_file"; exit 4 ;;
    *)
      log_error "Jira request failed (HTTP $http_code): $url"
      jira_err_snippet "$body_file"; rm -f "$body_file" "$err_file"; exit 3 ;;
  esac
}

# jira_fetch <url> — like jira_get but stores the body in $JIRA_BODY (so an
# error exit inside the command-substitution subshell still aborts the script).
jira_fetch() {
  local rc=0
  JIRA_BODY="$(jira_get "$1")" || rc=$?
  (( rc == 0 )) || exit "$rc"
}

# devstatus <issue-id> <pullrequest|branch|repository> — fetch dev-status detail.
devstatus() {
  local id="$1" dtype="$2"
  jira_fetch "$JIRA_URL/rest/dev-status/1.0/issue/detail?issueId=$id&applicationType=$APPLICATION_TYPE&dataType=$dtype"
  local errs
  errs="$("$JQ_PATH" -r '(.errors // []) | length' <<< "$JIRA_BODY" 2>/dev/null || echo 0)"
  if [[ -n "$errs" && "$errs" != "0" ]]; then
    log_info "dev-status reported $errs error(s) for issue $id — results may be incomplete. Check --application-type (bitbucket for Cloud, not stash) and that the issue has linked development data."
  fi
}

# resolve_issue_id <key|id> — sets RESOLVED_ID (+ RESOLVED_KEY/SUMMARY for keys).
resolve_issue_id() {
  local ref="$1"
  RESOLVED_KEY=""; RESOLVED_SUMMARY=""
  if [[ "$ref" =~ ^[0-9]+$ ]]; then RESOLVED_ID="$ref"; JIRA_BODY=""; return 0; fi
  jira_fetch "$JIRA_URL/rest/api/3/issue/$ref?fields=summary"
  RESOLVED_ID="$("$JQ_PATH" -r '.id // empty'            <<< "$JIRA_BODY")"
  RESOLVED_KEY="$("$JQ_PATH" -r '.key // empty'          <<< "$JIRA_BODY")"
  RESOLVED_SUMMARY="$("$JQ_PATH" -r '.fields.summary // empty' <<< "$JIRA_BODY")"
  [[ -n "$RESOLVED_ID" ]] || { log_error "Could not resolve a numeric issue id for '$ref'"; exit 4; }
}

validate_format() { case "$1" in json|tsv) ;; *) log_error "Invalid --format '$1' (expected json|tsv)"; exit 1 ;; esac }

# strip scheme+host from a Bitbucket repo URL → "<workspace>/<slug>"
slug_filter='if . == null or . == "" then null else (sub("^https?://[^/]+/"; "") | sub("/$"; "")) end'

# --- commands -------------------------------------------------------------

cmd_id() {
  local format="tsv" ref=""
  while (( $# > 0 )); do
    case "$1" in
      --format) (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }; format="$2"; shift 2 ;;
      --*) log_error "Unknown id flag: '$1'"; exit 1 ;;
      *) ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || { log_error "id requires <issue-key|issue-id>"; exit 1; }
  validate_format "$format"
  resolve_issue_id "$ref"

  if [[ "$format" == json ]]; then
    "$JQ_PATH" -n --arg id "$RESOLVED_ID" --arg key "$RESOLVED_KEY" --arg summary "$RESOLVED_SUMMARY" \
      '{ id: $id,
         key: (if $key == "" then null else $key end),
         summary: (if $summary == "" then null else $summary end) }'
  else
    printf '%s\n' "$RESOLVED_ID"
  fi
}

cmd_prs() {
  local format="json" state="" resolve_repo=1 ref=""
  while (( $# > 0 )); do
    case "$1" in
      --format)            (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }; format="$2"; shift 2 ;;
      --state)             (( $# >= 2 )) || { log_error "--state requires a value";    exit 1; }; state="$2"; shift 2 ;;
      --application-type)  (( $# >= 2 )) || { log_error "--application-type requires a value"; exit 1; }; APPLICATION_TYPE="$2"; shift 2 ;;
      --no-resolve-repo)   resolve_repo=0; shift ;;
      --*) log_error "Unknown prs flag: '$1'"; exit 1 ;;
      *) ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || { log_error "prs requires <issue-key|issue-id>"; exit 1; }
  validate_format "$format"
  resolve_issue_id "$ref"

  devstatus "$RESOLVED_ID" pullrequest
  local prs_json
  prs_json="$("$JQ_PATH" '
    [ .detail[]?.pullRequests[]? | {
        id: (.id | tostring | sub("^#"; "")),
        status: .status,
        title: .name,
        source: .source.branch,
        destination: .destination.branch,
        author: (.author.name // .author.displayName // null),
        lastUpdate: .lastUpdate,
        url: .url,
        repo: (.repositoryName // null)
      } ]' <<< "$JIRA_BODY")"

  if [[ -n "$state" ]]; then
    prs_json="$("$JQ_PATH" --arg st "$state" 'map(select(.status == ($st | ascii_upcase)))' <<< "$prs_json")"
  fi

  local repos_json="[]" single_slug=""
  if (( resolve_repo )); then
    devstatus "$RESOLVED_ID" repository
    repos_json="$("$JQ_PATH" "
      [ .detail[]?.repositories[]? | {
          name: .name,
          url: .url,
          slug: (.url | ${slug_filter})
        } ]" <<< "$JIRA_BODY")"
    if [[ "$("$JQ_PATH" 'length' <<< "$repos_json")" == "1" ]]; then
      single_slug="$("$JQ_PATH" -r '.[0].slug // empty' <<< "$repos_json")"
    fi
    if [[ -n "$single_slug" ]]; then
      prs_json="$("$JQ_PATH" --arg slug "$single_slug" '
        map(.repo = $slug
            | .url = "https://bitbucket.org/" + $slug + "/pull-requests/" + (.id | tostring))' <<< "$prs_json")"
    fi
  fi

  local out
  out="$("$JQ_PATH" -n \
      --argjson prs "$prs_json" --argjson repos "$repos_json" \
      --arg id "$RESOLVED_ID" --arg key "$RESOLVED_KEY" \
      '{ issue: { id: $id, key: (if $key == "" then null else $key end) },
         repositories: $repos,
         pullRequests: $prs }')"

  if [[ "$format" == tsv ]]; then
    "$JQ_PATH" -r '.pullRequests[] | [ .id, .status, .source, .destination, (.repo // "-"), .url, .title ] | @tsv' <<< "$out" \
      | buffer_output --label "jira-prs-${RESOLVED_ID}" --ext tsv
  else
    printf '%s\n' "$out" | buffer_output --label "jira-prs-${RESOLVED_ID}" --ext json
  fi
}

cmd_branches() {
  local format="json" ref=""
  while (( $# > 0 )); do
    case "$1" in
      --format)           (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }; format="$2"; shift 2 ;;
      --application-type) (( $# >= 2 )) || { log_error "--application-type requires a value"; exit 1; }; APPLICATION_TYPE="$2"; shift 2 ;;
      --*) log_error "Unknown branches flag: '$1'"; exit 1 ;;
      *) ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || { log_error "branches requires <issue-key|issue-id>"; exit 1; }
  validate_format "$format"
  resolve_issue_id "$ref"
  devstatus "$RESOLVED_ID" branch

  local out
  out="$("$JQ_PATH" "
    [ .detail[]?.branches[]? | {
        name: .name,
        repository: (.repository.name // null),
        slug: (.repository.url | ${slug_filter}),
        url: .url,
        lastCommit: (.lastCommit.displayId // .lastCommit.id // null),
        lastCommitDate: (.lastCommit.authorTimestamp // null)
      } ]" <<< "$JIRA_BODY")"

  if [[ "$format" == tsv ]]; then
    "$JQ_PATH" -r '.[] | [ .name, (.slug // "-"), (.lastCommit // "-"), .url ] | @tsv' <<< "$out" \
      | buffer_output --label "jira-branches-${RESOLVED_ID}" --ext tsv
  else
    printf '%s\n' "$out" | buffer_output --label "jira-branches-${RESOLVED_ID}" --ext json
  fi
}

cmd_repos() {
  local format="json" ref=""
  while (( $# > 0 )); do
    case "$1" in
      --format)           (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }; format="$2"; shift 2 ;;
      --application-type) (( $# >= 2 )) || { log_error "--application-type requires a value"; exit 1; }; APPLICATION_TYPE="$2"; shift 2 ;;
      --*) log_error "Unknown repos flag: '$1'"; exit 1 ;;
      *) ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || { log_error "repos requires <issue-key|issue-id>"; exit 1; }
  validate_format "$format"
  resolve_issue_id "$ref"
  devstatus "$RESOLVED_ID" repository

  local out
  out="$("$JQ_PATH" "
    [ .detail[]?.repositories[]? | {
        name: .name,
        slug: (.url | ${slug_filter}),
        url: .url,
        commitCount: ((.commits // []) | length),
        lastCommit: (.commits[0].displayId // .commits[0].id // null),
        lastCommitDate: (.commits[0].authorTimestamp // null)
      } ]" <<< "$JIRA_BODY")"

  if [[ "$format" == tsv ]]; then
    "$JQ_PATH" -r '.[] | [ .name, .slug, (.commitCount | tostring), .url ] | @tsv' <<< "$out" \
      | buffer_output --label "jira-repos-${RESOLVED_ID}" --ext tsv
  else
    printf '%s\n' "$out" | buffer_output --label "jira-repos-${RESOLVED_ID}" --ext json
  fi
}

cmd_whoami() {
  local format="json"
  while (( $# > 0 )); do
    case "$1" in
      --format) (( $# >= 2 )) || { log_error "--format requires json|tsv"; exit 1; }; format="$2"; shift 2 ;;
      --*) log_error "Unknown whoami flag: '$1'"; exit 1 ;;
      *) log_error "whoami takes no positional arguments (got '$1')"; exit 1 ;;
    esac
  done
  validate_format "$format"
  jira_fetch "$JIRA_URL/rest/api/3/myself"

  if [[ "$format" == tsv ]]; then
    "$JQ_PATH" -r '[ .accountId, .emailAddress, .displayName ] | @tsv' <<< "$JIRA_BODY" \
      | buffer_output --label "jira-whoami" --ext tsv
  else
    "$JQ_PATH" '{ accountId, emailAddress, displayName, active }' <<< "$JIRA_BODY" \
      | buffer_output --label "jira-whoami" --ext json
  fi
}

show_usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME <command> [args...]

Bridges JIRA issues to their linked Bitbucket PRs/branches/repos via Jira's
dev-status API. Runs from ANY directory (it does not use git or \`bb\`).

Commands:
  id       <key|id> [--format json|tsv]                Resolve a Jira key to its numeric issue id (json adds key+summary).
  prs      <key|id> [--state OPEN|MERGED|DECLINED]      Linked pull requests. By default also resolves the repo slug and
                    [--no-resolve-repo] [--format ...]  rewrites the UUID-based PR URL to a clean one (single-repo case).
  branches <key|id> [--format json|tsv]                Linked branches (name, repo slug, last commit, url).
  repos    <key|id> [--format json|tsv]                Linked repositories — resolves the <workspace>/<slug> for the bb scripts.
  whoami            [--format json|tsv]                Account behind the token (/myself) — verify auth, avoid guessing the login.

  All commands accept --application-type T (default: \${JIRA_DEV_APPLICATION_TYPE:-bitbucket};
  use 'bitbucket' for Bitbucket Cloud — 'stash' returns empty results there).

Chaining into the bb wrappers (linked repos are usually not cloned locally):
  bitbucket_pr_comments.sh list <pr-id> --repo <workspace>/<slug>

Credentials (env wins; else \$SOPS_SECRETS_DIR files; default $SOPS_SECRETS_DIR):
  JIRA_URL | jira_url ;  JIRA_USERNAME | jira_username
  JIRA_API_TOKEN → ATLASSIAN_API_TOKEN | jira_api_token → atlassian_c24_bitbucket_api_token

Environment:
  CURL_PATH             Path to curl             (default: curl)
  JQ_PATH               Path to jq               (default: jq)
  SOPS_SECRETS_DIR      sops-nix secrets dir     (default: \${XDG_CONFIG_HOME:-\$HOME/.config}/sops-nix/secrets)
  JIRA_DEV_APPLICATION_TYPE  dev-status applicationType (default: bitbucket)
  BB_OUTPUT_MAX_BYTES   Spill output > N bytes to a tempfile (default: 32768)

Exit codes: 0 success, 1 bad args, 2 missing prereq/credentials, 3 API/auth/network, 4 issue/resource not found.
EOF
}

main() {
  (( $# >= 1 )) || { log_error "Missing command"; show_usage; exit 1; }
  case "$1" in -h|--help|help) show_usage; exit 0 ;; esac

  check_prerequisites_jira
  load_credentials
  local command="$1"; shift

  case "$command" in
    id)       (( $# >= 1 )) || { log_error "id requires <issue-key|issue-id>";       exit 1; }; cmd_id       "$@" ;;
    prs)      (( $# >= 1 )) || { log_error "prs requires <issue-key|issue-id>";      exit 1; }; cmd_prs      "$@" ;;
    branches) (( $# >= 1 )) || { log_error "branches requires <issue-key|issue-id>"; exit 1; }; cmd_branches "$@" ;;
    repos)    (( $# >= 1 )) || { log_error "repos requires <issue-key|issue-id>";    exit 1; }; cmd_repos    "$@" ;;
    whoami)   cmd_whoami   "$@" ;;
    *) log_error "Unknown command: '$command'"; show_usage; exit 1 ;;
  esac
}

main "$@"
