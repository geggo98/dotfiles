#!/bin/zsh
set -euo pipefail

# zsh on purpose (AGENTS.md, "Script style"): SKILL.md has always invoked this file
# as `zsh nix_shell.sh`, so the former bash shebang was never honoured. Two zsh
# rules apply throughout: word lists are arrays, never unquoted scalars (zsh does
# not word-split), and variable content is printed with printf, never echo (zsh's
# echo interprets backslash escapes, which would corrupt the JSON from nix search).

# Nix Shell Skill
# Search Nix packages and run commands with packages from nixpkgs.
#
# Usage:
#   nix_shell.sh search <term> [--json]
#   nix_shell.sh locate <pattern> [-t TYPE] [-n LIMIT] [--timeout SECS] [-w]
#   nix_shell.sh run <packages...> -- <command> [args...]
#   nix_shell.sh versions <pkg> [<version>] [--system SYS] [--limit N] [--json]
#
# `run` also accepts devbox-style `name@version` (e.g. duckdb@1.5.3), resolved
# through the same API as `versions` to github:NixOS/nixpkgs/<rev>#<attr>.

NIX="${NIX:-nix}"

# nixhub.io itself serves HTML only; the JSON behind it is search.devbox.sh, the
# API the devbox CLI uses (documented by Jetify as free for personal use: a pool
# of 1000 requests per IP, refilled at 5/min, then HTTP 429). An unknown version
# answers 404 with a plain-text body, not JSON. Measured 2026-09-10.
SEARCH_API="https://search.devbox.sh/v2"
BINARY_CACHE="https://cache.nixos.org"
USER_AGENT="nix-shell-skill/1"
SCRATCH=""   # per-run temp dir, created in main, removed by the EXIT trap

# --- Logging -----------------------------------------------------------

log_error() {
  printf '%s\n' "ERROR: $*" >&2
}

log_info() {
  printf '%s\n' "INFO: $*" >&2
}

# --- Prerequisites ------------------------------------------------------

check_prerequisites() {
  if ! command -v "$NIX" &>/dev/null; then
    log_error "'$NIX' not found. Install Nix or Determinate Nix."
    exit 2
  fi
}

# --- Version lookup helpers (shared by `versions` and `run name@version`) ---

# api_get <endpoint> <outfile> [curl args...]  — GET $SEARCH_API/<endpoint>.
# Query parameters go in as `--data-urlencode k=v` (curl -G turns them into the
# query string). Every non-200 answer is fatal here, and each one says why.
api_get() {
  local endpoint="$1" out="$2" code
  shift 2
  if ! code=$(curl -sS -G --max-time 30 -A "$USER_AGENT" -o "$out" -w '%{http_code}' \
               "$@" "$SEARCH_API/$endpoint"); then
    log_error "Cannot reach $SEARCH_API (network error)."
    exit 3
  fi
  case "$code" in
    200) ;;
    404) log_error "$SEARCH_API/$endpoint: HTTP 404 (no such package or version): $(cat "$out")"; exit 3 ;;
    429) log_error "Rate limited by $SEARCH_API (1000 requests per IP, refilled at 5/min). Retry later."; exit 3 ;;
    *)   log_error "$SEARCH_API answered HTTP $code for $endpoint."; exit 3 ;;
  esac
}

# current_system — the Nix system double of this machine, e.g. aarch64-darwin
current_system() {
  "$NIX" eval --impure --raw --expr builtins.currentSystem
}

# cache_status <store-path> — "yes" | "no" | "http NNN" | "unreachable".
# One HEAD on the narinfo, no nixpkgs evaluation. The narinfo name is the
# first 32 characters of the store path's basename.
cache_status() {
  local base="${1##*/}" code
  if ! code=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -I \
               "$BINARY_CACHE/${base:0:32}.narinfo"); then
    printf '%s\n' "unreachable"
    return 0
  fi
  case "$code" in
    200) printf '%s\n' "yes" ;;
    404) printf '%s\n' "no" ;;
    *)   printf '%s\n' "http $code" ;;
  esac
}

