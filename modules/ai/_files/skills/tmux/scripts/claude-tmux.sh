#!/usr/bin/env zsh
set -euo pipefail

# claude-tmux — wrapper around tmux for Claude Code agent sessions.
# Provides subcommands with sensible defaults so agents avoid raw
# variable-expansion calls that trigger security prompts.

SOCKET_DIR="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/claude-tmux-sockets}"
DELTA_DIR="${TMPDIR:-/tmp}/claude-tmux-delta"

usage() {
  cat <<'USAGE'
Usage: claude-tmux [global-opts] <command> [command-opts]

Global options (before the command):
  -S, --socket-path PATH   tmux socket path (default: $SOCKET_DIR/claude.sock)
  -t, --target TARGET      pane target session:window.pane (default: auto-detect)
  -h, --help               show this help

Commands:
  new      Create a new session
  send     Send keys to a pane
  capture  Print current pane content
  delta    Print pane content that changed since last capture/delta
  keys     Send special key (Enter, C-c, C-d, Escape, …)
  list     List sessions on the socket
  kill     Kill a session or the whole server
  wait     Poll for text in a pane (wraps wait-for-text.sh)
  attach   Print the attach command for the user (does not attach)

Run 'claude-tmux <command> --help' for command-specific help.
USAGE
}

# --- global option parsing ---
socket_path=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -S|--socket-path) socket_path="${2-}"; shift 2 ;;
    -t|--target)      target="${2-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "Unknown global option: $1" >&2; usage; exit 1 ;;
    *)                break ;;  # first non-option is the command
  esac
done

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

command="$1"; shift

# Ensure socket dir exists
mkdir -p "$SOCKET_DIR"

# Default socket path
if [[ -z "$socket_path" ]]; then
  socket_path="$SOCKET_DIR/claude.sock"
fi

# Build base tmux command
tmux_cmd=(tmux -S "$socket_path")

# Auto-detect target: use first session on the socket if not specified
resolve_target() {
  if [[ -n "$target" ]]; then
    printf '%s' "$target"
    return
  fi
  local first
  first="$("${tmux_cmd[@]}" list-sessions -F '#{session_name}' 2>/dev/null | head -1)" || true
  if [[ -z "$first" ]]; then
    echo "No sessions found on socket $socket_path — specify -t TARGET" >&2
    exit 1
  fi
  printf '%s:0.0' "$first"
}

# Delta key for a target (filesystem-safe)
delta_key() {
  local t="$1"
  printf '%s' "${socket_path}::${t}" | sed 's|/|__|g'
}

# ─── new ──────────────────────────────────────────────────────────────
cmd_new() {
  local session="" window="shell" cmd_to_run=""
  local new_usage="Usage: claude-tmux new -s SESSION [-w WINDOW] [-c CMD]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--session) session="${2-}"; shift 2 ;;
      -w|--window)  window="${2-}"; shift 2 ;;
      -c|--cmd)     cmd_to_run="${2-}"; shift 2 ;;
      -h|--help)    echo "$new_usage"; exit 0 ;;
      *)            echo "Unknown option: $1" >&2; echo "$new_usage" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$session" ]]; then
    echo "Session name required (-s)" >&2
    echo "$new_usage" >&2
    exit 1
  fi

  "${tmux_cmd[@]}" new -d -s "$session" -n "$window"

  if [[ -n "$cmd_to_run" ]]; then
    "${tmux_cmd[@]}" send-keys -t "${session}:0.0" -- "$cmd_to_run" Enter
  fi

  echo "Session '$session' created on socket: $socket_path"
  echo ""
  echo "To monitor this session yourself:"
  echo "  tmux -S '$socket_path' attach -t '$session'"
}

