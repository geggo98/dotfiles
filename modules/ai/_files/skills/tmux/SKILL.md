---
name: tmux
description: "Remote control tmux sessions for interactive CLIs (python, gdb, etc.) by sending keystrokes and scraping pane output."
license: Vibecoded
allowed-tools: Read(references/*) Bash(./scripts/claude-tmux.sh *)
---

# tmux Skill

Use tmux as a programmable terminal multiplexer for interactive work. Works on Linux and macOS with stock tmux; the `claude-tmux` wrapper manages sockets, targets, and defaults automatically.

## Detailed References

| Topic | Description | Reference |
|-------|-------------|-----------|
| Sending keystrokes | `send-keys` modes (literal vs key-name), control keys, quoting, multi-line input, pitfalls | [send-keys](references/send-keys.md) |
| Capturing output | `capture-pane` flags, scrollback depth, polling patterns, filtering | [capture-output](references/capture-output.md) |
| Interactive recipes | Step-by-step for Python, lldb, gdb, psql, node, pdb, long-running servers | [interactive-recipes](references/interactive-recipes.md) |
| Session management | Creating, targeting, inspecting, and cleaning up sessions/windows/panes | [session-management](references/session-management.md) |

## Wrapper Script: `claude-tmux`

All tmux interactions go through `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh`. This avoids raw variable expansion in shell commands (no more `$SOCKET` / `$SESSION` security prompts).

**Defaults:**
- Socket: `${TMPDIR}/claude-tmux-sockets/claude.sock` (created automatically)
- Target: auto-detected (first session on the socket, pane `:0.0`)

### Commands at a glance

| Command | Description | Example |
|---------|-------------|---------|
| `new`     | Create a session | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh new -s claude-py -c 'PYTHON_BASIC_REPL=1 python3 -q'` |
| `send`    | Send literal text + Enter | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh send 'print("hello")'` |
| `keys`    | Send special keys | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh keys C-c` |
| `capture` | Print current pane content | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh capture` |
| `delta`   | Print only new output since last capture/delta | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh delta` |
| `wait`    | Poll for text pattern | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh wait -p '^>>>'` |
| `list`    | List sessions | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh list` |
| `kill`    | Kill session or server | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh kill -s claude-py` |
| `attach`  | Print monitor command for user | `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh attach` |

### Global options (before the command)

- `-S PATH` — override socket path
- `-t TARGET` — override pane target (`session:window.pane`)

## Quickstart

```bash
# Start a Python REPL session
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh new -s claude-py -c 'PYTHON_BASIC_REPL=1 python3 -q'

# Wait for the prompt
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh wait -p '^>>>'

# Send code
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh send 'print("hello world")'

# Read output
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh capture

# Read only new output since last capture
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh delta

# Clean up
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh kill -s claude-py
```

After starting a session ALWAYS tell the user how to monitor it. Use `${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh attach` to print the command, or manually give them:

```
To monitor this session yourself:
  tmux -S '<socket-path>' attach -t '<session>'
```

This must ALWAYS be printed right after a session was started and once again at the end of the tool loop.

## Targeting specific panes

When running multiple sessions or panes, use `-t` globally:

```bash
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh -t claude-gdb:0.0 send 'bt'
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh -t claude-gdb:0.0 capture
```

Without `-t`, the script auto-detects the first session on the socket.

## Sending input safely

- `send` uses `-l` (literal mode) by default — no shell expansion, no tmux key interpretation. Text is followed by Enter automatically.
- Use `send -R` for raw mode (tmux key names like `Up`, `Down` are interpreted).
- Use `keys` for special keys without text: `keys C-c`, `keys C-d`, `keys Escape`, `keys Enter`.

## Watching output

- `capture` prints the last 200 lines (adjustable with `-l`). It also saves a snapshot for `delta`.
- `delta` prints only lines that are new since the last `capture` or `delta` call — useful for tracking incremental output without re-reading everything.
- `wait -p PATTERN` polls until a regex matches (default 15s timeout). Use `-F` for fixed strings, `-T` for custom timeout.

## Spawning Processes

- When asked to debug, use lldb by default.
- When starting a python interactive shell, always set `PYTHON_BASIC_REPL=1`. Pass it via `-c`:
  ```bash
  ${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh new -s claude-py -c 'PYTHON_BASIC_REPL=1 python3 -q'
  ```

## Interactive tool recipes

- **Python REPL**: `new -s claude-py -c 'PYTHON_BASIC_REPL=1 python3 -q'`; `wait -p '^>>>'`; `send 'code'`; interrupt with `keys C-c`.
- **lldb**: `new -s claude-lldb -c 'lldb ./a.out'`; `wait -p '\\(lldb\\)'`; `send 'breakpoint set ...'`; exit via `send quit`.
- **gdb**: `new -s claude-gdb -c 'gdb --quiet ./a.out'`; `wait -p '\\(gdb\\)'`; `send 'set pagination off'`; exit via `send quit` then `send y`.
- **Other TTY apps** (psql, node, bash): same pattern — `new` with `-c`, `wait` for prompt, `send` commands.

## Cleanup

```bash
# Kill one session
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh kill -s claude-py

# Kill everything on the socket
${CLAUDE_SKILL_DIR}/scripts/claude-tmux.sh kill --all
```
