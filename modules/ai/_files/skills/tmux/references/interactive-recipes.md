---
name: interactive-recipes
description: "Step-by-step recipes for common interactive tools: Python REPL, lldb, gdb, psql, node, ipdb, shell scripts."
---

# Interactive Tool Recipes

Complete step-by-step patterns for launching, driving, and cleaning up interactive CLI tools in tmux. Each recipe follows the same structure: start, wait for ready, interact, capture, clean up.

All examples assume:

```bash
SOCKET="${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/tmux-use-sockets}/tmux.sock"
mkdir -p "${CLAUDE_TMUX_SOCKET_DIR:-${TMPDIR:-/tmp}/tmux-use-sockets}"
```

## Python REPL

**Critical**: Always set `PYTHON_BASIC_REPL=1`. The enhanced REPL (pyrepl) uses cursor positioning that breaks `send-keys`.

```bash
SESSION=claude-py
tmux -S "$SOCKET" new -d -s "$SESSION" -n py

# Start Python with basic REPL
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'PYTHON_BASIC_REPL=1 python3 -q' Enter

# Wait for prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>>>' -T 10

# Send code (use -l for safety)
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'import sys; print(sys.version)'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter

# Wait for output and next prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>>>' -T 5

# Capture result
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -50
```

### Multi-line Python (for/if/def blocks)

The REPL expects indented continuation lines after `:` and a blank line to end:

```bash
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'for i in range(3):'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter
sleep 0.2

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- '    print(f"item {i}")'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter
sleep 0.2

# Blank line ends the block
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter

./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>>>' -T 5
```

### Alternative: exec from file (for complex code)

```bash
cat > /tmp/agent-code.py << 'PYEOF'
def fibonacci(n):
    a, b = 0, 1
    for _ in range(n):
        yield a
        a, b = b, a + b

for x in fibonacci(10):
    print(x, end=' ')
print()
PYEOF

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- "exec(open('/tmp/agent-code.py').read())" Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>>>' -T 10
```

### Exit

```bash
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'exit()' Enter
# or
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 C-d
```

## lldb (default debugger on macOS)

```bash
SESSION=claude-lldb
tmux -S "$SOCKET" new -d -s "$SESSION" -n lldb

# Start lldb
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'lldb ./myprogram' Enter

# Wait for lldb prompt
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 15

# Set breakpoint
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'breakpoint set --name main' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 5

# Run
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'run' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p 'stop reason' -T 30

# Inspect
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'bt' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 5

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'frame variable' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 5

# Step
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'next' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 10

# Continue
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'continue' Enter

# Interrupt a running process
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 C-c
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(lldb\)' -T 5

# Exit
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'quit' Enter
```

## gdb

```bash
SESSION=claude-gdb
tmux -S "$SOCKET" new -d -s "$SESSION" -n gdb

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'gdb --quiet ./myprogram' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(gdb\)' -T 15

# Disable paging (essential for scripted interaction)
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'set pagination off' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(gdb\)' -T 5

# Set breakpoint and run
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'break main' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(gdb\)' -T 5

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'run' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p 'Breakpoint' -T 30

# Inspect
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'bt' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'info locals' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'print variable_name' Enter

# Exit (gdb asks for confirmation)
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'quit' Enter
sleep 0.5
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'y' Enter
```

## psql (PostgreSQL)

```bash
SESSION=claude-psql
tmux -S "$SOCKET" new -d -s "$SESSION" -n psql

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'psql -h localhost -U myuser mydb' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '=>' -T 15

# Run query
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'SELECT count(*) FROM users;'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '=>' -T 10

# Capture
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -50

# Expand output for wide tables
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- '\x' Enter

# Exit
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- '\q' Enter
```

## node (Node.js REPL)

```bash
SESSION=claude-node
tmux -S "$SOCKET" new -d -s "$SESSION" -n node

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'node' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>' -T 10

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -l -- 'const x = [1,2,3].map(n => n*2); console.log(x);'
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '>' -T 5

# Exit
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- '.exit' Enter
```

## ipdb / pdb (Python debugger)

```bash
SESSION=claude-ipdb
tmux -S "$SOCKET" new -d -s "$SESSION" -n ipdb

tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'PYTHON_BASIC_REPL=1 python3 -m pdb myscript.py' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(Pdb\)' -T 15

# Set breakpoint and continue
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'break 42' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'continue' Enter
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\(Pdb\)' -T 30

# Inspect
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'locals()' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'pp some_variable' Enter

# Step
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'next' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'step' Enter

# Exit
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'quit' Enter
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'y' Enter
```

## Long-running process (server, build, etc.)

```bash
SESSION=claude-server
tmux -S "$SOCKET" new -d -s "$SESSION" -n server

# Start server
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 -- 'npm run dev' Enter

# Wait for ready message
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p 'ready\|listening\|started' -T 60

# Monitor logs
tmux -S "$SOCKET" capture-pane -p -J -t "$SESSION":0.0 -S -100

# Stop server
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 C-c
./scripts/wait-for-text.sh -S "$SOCKET" -t "$SESSION":0.0 -p '\$' -T 10
```

## General pattern

Every interactive tool follows the same loop:

```
1. Create session:  tmux -S "$SOCKET" new -d -s "$SESSION" ...
2. Start program:   tmux -S "$SOCKET" send-keys ... '<command>' Enter
3. Wait for ready:  ./scripts/wait-for-text.sh -S "$SOCKET" -t ... -p '<prompt>'
4. Send input:      tmux -S "$SOCKET" send-keys -t ... -l -- '<input>'
                    tmux -S "$SOCKET" send-keys -t ... Enter
5. Wait for output: ./scripts/wait-for-text.sh or sleep
6. Capture output:  tmux -S "$SOCKET" capture-pane -p -J -t ... -S -200
7. Repeat 4–6
8. Exit program:    tmux -S "$SOCKET" send-keys ... 'exit' Enter (or C-d)
9. Kill session:    tmux -S "$SOCKET" kill-session -t "$SESSION"
```

## Cleanup

Always clean up sessions when done:

```bash
tmux -S "$SOCKET" kill-session -t "$SESSION"
```