# ─── send ─────────────────────────────────────────────────────────────
cmd_send() {
  local literal=true text=""
  local send_usage="Usage: claude-tmux send [-R] TEXT   (sends literal text + Enter)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R|--raw)   literal=false; shift ;;
      -h|--help)  echo "$send_usage"; exit 0 ;;
      -*)         echo "Unknown option: $1" >&2; echo "$send_usage" >&2; exit 1 ;;
      *)          text="$1"; shift ;;
    esac
  done

  if [[ -z "$text" ]]; then
    echo "Text to send is required" >&2
    echo "$send_usage" >&2
    exit 1
  fi

  local t
  t="$(resolve_target)"

  if $literal; then
    "${tmux_cmd[@]}" send-keys -t "$t" -l -- "$text"
    "${tmux_cmd[@]}" send-keys -t "$t" Enter
  else
    "${tmux_cmd[@]}" send-keys -t "$t" -- "$text" Enter
  fi
}

# ─── keys ─────────────────────────────────────────────────────────────
cmd_keys() {
  local keys_usage="Usage: claude-tmux keys KEY [KEY …]   (e.g. Enter, C-c, C-d, Escape)"

  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "$keys_usage"
    [[ $# -eq 0 ]] && exit 1 || exit 0
  fi

  local t
  t="$(resolve_target)"

  "${tmux_cmd[@]}" send-keys -t "$t" "$@"
}

# ─── capture ──────────────────────────────────────────────────────────
cmd_capture() {
  local lines=200 save_delta=true
  local capture_usage="Usage: claude-tmux capture [-l LINES] [--no-save]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--lines)    lines="${2-}"; shift 2 ;;
      --no-save)     save_delta=false; shift ;;
      -h|--help)     echo "$capture_usage"; exit 0 ;;
      *)             echo "Unknown option: $1" >&2; echo "$capture_usage" >&2; exit 1 ;;
    esac
  done

  local t
  t="$(resolve_target)"

  local output
  output="$("${tmux_cmd[@]}" capture-pane -p -J -t "$t" -S "-${lines}")"
  printf '%s\n' "$output"

  if $save_delta; then
    mkdir -p "$DELTA_DIR"
    local key
    key="$(delta_key "$t")"
    printf '%s\n' "$output" > "$DELTA_DIR/$key"
  fi
}

# ─── delta ────────────────────────────────────────────────────────────
cmd_delta() {
  local lines=200
  local delta_usage="Usage: claude-tmux delta [-l LINES]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--lines) lines="${2-}"; shift 2 ;;
      -h|--help)  echo "$delta_usage"; exit 0 ;;
      *)          echo "Unknown option: $1" >&2; echo "$delta_usage" >&2; exit 1 ;;
    esac
  done

  local t
  t="$(resolve_target)"

  local key
  key="$(delta_key "$t")"
  local prev_file="$DELTA_DIR/$key"

  local current
  current="$("${tmux_cmd[@]}" capture-pane -p -J -t "$t" -S "-${lines}")"

  if [[ -f "$prev_file" ]]; then
    # Show only new lines (standard diff format, portable across BSD/GNU)
    diff "$prev_file" <(printf '%s\n' "$current") 2>/dev/null \
      | sed -n 's/^> //p' || true
  else
    printf '%s\n' "$current"
  fi

  # Save current as baseline for next delta
  mkdir -p "$DELTA_DIR"
  printf '%s\n' "$current" > "$prev_file"
}

# ─── list ─────────────────────────────────────────────────────────────
cmd_list() {
  local list_usage="Usage: claude-tmux list [-q QUERY]"
  local query=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q|--query) query="${2-}"; shift 2 ;;
      -h|--help)  echo "$list_usage"; exit 0 ;;
      *)          echo "Unknown option: $1" >&2; echo "$list_usage" >&2; exit 1 ;;
    esac
  done

  local sessions
  if ! sessions="$("${tmux_cmd[@]}" list-sessions -F '#{session_name}|#{session_attached}|#{session_created_string}' 2>/dev/null)"; then
    echo "No tmux server on socket: $socket_path"
    return 0
  fi

  if [[ -n "$query" ]]; then
    sessions="$(printf '%s\n' "$sessions" | grep -i -- "$query" || true)"
  fi

  if [[ -z "$sessions" ]]; then
    echo "No sessions found"
    return 0
  fi

  printf '%s\n' "$sessions" | while IFS='|' read -r name attached created; do
    local state="detached"
    [[ "$attached" == "1" ]] && state="attached"
    printf '  %s  (%s, started %s)\n' "$name" "$state" "$created"
  done
}

