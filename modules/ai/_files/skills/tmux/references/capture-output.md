---
name: capture-output
description: "Reading tmux pane contents: capture-pane options, scrollback, joined lines, filtering, and polling patterns."
---

# capture-pane Reference

`capture-pane` is how the agent reads what a program has printed. It returns the text content of a pane's visible area and scrollback buffer.

All examples assume `SOCKET` and `TARGET` are set:

```bash
SOCKET="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/claude-tmux-sockets}/claude.sock"
TARGET="claude-py:0.0"
```

## Basic capture

```bash
# Print pane contents to stdout
tmux -S "$SOCKET" capture-pane -p -t "$TARGET"
```

- `-p` sends output to stdout (without it, capture goes to a paste buffer).
- `-t` specifies the target pane.

## Useful flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-p` | Print to stdout | Always use this |
| `-J` | Join wrapped lines | Prevents artificial line breaks from pane width |
| `-S -N` | Start capture N lines from bottom | `-S -200` captures last 200 lines |
| `-S 0` | Start from beginning of scrollback | Full history |
| `-E N` | End at line N | Combine with `-S` for a range |
| `-e` | Include escape sequences (colors) | Rarely needed for agents |

## Recommended capture command

```bash
tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -200
```

This captures the last 200 lines with joined wrapped lines — the best default for agent use.

### Why `-J` matters

Without `-J`, a long line that wraps across the pane width appears as multiple lines:

```
# Without -J (pane is 80 cols wide):
this is a very long line that wraps around the terminal window and continues on t
he next line

# With -J:
this is a very long line that wraps around the terminal window and continues on the next line
```

### Adjusting scrollback depth

```bash
# Last 50 lines (fast, for prompt detection)
tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -50

# Last 500 lines (for finding earlier output)
tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -500

# Entire scrollback (slow for large buffers)
tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S 0
```

## Polling for output

### Pattern: wait for specific text

Use `wait-for-text.sh` for reliable polling:

```bash
# Wait for Python prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$TARGET" -p '>>>' -T 15

# Wait for gdb prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$TARGET" -p '\(gdb\)' -T 10

# Wait for fixed string (no regex)
./scripts/wait-for-text.sh -S "$SOCKET" -t "$TARGET" -F -p 'Build succeeded' -T 60
```

### Pattern: wait for idle (no new output)

Poll and compare captures. If the content hash is stable for N seconds, the pane is idle:

```bash
last_hash=""
idle_count=0
while true; do
  content=$(tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -100)
  hash=$(printf '%s' "$content" | md5)
  if [[ "$hash" == "$last_hash" ]]; then
    idle_count=$((idle_count + 1))
    if (( idle_count >= 4 )); then  # 4 * 0.5s = 2s idle
      break
    fi
  else
    idle_count=0
    last_hash="$hash"
  fi
  sleep 0.5
done
```

### Pattern: capture after command

```bash
# Send command
tmux -S "$SOCKET" send-keys -t "$TARGET" -- 'echo done-marker-12345' Enter

# Wait for marker in output
./scripts/wait-for-text.sh -S "$SOCKET" -t "$TARGET" -F -p 'done-marker-12345' -T 10

# Capture everything
output=$(tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -200)
```

## Filtering captured output

### Extract lines after a marker

```bash
output=$(tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -200)

# Everything after ">>>" prompt
echo "$output" | sed -n '/>>>/,$p'

# Last N lines only
echo "$output" | tail -20
```

### Check for errors

```bash
output=$(tmux -S "$SOCKET" capture-pane -p -J -t "$TARGET" -S -100)

if echo "$output" | grep -qi 'error\|traceback\|exception'; then
  echo "Error detected in pane output"
fi
```

## Pane dimensions

The capture width depends on the pane size. For consistent output, you can resize the pane before capturing:

```bash
# Check current size
tmux -S "$SOCKET" display-message -t "$TARGET" -p '#{pane_width}x#{pane_height}'

# Resize for wider captures (200 columns)
tmux -S "$SOCKET" resize-pane -t "$TARGET" -x 200
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Empty output | Pane has no scrollback yet | Wait for the program to produce output |
| Truncated lines | Missing `-J` flag | Add `-J` to join wrapped lines |
| Missing old output | `-S` value too small | Increase: `-S -500` or `-S 0` |
| ANSI escape codes in output | Terminal colors | Usually harmless; add `-e` only if you need them |
| Output includes prompt line | Normal behavior | Filter with `grep -v` or `sed` if needed |