# resolve_version <name> <version> <system> — sets R_VERSION, R_REV, R_ATTR and
# R_PATH (the default output's store path), or exits 3 naming the systems the
# version was built for.
# Results go into variables, not to stdout, on purpose: a caller's `$(…)` would
# run this in a subshell, and an `exit` in there neither stops the caller nor
# runs the EXIT trap — measured, the scratch directory survived every 404.
# And never a variable named `path`: in zsh that is the array tied to PATH, and
# assigning a string to it clobbers PATH for the rest of the function.
R_VERSION=""; R_REV=""; R_ATTR=""; R_PATH=""
resolve_version() {
  local name="$1" version="$2" system="$3"
  local out="$SCRATCH/resolve.json" line have
  api_get resolve "$out" --data-urlencode "name=$name" --data-urlencode "version=$version"
  R_VERSION=$(jq -r '.version' "$out")
  line=$(jq -r --arg s "$system" '
    .systems[$s] // empty
    | [ .flake_installable.ref.rev,
        .flake_installable.attr_path,
        (.outputs[] | select(.default == true) | .path) ]
    | @tsv' "$out")
  if [[ -z "$line" ]]; then
    have=$(jq -r '.systems | keys | join(", ")' "$out")
    log_error "$name $R_VERSION exists but was never built for $system (built for: $have)."
    exit 3
  fi
  IFS=$'\t' read -r R_REV R_ATTR R_PATH <<< "$line"
}

# --- Subcommands --------------------------------------------------------

cmd_search() {
  local json_mode=false
  local term=""
  local timeout="5m"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      --timeout)
        if [[ $# -lt 2 ]]; then log_error "--timeout requires a duration (e.g. 5m)"; exit 1; fi
        timeout="$2"; shift 2 ;;
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
  if ! output=$(gtimeout "$timeout" "$NIX" search nixpkgs "$term" --json 2>/dev/null); then
    log_error "nix search failed."
    exit 3
  fi

  # Check for empty results
  if [[ "$output" == "{}" ]] || [[ -z "$output" ]]; then
    echo "No packages found matching '$term'."
    return 0
  fi

  if [[ "$json_mode" == true ]]; then
    printf '%s\n' "$output"
  else
    # Format as a clean table: name  version  description
    printf '%s\n' "$output" | jq -r '
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

  printf '%s\n' "$output"
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

  # Auto-prefix bare package names with nixpkgs#; resolve name@version through
  # the version API to the nixpkgs commit that ships that version.
  local nix_pkgs=() system="" pkg name version
  for pkg in "${packages[@]}"; do
    if [[ "$pkg" == *"#"* ]] || [[ "$pkg" == *":"* ]]; then
      # Full flake reference, pass through
      nix_pkgs+=("$pkg")
    elif [[ "$pkg" == *"@"* ]]; then
      name="${pkg%%@*}"; version="${pkg#*@}"
      [[ -n "$system" ]] || system=$(current_system)
      resolve_version "$name" "$version" "$system"
      log_info "$pkg -> github:NixOS/nixpkgs/${R_REV:0:10}#$R_ATTR (cached in $BINARY_CACHE: $(cache_status "$R_PATH"))"
      nix_pkgs+=("github:NixOS/nixpkgs/$R_REV#$R_ATTR")
    else
      nix_pkgs+=("nixpkgs#$pkg")
    fi
  done

  log_info "Running in nix shell with: ${nix_pkgs[*]}"

  # exec replaces this process, so the EXIT trap never runs: clean up by hand.
  rm -rf "$SCRATCH"
  exec "$NIX" shell --no-write-lock-file "${nix_pkgs[@]}" --command "${cmd_args[@]}"
}

cmd_versions() {
  local name="" version="" system="" limit=10 json_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      --system)
        if [[ $# -lt 2 ]]; then log_error "--system requires a value (e.g. x86_64-linux)"; exit 1; fi
        system="$2"; shift 2 ;;
      --limit)
        if [[ $# -lt 2 || "$2" != <-> ]]; then log_error "--limit requires a number"; exit 1; fi
        limit="$2"; shift 2 ;;
      -*)     log_error "Unknown option: $1"; show_usage; exit 1 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        elif [[ -z "$version" ]]; then
          version="$1"
        else
          log_error "Too many arguments (got extra: '$1')"
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$name" ]]; then
    log_error "Package name required."
    show_usage
    exit 1
  fi
  [[ -n "$system" ]] || system=$(current_system)

  local out="$SCRATCH/versions.json"

  if [[ -n "$version" ]]; then
    # One version: the flake ref to use, the store path it yields, and whether
    # the binary cache has it (otherwise nix compiles it).
    if [[ "$json_mode" == true ]]; then
      api_get resolve "$out" --data-urlencode "name=$name" --data-urlencode "version=$version"
      cat "$out"
      return 0
    fi
    local cached
    resolve_version "$name" "$version" "$system"
    cached=$(cache_status "$R_PATH")
    printf '%s %s for %s\n' "$name" "$R_VERSION" "$system"
    printf '  flake ref   : github:NixOS/nixpkgs/%s#%s\n' "$R_REV" "$R_ATTR"
    printf '  store path  : %s\n' "$R_PATH"
    printf '  cached      : %s (%s)\n' "$cached" "$BINARY_CACHE"
    if [[ "$cached" != yes ]]; then
      log_info "Not in $BINARY_CACHE: nix would BUILD this version from source."
    fi
    printf '\n'
    printf '  nix shell   : nix shell github:NixOS/nixpkgs/%s#%s\n' "$R_REV" "$R_ATTR"
    printf '  flake.nix   : inputs.nixpkgs-%s.url = "github:NixOS/nixpkgs/%s";\n' "${name//./-}" "$R_REV"
    printf '  devenv.yaml : inputs: { nixpkgs-%s: { url: github:NixOS/nixpkgs/%s } }\n' "${name//./-}" "$R_REV"
    return 0
  fi

  # No version: the history, newest first, with the commit nixhub recorded for
  # this system and whether that build is still in the binary cache.
  api_get pkg "$out" --data-urlencode "name=$name"
  if [[ "$json_mode" == true ]]; then
    cat "$out"
    return 0
  fi
  local rows
  rows=$(jq -r --arg s "$system" --argjson n "$limit" '
    .releases[:$n][]
    | . as $r
    | ((.platforms[] | select(.system == $s)) // null) as $p
    | [ $r.version,
        ($r.last_updated[:10]),
        (if $p then $p.commit_hash[:10] else "-" end),
        (if $p then ($p.outputs[] | select(.default == true) | .path) else "-" end) ]
    | @tsv' "$out")
  if [[ -z "$rows" ]]; then
    printf '%s\n' "No versions listed for '$name'."
    return 0
  fi
  local v d c p
  {
    printf 'version\tdate\tcommit (%s)\tcached\n' "$system"
    while IFS=$'\t' read -r v d c p; do
      if [[ "$p" == "-" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$v" "$d" "-" "not built"
      else
        printf '%s\t%s\t%s\t%s\n' "$v" "$d" "$c" "$(cache_status "$p")"
      fi
    done <<< "$rows"
  } | column -t -s $'\t'
}

# --- Usage ---------------------------------------------------------------

show_usage() {
  cat >&2 <<'EOF'
Usage: nix_shell.sh <command> [args...]

Commands:
  search <term> [--json] [--timeout DURATION]       Search nixpkgs for packages by name
  locate <pattern> [-t TYPE] [-n N] [--timeout S]   Find which package provides a file/binary
  run <packages...> -- <cmd> [args]                Run a command with nix packages on PATH
                                                   (name@version pins a version, e.g. duckdb@1.5.3)
  versions <pkg> [<version>] [--system S] [--limit N] [--json]
                                                   Version history from nixhub, or the nixpkgs
                                                   commit + cache status for one version

Examples:
  nix_shell.sh search envsubst
  nix_shell.sh search envsubst --json
  nix_shell.sh locate gtimeout
  nix_shell.sh locate gtimeout -t x -n 10
  nix_shell.sh run envsubst -- envsubst --help
  nix_shell.sh run envsubst jq -- sh -c 'which envsubst && which jq'
  nix_shell.sh run duckdb@1.5.3 -- duckdb --version
  nix_shell.sh versions duckdb
  nix_shell.sh versions duckdb 1.5.3 --system x86_64-linux

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

  local subcommand="$1"
  shift

  case "$subcommand" in
    search) cmd_search "$@" ;;
    locate) cmd_locate "$@" ;;
    run)    cmd_run "$@" ;;
    versions) cmd_versions "$@" ;;
    *)
      log_error "Unknown command: '$subcommand'"
      show_usage
      exit 1
      ;;
  esac
}

# The trap must be set here, at top level, and on ZERR as well as EXIT. Measured
# in zsh 5.9: a trap defined inside a function is local to that function; and an
# error that trips `set -e` inside a function exits WITHOUT running the EXIT
# trap — only ZERR fires there. Either alone left scratch directories behind.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT ZERR
main "$@"
