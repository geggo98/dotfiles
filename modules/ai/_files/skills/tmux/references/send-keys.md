---
name: send-keys
description: "Complete reference for tmux send-keys: literal text, control keys, special keys, quoting, multi-line input, and common pitfalls."
---

# send-keys Reference

`send-keys` is the primary way an agent types into a tmux pane. Understanding its modes prevents the most common class of bugs (swallowed input, unintended key combos, broken quoting).

All examples assume `SOCKET` and `TARGET` are set:

```bash
SOCKET="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/tmux-use-sockets}/tmux.sock"
TARGET="claude-py:0.0"
```

## Two modes: key names vs literal text

### Key-name mode (default)

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'echo hello' Enter
```

Each whitespace-separated token is interpreted as a **key name**. `Enter`, `Escape`, `Space`, `Tab`, `C-c`, `C-d`, `BSpace`, `Up`, `Down`, `Left`, `Right`, `F1`–`F12` are recognized. Unrecognized tokens are sent as literal characters.

The trailing `Enter` is a key name — it presses the Enter key. Without it, text sits in the input buffer unsent.

### Literal mode (`-l`)

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- "$text"
```

The **entire argument** is sent character-by-character. No key-name interpretation. Use this when:

- The text might accidentally match a key name (e.g., a variable containing `Enter` or `Escape`).
- You want to paste multi-line text without triggering Enter after each line.
- The command contains spaces, quotes, or special characters you don't want shell-expanded.

**Caveat**: `-l` cannot send control keys or Enter. Send those separately:

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'print("hello world")'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
```

## Control keys and special keys

| Key | send-keys token | Notes |
|-----|----------------|-------|
| Enter / Return | `Enter` or `C-m` | |
| Ctrl+C (interrupt) | `C-c` | |
| Ctrl+D (EOF) | `C-d` | |
| Ctrl+Z (suspend) | `C-z` | |
| Ctrl+L (clear) | `C-l` | |
| Ctrl+A (line start) | `C-a` | |
| Ctrl+E (line end) | `C-e` | |
| Ctrl+U (kill line) | `C-u` | |
| Ctrl+W (kill word) | `C-w` | |
| Escape | `Escape` | |
| Tab | `Tab` | |
| Backspace | `BSpace` | |
| Arrow keys | `Up`, `Down`, `Left`, `Right` | |
| Page up/down | `PageUp`, `PageDown` | |
| Home / End | `Home`, `End` | |
| Function keys | `F1` … `F12` | |

### Combining text and control keys

Send text first, then the control key as a separate token:

```bash
# Type a command and press Enter
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'ls -la /tmp' Enter

# Type text, then Ctrl+C to cancel
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'some partial input' C-c
```

Or use two separate send-keys calls for clarity:

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'complex "quoted" text'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
```

## Quoting strategies

### Problem: shell expansion before tmux sees the text

The outer shell (your Bash call) expands `$`, `!`, `` ` ``, `\`, etc. **before** tmux receives them. You must quote to prevent this.

### Strategy 1: Single quotes (simplest)

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'echo $HOME' Enter
```

The pane receives `echo $HOME` literally. The pane's shell then expands `$HOME`.

### Strategy 2: ANSI-C quoting for embedded single quotes

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -- $'echo \'hello world\'' Enter
```

### Strategy 3: Literal mode + variable

```bash
cmd='import os; print(os.getcwd())'
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- "$cmd"
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
```

This is the **safest approach for dynamic content**. The variable is expanded by your shell, but `-l` prevents tmux from interpreting key names.

### Strategy 4: Heredoc for multi-line (via a temp file or paste)

For multi-line Python, write to a file and source it, or use literal mode with embedded newlines:

```bash
# Write to file, then source
cat > /tmp/agent-script.py << 'PYEOF'
for i in range(10):
    print(f"line {i}")
PYEOF
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'exec(open("/tmp/agent-script.py").read())' Enter
```

Alternatively, send line-by-line with Enter after each:

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'for i in range(3):'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- '    print(i)'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter  # blank line to end block
```

## Timing and pacing

### Why timing matters

Interactive programs (Python REPL, gdb, psql) may not be ready to accept input immediately. Sending keystrokes too fast can:

- Drop characters if the program is still initializing.
- Interleave with program output, corrupting both.
- Miss prompts that indicate readiness.

### Best practice: poll then send

```bash
# 1. Start the program
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# 2. Wait for the prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$TARGET" -p '>>>' -T 10

# 3. Now send input
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'print("ready")'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
```

### Delays between rapid sends

If sending multiple lines to a program that echoes (like a REPL), add a small sleep or poll between sends:

```bash
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'x = 42'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.3
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- 'print(x)'
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter
```

## Common pitfalls

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Forgot `Enter` | Text appears but command doesn't execute | Add `Enter` as last token |
| Used `-l` with `Enter` appended | Literal string `Enter` appears in pane | Send `Enter` as a separate `send-keys` call |
| Unquoted `$VAR` | Variable expanded by agent's shell, not pane's | Use single quotes or `-l` with double quotes |
| Sent too fast | Characters dropped or garbled | Poll for prompt with `wait-for-text.sh` first |
| Space in key-name mode | `send-keys 'a b'` sends `a`, `Space`, `b` | Use `-l` for strings containing spaces |
| Backslash eaten | `\n` becomes newline before tmux sees it | Use single quotes: `'\n'` |
| `--` missing | Text starting with `-` treated as flag | Always use `--` before the text argument |

## The `--` separator

Always place `--` before the text/key argument to prevent tmux from interpreting leading dashes as flags:

```bash
# Without -- : tmux interprets -l as a flag (ambiguous)
tmux -S "$SOCKET" send-keys -t "$TARGET" '-l flag'    # WRONG

# With -- : -l flag is sent as text
tmux -S "$SOCKET" send-keys -t "$TARGET" -- '-l flag' Enter  # CORRECT
```

## Cheat sheet

```bash
# Send a shell command and execute it
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'ls -la' Enter

# Send literal text (safe for any content)
tmux -S "$SOCKET" send-keys -t "$TARGET" -l -- "$variable"
tmux -S "$SOCKET" send-keys -t "$TARGET" Enter

# Interrupt running process
tmux -S "$SOCKET" send-keys -t "$TARGET" C-c

# Send EOF (close stdin / exit shell)
tmux -S "$SOCKET" send-keys -t "$TARGET" C-d

# Clear the screen
tmux -S "$SOCKET" send-keys -t "$TARGET" C-l

# Navigate readline (bash/zsh prompt)
tmux -S "$SOCKET" send-keys -t "$TARGET" C-a  # beginning of line
tmux -S "$SOCKET" send-keys -t "$TARGET" C-e  # end of line
tmux -S "$SOCKET" send-keys -t "$TARGET" C-u  # kill line
tmux -S "$SOCKET" send-keys -t "$TARGET" C-w  # kill word back

# Arrow keys for history / cursor
tmux -S "$SOCKET" send-keys -t "$TARGET" Up    # previous command
tmux -S "$SOCKET" send-keys -t "$TARGET" Down  # next command
```
