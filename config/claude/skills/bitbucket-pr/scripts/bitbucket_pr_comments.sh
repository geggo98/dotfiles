#!/usr/bin/env bash

set -euo pipefail

# Bitbucket PR Comments Script
# Fetches comments from a Bitbucket pull request
#
# Usage:
#   bitbucket_pr_comments.sh list <pr-id>
#   bitbucket_pr_comments.sh get <pr-id> <comment-id>

# Default commands (can be overridden via environment)
BITBUCKET_CLI="${BITBUCKET_CLI:-bb}"
JQ_PATH="${JQ_PATH:-jq}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Logging functions
log_error() {
  echo -e "${RED}Error: $1${NC}" >&2
}

log_success() {
  echo -e "${GREEN}$1${NC}"
}

log_info() {
  echo -e "${YELLOW}Info: $1${NC}" >&2
}

# Check prerequisites
check_prerequisites() {
  local missing=()

  if ! command -v "$BITBUCKET_CLI" &> /dev/null; then
    missing+=("Bitbucket CLI ('$BITBUCKET_CLI')")
  fi

  if ! command -v "$JQ_PATH" &> /dev/null; then
    missing+=("jq ('$JQ_PATH')")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing prerequisites:"
    for tool in "${missing[@]}"; do
      echo "  - $tool" >&2
    done
    exit 2
  fi
}

# Validate numeric input
validate_numeric() {
  local value="$1"
  local name="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_error "Invalid $name: '$value' (must be numeric)"
    exit 1
  fi
}

# List all comments for a PR
list_comments() {
  local pr_id="$1"

  log_info "Fetching comments for PR #$pr_id..."

  local output
  if ! output=$($BITBUCKET_CLI pr comment list --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch comments for PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 3
  fi

  # Parse and format output
  echo "$output" | $JQ_PATH 'map({id, content, inline})'
}

# Get a specific comment by ID
get_comment() {
  local pr_id="$1"
  local comment_id="$2"

  log_info "Fetching comment #$comment_id from PR #$pr_id..."

  local output
  if ! output=$($BITBUCKET_CLI pr comment get "$comment_id" --pullrequest "$pr_id" --output json 2>&1); then
    log_error "Failed to fetch comment #$comment_id from PR #$pr_id"
    log_error "Bitbucket CLI output: $output"
    exit 4
  fi

  # Extract and return content
  echo "$output" | $JQ_PATH -r '.content'
}

# Show usage
show_usage() {
  cat >&2 << EOF
Usage: bitbucket_pr_comments.sh <command> <pr-id> [comment-id]

Commands:
  list <pr-id>              List all comments for a pull request
  get <pr-id> <comment-id>  Get a specific comment by ID

Examples:
  bitbucket_pr_comments.sh list 12345
  bitbucket_pr_comments.sh get 12345 67890

Environment Variables:
  BITBUCKET_CLI    Path to Bitbucket CLI (default: bb)
  JQ_PATH          Path to jq (default: jq)
EOF
}

# Main script logic
main() {
  check_prerequisites

  if [ $# -lt 2 ]; then
    log_error "Insufficient arguments"
    show_usage
    exit 1
  fi

  local command="$1"
  local pr_id="$2"

  validate_numeric "$pr_id" "PR ID"

  case "$command" in
    list)
      list_comments "$pr_id"
      ;;
    get)
      if [ $# -lt 3 ]; then
        log_error "Comment ID required for 'get' command"
        show_usage
        exit 1
      fi

      local comment_id="$3"
      validate_numeric "$comment_id" "Comment ID"
      get_comment "$pr_id" "$comment_id"
      ;;
    *)
      log_error "Unknown command: '$command'"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
