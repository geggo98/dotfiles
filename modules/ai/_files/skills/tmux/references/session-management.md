---
name: session-management
description: "Creating, listing, targeting, and cleaning up tmux sessions, windows, and panes on a private socket."
---

# Session Management Reference

How to create, organize, inspect, and tear down tmux sessions using the private socket convention.

All examples assume:

```bash
SOCKET_DIR="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/tmux-use-sockets}"
mkdir -p "$SOCKET_DIR"
SOCKET="$SOCKET_DIR/tmux.sock"
```

## Creating sessions

### New detached session

```bash
tmux -S "$SOCKET" new -d -s claude-py -n shell
```

- `-d` — detached (don't attach the agent's terminal)
- `-s claude-py` — session name (keep short, slug-like, no spaces)
- `-n shell` — name for the first window

### Session with a specific command

```bash
tmux -S "$SOCKET" new -d -s claude-py -n py 'PYTHON_BASIC_REPL=1 python3 -q'
```

The command runs directly in the pane. When the command exits, the pane closes.

### Session with specific dimensions

```bash
tmux -S "$SOCKET" new -d -s claude-wide -x 200 -y 50
```

Useful when you need wide output (e.g., tables, log lines).

## Targeting: sessions, windows, panes

tmux uses the format `session:window.pane`:

| Target | Meaning |
|--------|---------|
| `claude-py` | Session `claude-py`, active window, active pane |
| `claude-py:0` | Session `claude-py`, window index 0, active pane |
| `claude-py:0.0` | Session `claude-py`, window 0, pane 0 |
| `claude-py:shell` | Session `claude-py`, window named `shell` |
| `claude-py:shell.1` | Session `claude-py`, window `shell`, pane 1 |

**Best practice**: Always use the full `session:window.pane` form (`claude-py:0.0`) to avoid ambiguity.

## Windows (tabs within a session)

### Create a new window

```bash
tmux -S "$SOCKET" new-window -t claude-py -n build
```

### List windows

```bash
tmux -S "$SOCKET" list-windows -t claude-py
```

### Select a window

```bash
tmux -S "$SOCKET" select-window -t claude-py:1
```

## Panes (splits within a window)

### Split horizontally (top/bottom)

```bash
tmux -S "$SOCKET" split-window -v -t claude-py:0
```

### Split vertically (left/right)

```bash
tmux -S "$SOCKET" split-window -h -t claude-py:0
```

### List panes

```bash
tmux -S "$SOCKET" list-panes -t claude-py:0
```

### Resize a pane

```bash
tmux -S "$SOCKET" resize-pane -t claude-py:0.1 -D 10  # 10 lines down
tmux -S "$SOCKET" resize-pane -t claude-py:0.1 -R 20  # 20 cols right
tmux -S "$SOCKET" resize-pane -t claude-py:0.0 -x 120 # set width to 120
```

## Inspecting

### List all sessions on the socket

```bash
tmux -S "$SOCKET" list-sessions
```

### List all sessions with details

```bash
tmux -S "$SOCKET" list-sessions -F '#{session_name} (#{session_windows} windows, #{?session_attached,attached,detached})'
```

### List all panes across all sessions

```bash
tmux -S "$SOCKET" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_width}x#{pane_height}'
```

### Check pane dimensions

```bash
tmux -S "$SOCKET" display-message -t claude-py:0.0 -p '#{pane_width}x#{pane_height}'
```

### Check what command runs in a pane

```bash
tmux -S "$SOCKET" display-message -t claude-py:0.0 -p '#{pane_current_command}'
```

### Using find-sessions.sh

```bash
# All sessions on specific socket
./scripts/find-sessions.sh -S "$SOCKET"

# Filter by name
./scripts/find-sessions.sh -S "$SOCKET" -q python

# Scan all agent sockets
./scripts/find-sessions.sh --all
```

## User monitoring

After creating a session, **always** tell the user how to attach:

```bash
echo "To monitor this session yourself:"
echo "  tmux -S $SOCKET attach -t $SESSION"
echo ""
echo "Or to capture the output once:"
echo "  tmux -S $SOCKET capture-pane -p -J -t $SESSION:0.0 -S -200"
```

The user detaches with `Ctrl+b d`.

## Cleanup

### Kill a single session

```bash
tmux -S "$SOCKET" kill-session -t claude-py
```

### Kill all sessions on the socket

```bash
tmux -S "$SOCKET" list-sessions -F '#{session_name}' | xargs -n1 tmux -S "$SOCKET" kill-session -t
```

### Kill the entire tmux server on the socket

```bash
tmux -S "$SOCKET" kill-server
```

This removes the socket file as well.

### Check if a session still exists

```bash
if tmux -S "$SOCKET" has-session -t claude-py 2>/dev/null; then
  echo "Session exists"
else
  echo "Session gone"
fi
```
