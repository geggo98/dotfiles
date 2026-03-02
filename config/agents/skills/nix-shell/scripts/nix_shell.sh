#!/usr/bin/env bash
set -euo pipefail

# Nix Shell Skill
# Search Nix packages and run commands with packages from nixpkgs.
#
# Usage:
#   nix_shell.sh search <term> [--json]
#   nix_shell.sh locate <pattern> [-t TYPE] [-n LIMIT] [--timeout SECS] [-w]
#   nix_shell.sh run <packages...> -- <command> [args...]

NIX="${NIX:-nix}"

# --- Logging -----------------------------------------------------------

log_error() {
  echo >&2 "ERROR: $*"
}

log_info() {
  echo >&2 "INFO: $*"
}

# --- Prerequisites ------------------------------------------------------

check_prerequisites() {
  if ! command -v "$NIX" &>/dev/null; then
    log_error "'$NIX' not found. Install Nix or Determinate Nix."
    exit 2
  fi
}

# --- Subcommands --------------------------------------------------------

cmd_search() {
  local json_mode=false
  local term=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      -*)     log_error "Unknown option: $1"; show_usage; exit 1 ;;
      *)
        if [[ -z "$term" ]]; then
          term="$1"
        else
          log_error "Only one search term supported (got extra: '$1')"
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$term" ]]; then
    log_error "Search term required."
    show_usage
    exit 1
  fi

  log_info "Searching nixpkgs for '$term'..."

  local output
  if ! output=$(gtimeout 5m "$NIX" search nixpkgs "$term" --json 2>/dev/null); then
    log_error "nix search failed."
    exit 3
  fi

  # Check for empty results
  if [[ "$output" == "{}" ]] || [[ -z "$output" ]]; then
    echo "No packages found matching '$term'."
    return 0
  fi

  if [[ "$json_mode" == true ]]; then
    echo "$output"
  else
    # Format as a clean table: name  version  description
    echo "$output" | jq -r '
      to_entries[]
      | .value
      | [.pname, .version, .description]
      | @tsv
    ' | sort -u | column -t -s $'\t'
  fi
}

cmd_locate() {
  local pattern=""
  local file_type="x"
  local limit=100
  local timeout_secs=60
  local whole_name=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--type)
        if [[ $# -lt 2 ]]; then log_error "-t requires a type argument (r, x, d, s)"; exit 1; fi
        file_type="$2"; shift 2 ;;
      -n|--limit)
        if [[ $# -lt 2 ]]; then log_error "-n requires a number"; exit 1; fi
        limit="$2"; shift 2 ;;
      --timeout)
        if [[ $# -lt 2 ]]; then log_error "--timeout requires seconds"; exit 1; fi
        timeout_secs="$2"; shift 2 ;;
      -w|--whole-name)
        whole_name=true; shift ;;
      -*)
        log_error "Unknown option: $1"; show_usage; exit 1 ;;
      *)
        if [[ -z "$pattern" ]]; then
          pattern="$1"
        else
          log_error "Only one pattern supported (got extra: '$1')"
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$pattern" ]]; then
    log_error "Locate pattern required."
    show_usage
    exit 1
  fi

  if ! command -v nix-locate &>/dev/null; then
    log_error "'nix-locate' not found. Install nix-index."
    exit 2
  fi

  local locate_args=(--minimal --type "$file_type")
  if [[ "$whole_name" == true ]]; then
    locate_args+=(--whole-name)
  fi
  locate_args+=("$pattern")

  log_info "Locating files matching '$pattern' (type=$file_type, limit=$limit, timeout=${timeout_secs}s)..."

  local output rc=0
  # Run in a subshell with pipefail disabled: head closing the pipe early
  # causes SIGPIPE (exit 141) on nix-locate, which is expected when limiting.
  output=$(set +o pipefail; gtimeout "${timeout_secs}s" nix-locate "${locate_args[@]}" 2>/dev/null | head -n "$limit") || rc=$?

  # gtimeout returns 124 on timeout; head may cause 141 (SIGPIPE) which is fine
  if [[ $rc -eq 124 ]]; then
    log_error "nix-locate timed out after ${timeout_secs}s. Try a more specific pattern."
    exit 3
  fi

  if [[ -z "$output" ]]; then
    echo "No files found matching '$pattern'."
    return 0
  fi

  echo "$output"
}

cmd_run() {
  local packages=()
  local cmd_args=()
  local found_separator=false

  # Parse arguments: packages before --, command after --
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      found_separator=true
      shift
      break
    fi
    packages+=("$1")
    shift
  done

  if [[ "$found_separator" == false ]]; then
    log_error "Missing '--' separator between packages and command."
    log_error "Usage: nix_shell.sh run <packages...> -- <command> [args...]"
    exit 1
  fi

  # Everything after -- is the command
  cmd_args=("$@")

  if [[ ${#packages[@]} -eq 0 ]]; then
    log_error "No packages specified."
    show_usage
    exit 1
  fi

  if [[ ${#cmd_args[@]} -eq 0 ]]; then
    log_error "No command specified after '--'."
    show_usage
    exit 1
  fi

  # Auto-prefix bare package names with nixpkgs#
  local nix_pkgs=()
  for pkg in "${packages[@]}"; do
    if [[ "$pkg" == *"#"* ]] || [[ "$pkg" == *":"* ]]; then
      # Full flake reference, pass through
      nix_pkgs+=("$pkg")
    else
      nix_pkgs+=("nixpkgs#$pkg")
    fi
  done

  log_info "Running in nix shell with: ${nix_pkgs[*]}"

  # exec replaces this process so the exit code passes through
  exec "$NIX" shell "${nix_pkgs[@]}" --command "${cmd_args[@]}"
}

# --- Usage ---------------------------------------------------------------

show_usage() {
  cat >&2 <<'EOF'
Usage: nix_shell.sh <command> [args...]

Commands:
  search <term> [--json]                          Search nixpkgs for packages by name
  locate <pattern> [-t TYPE] [-n N] [--timeout S]  Find which package provides a file/binary
  run <packages...> -- <cmd> [args]                Run a command with nix packages on PATH

Examples:
  nix_shell.sh search envsubst
  nix_shell.sh search envsubst --json
  nix_shell.sh locate gtimeout
  nix_shell.sh locate gtimeout -t x -n 10
  nix_shell.sh run envsubst -- envsubst --help
  nix_shell.sh run envsubst jq -- sh -c 'which envsubst && which jq'

Environment Variables:
  NIX    Path to nix binary (default: nix)
EOF
}

# --- Main ----------------------------------------------------------------

main() {
  check_prerequisites

  if [[ $# -lt 1 ]]; then
    log_error "No command specified."
    show_usage
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
    search) cmd_search "$@" ;;
    locate) cmd_locate "$@" ;;
    run)    cmd_run "$@" ;;
    *)
      log_error "Unknown command: '$command'"
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
