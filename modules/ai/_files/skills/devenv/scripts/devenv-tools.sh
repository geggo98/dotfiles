#!/bin/zsh
set -euo pipefail

# Direct, short-lived CLI calls. Never start the memory-heavy MCP server.
usage() {
  cat <<'EOF'
Usage: devenv-tools.sh COMMAND [ARGUMENTS]
  search_packages QUERY       Search packages AND options (native CLI output)
  search_options QUERY        Same combined search
  list_processes
  get_process_status NAME
  get_process_logs NAME [LINES]  Default: 100 lines
  start_process NAME
  stop_process NAME
  restart_process NAME

Run in the devenv project directory. Set DEVENV_BIN to select a full devenv CLI.
The named start command may start the process manager and required dependencies.
EOF
}

fail() { print -ru2 -- "devenv-tools: $*"; exit 2; }

(( $# )) || { usage >&2; exit 2; }
action=$1
shift
typeset -a cli_args
case "$action" in
  -h|--help) usage; exit 0 ;;
  search_packages|search_options)
    (( $# == 1 )) && [[ -n $1 ]] || fail "$action requires QUERY"
    cli_args=(search -- "$1") ;;
  list_processes)
    (( $# == 0 )) || fail "$action takes no arguments"
    cli_args=(processes list) ;;
  get_process_status|start_process|stop_process|restart_process)
    (( $# == 1 )) && [[ -n $1 ]] || fail "$action requires NAME"
    case "$action" in
      get_process_status) verb=status ;;
      start_process) verb=start ;;
      stop_process) verb=stop ;;
      restart_process) verb=restart ;;
    esac
    cli_args=(processes "$verb" -- "$1") ;;
  get_process_logs)
    (( $# >= 1 && $# <= 2 )) && [[ -n $1 ]] || fail "$action requires NAME [LINES]"
    lines=${2:-100}
    [[ $lines == <-> ]] || fail "LINES must be a nonnegative integer"
    cli_args=(processes logs --lines "$lines" -- "$1") ;;
  *) fail "unknown command: $action (see --help)" ;;
esac

# `devenv` inside a flake shell can be a restricted wrapper. Check capabilities
# instead of trusting its name or version. An explicit override must not fall back.
is_full_cli() {
  local help_text
  [[ -x $1 ]] || return 1
  help_text=$("$1" -h 2>/dev/null) || return 1
  [[ $help_text == *$'\n  search '* && $help_text == *$'\n  processes '* ]]
}

typeset -a candidates
if [[ -n ${DEVENV_BIN:-} ]]; then
  candidates=("$DEVENV_BIN")
else
  candidates=("$HOME/.nix-profile/bin/devenv" "/etc/profiles/per-user/$(id -un)/bin/devenv")
  for directory in "${path[@]}"; do
    candidates+=("${directory:-.}/devenv")
  done
fi

for candidate in "${candidates[@]}"; do
  if is_full_cli "$candidate"; then
    exec "$candidate" --no-tui "${cli_args[@]}"
  fi
done
fail "full devenv CLI not found; set DEVENV_BIN to its executable path (flake wrappers lack search/processes)"