# ─── kill ─────────────────────────────────────────────────────────────
cmd_kill() {
  local session="" all=false
  local kill_usage="Usage: claude-tmux kill [-s SESSION | --all]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--session) session="${2-}"; shift 2 ;;
      -A|--all)     all=true; shift ;;
      -h|--help)    echo "$kill_usage"; exit 0 ;;
      *)            echo "Unknown option: $1" >&2; echo "$kill_usage" >&2; exit 1 ;;
    esac
  done

  if $all; then
    "${tmux_cmd[@]}" kill-server 2>/dev/null || true
    echo "Killed all sessions on socket: $socket_path"
  elif [[ -n "$session" ]]; then
    "${tmux_cmd[@]}" kill-session -t "$session"
    echo "Killed session '$session'"
  else
    echo "Specify -s SESSION or --all" >&2
    echo "$kill_usage" >&2
    exit 1
  fi
}

# ─── wait ─────────────────────────────────────────────────────────────
cmd_wait() {
  local pattern="" fixed="" timeout=15 interval=0.5 lines=1000
  local wait_usage="Usage: claude-tmux wait -p PATTERN [-F] [-T SECS] [-i SECS] [-l LINES]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--pattern)  pattern="${2-}"; shift 2 ;;
      -F|--fixed)    fixed="-F"; shift ;;
      -T|--timeout)  timeout="${2-}"; shift 2 ;;
      -i|--interval) interval="${2-}"; shift 2 ;;
      -l|--lines)    lines="${2-}"; shift 2 ;;
      -h|--help)     echo "$wait_usage"; exit 0 ;;
      *)             echo "Unknown option: $1" >&2; echo "$wait_usage" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$pattern" ]]; then
    echo "Pattern required (-p)" >&2
    echo "$wait_usage" >&2
    exit 1
  fi

  local t
  t="$(resolve_target)"

  local grep_flag="-E"
  [[ -n "$fixed" ]] && grep_flag="-F"

  local start_epoch deadline
  start_epoch=$(date +%s)
  deadline=$((start_epoch + timeout))

  while true; do
    local pane_text
    pane_text="$("${tmux_cmd[@]}" capture-pane -p -J -t "$t" -S "-${lines}" 2>/dev/null || true)"

    if printf '%s\n' "$pane_text" | grep $grep_flag -- "$pattern" >/dev/null 2>&1; then
      exit 0
    fi

    local now
    now=$(date +%s)
    if (( now >= deadline )); then
      echo "Timed out after ${timeout}s waiting for: $pattern" >&2
      echo "Last ${lines} lines from $t:" >&2
      printf '%s\n' "$pane_text" >&2
      exit 1
    fi

    sleep "$interval"
  done
}

# ─── attach ───────────────────────────────────────────────────────────
cmd_attach() {
  local t
  t="$(resolve_target)"
  # Extract session name (part before the first colon)
  local sess="${t%%:*}"
  echo "To monitor this session yourself:"
  echo "  tmux -S '$socket_path' attach -t '$sess'"
  echo ""
  echo "Or capture the output once:"
  echo "  tmux -S '$socket_path' capture-pane -p -J -t '$t' -S -200"
}

# ─── dispatch ─────────────────────────────────────────────────────────
case "$command" in
  new)     cmd_new "$@" ;;
  send)    cmd_send "$@" ;;
  keys)    cmd_keys "$@" ;;
  capture) cmd_capture "$@" ;;
  delta)   cmd_delta "$@" ;;
  list)    cmd_list "$@" ;;
  kill)    cmd_kill "$@" ;;
  wait)    cmd_wait "$@" ;;
  attach)  cmd_attach "$@" ;;
  *)       echo "Unknown command: $command" >&2; usage; exit 1 ;;
esac
