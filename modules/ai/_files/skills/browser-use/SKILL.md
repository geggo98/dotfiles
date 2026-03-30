---
name: browser-use
description: "Automates browser interactions for web testing, form filling, screenshots, and data extraction. Use when the user needs to navigate websites, interact with web pages, fill forms, take screenshots, or extract information from web pages."
argument-hint: "<task description or URL>"
allowed-tools: Read(references/*) Bash(./scripts/browser-use.sh *)
dependencies: "uv, gtimeout"
---

# Browser Automation with browser-use CLI

The `./scripts/browser-use.sh` command provides fast, persistent browser automation. It maintains browser sessions across commands, enabling complex multi-step workflows.

For more information, see https://github.com/browser-use/browser-use/blob/main/browser_use/skill_cli/README.md

> **Important:** Run the script directly (`./scripts/browser-use.sh`). Do **not** prefix with `bash` — the script requires zsh and will fail under bash.

> **Security:** Never use compound commands (`cd ... &&`), shell redirects (`2>/dev/null`), or pipes with this script. These trigger manual approval prompts. Instead, use the built-in output control flags below.

## Output Control Flags

These flags are handled by the wrapper script and work with any command. They eliminate the need for shell redirects or pipes, avoiding security prompts.

```bash
# Silent mode — discard all output, only propagate exit code
./scripts/browser-use.sh --silent close                    # Close without output
./scripts/browser-use.sh --silent close --all              # Clean up silently

# Head/tail — limit output to first/last N lines
./scripts/browser-use.sh --head 20 state                   # First 20 lines only
./scripts/browser-use.sh --tail 10 state                   # Last 10 lines only
./scripts/browser-use.sh --head 5 --tail 5 get html        # First 5 + last 5 lines

# Regex match — filter output lines matching a pattern (ERE syntax)
./scripts/browser-use.sh --match "button|link" state        # Only lines with "button" or "link"
./scripts/browser-use.sh --match "^\[[0-9]" state           # Only indexed element lines

# Regex replace — search and replace in output (sed ERE syntax, '|' delimiter)
./scripts/browser-use.sh --replace "\s+$" "" state          # Strip trailing whitespace
./scripts/browser-use.sh --replace "(https?://)[^ ]+" "\\1..." get html  # Redact URLs
```

**Combining flags:** Filters apply in order: match → replace → head → tail.

```bash
# Filter to buttons, show only the first 10
./scripts/browser-use.sh --match "button" --head 10 state

# Extract text, strip HTML tags, show last 5 lines
./scripts/browser-use.sh --replace "<[^>]+>" "" --tail 5 get html --selector "main"
```

## Core Workflow

1. **Navigate**: `./scripts/browser-use.sh open <url>` - Opens URL (starts browser if needed)
2. **Inspect**: `./scripts/browser-use.sh state` - Returns clickable elements with indices
3. **Interact**: Use indices from state to interact (`./scripts/browser-use.sh click 5`, `./scripts/browser-use.sh input 3 "text"`)
4. **Verify**: `./scripts/browser-use.sh state` or `./scripts/browser-use.sh screenshot` to confirm actions
5. **Repeat**: Browser stays open between commands
6. **Close**: `./scripts/browser-use.sh close` - Closes browser, free resources

## Browser Modes

```bash
./scripts/browser-use.sh --browser chromium open <url>      # Default: headless Chromium
./scripts/browser-use.sh --browser chromium --headed open <url>  # Visible Chromium window
./scripts/browser-use.sh --browser real open <url>          # Real Chrome (no profile = fresh)
./scripts/browser-use.sh --browser real --profile "Default" open <url>  # Real Chrome with your login sessions
./scripts/browser-use.sh --browser remote open <url>        # Cloud browser
```

- **chromium**: Fast, isolated, headless by default
- **real**: Uses a real Chrome binary. Without `--profile`, uses a persistent but empty CLI profile at `~/.config/browseruse/profiles/cli/`. With `--profile "ProfileName"`, copies your actual Chrome profile (cookies, logins, extensions)
- **remote**: Cloud-hosted browser with proxy support

## Essential Commands

```bash
# Navigation
./scripts/browser-use.sh open <url>                    # Navigate to URL
./scripts/browser-use.sh back                          # Go back
./scripts/browser-use.sh scroll down                   # Scroll down (--amount N for pixels)

# Page State (always run state first to get element indices)
./scripts/browser-use.sh state                         # Get URL, title, clickable elements
./scripts/browser-use.sh screenshot                    # Take screenshot (base64)
./scripts/browser-use.sh screenshot path.png           # Save screenshot to file

# Interactions (use indices from state)
./scripts/browser-use.sh click <index>                 # Click element
./scripts/browser-use.sh type "text"                   # Type into focused element
./scripts/browser-use.sh input <index> "text"          # Click element, then type
./scripts/browser-use.sh keys "Enter"                  # Send keyboard keys
./scripts/browser-use.sh select <index> "option"       # Select dropdown option

# Data Extraction
./scripts/browser-use.sh eval "document.title"         # Execute JavaScript
./scripts/browser-use.sh get text <index>              # Get element text
./scripts/browser-use.sh get html --selector "h1"      # Get scoped HTML

# Wait
./scripts/browser-use.sh wait selector "h1"            # Wait for element
./scripts/browser-use.sh wait text "Success"           # Wait for text

# Session
./scripts/browser-use.sh sessions                      # List active sessions
./scripts/browser-use.sh close                         # Close current session
./scripts/browser-use.sh close --all                   # Close all sessions

# AI Agent
./scripts/browser-use.sh -b remote run "task"          # Run agent in cloud (async by default)
./scripts/browser-use.sh task status <id>              # Check cloud task progress
```

## Commands

### Navigation & Tabs
```bash
./scripts/browser-use.sh open <url>                    # Navigate to URL
./scripts/browser-use.sh back                          # Go back in history
./scripts/browser-use.sh scroll down                   # Scroll down
./scripts/browser-use.sh scroll up                     # Scroll up
./scripts/browser-use.sh scroll down --amount 1000     # Scroll by specific pixels (default: 500)
./scripts/browser-use.sh switch <tab>                  # Switch to tab by index
./scripts/browser-use.sh close-tab                     # Close current tab
./scripts/browser-use.sh close-tab <tab>              # Close specific tab
```

### Page State
```bash
./scripts/browser-use.sh state                         # Get URL, title, and clickable elements
./scripts/browser-use.sh screenshot                    # Take screenshot (outputs base64)
./scripts/browser-use.sh screenshot path.png           # Save screenshot to file
./scripts/browser-use.sh screenshot --full path.png    # Full page screenshot
```

### Interactions
```bash
./scripts/browser-use.sh click <index>                 # Click element
./scripts/browser-use.sh type "text"                   # Type text into focused element
./scripts/browser-use.sh input <index> "text"          # Click element, then type text
./scripts/browser-use.sh keys "Enter"                  # Send keyboard keys
./scripts/browser-use.sh keys "Control+a"              # Send key combination
./scripts/browser-use.sh select <index> "option"       # Select dropdown option
./scripts/browser-use.sh hover <index>                 # Hover over element (triggers CSS :hover)
./scripts/browser-use.sh dblclick <index>              # Double-click element
./scripts/browser-use.sh rightclick <index>            # Right-click element (context menu)
```

Use indices from `./scripts/browser-use.sh state`.

### JavaScript & Data
```bash
./scripts/browser-use.sh eval "document.title"         # Execute JavaScript, return result
./scripts/browser-use.sh get title                     # Get page title
./scripts/browser-use.sh get html                      # Get full page HTML
./scripts/browser-use.sh get html --selector "h1"      # Get HTML of specific element
./scripts/browser-use.sh get text <index>              # Get text content of element
./scripts/browser-use.sh get value <index>             # Get value of input/textarea
./scripts/browser-use.sh get attributes <index>        # Get all attributes of element
./scripts/browser-use.sh get bbox <index>              # Get bounding box (x, y, width, height)
```

### Cookies
```bash
./scripts/browser-use.sh cookies get                   # Get all cookies
./scripts/browser-use.sh cookies get --url <url>       # Get cookies for specific URL
./scripts/browser-use.sh cookies set <name> <value>    # Set a cookie
./scripts/browser-use.sh cookies set name val --domain .example.com --secure --http-only
./scripts/browser-use.sh cookies set name val --same-site Strict  # SameSite: Strict, Lax, or None
./scripts/browser-use.sh cookies set name val --expires 1735689600  # Expiration timestamp
./scripts/browser-use.sh cookies clear                 # Clear all cookies
./scripts/browser-use.sh cookies clear --url <url>     # Clear cookies for specific URL
./scripts/browser-use.sh cookies export <file>         # Export all cookies to JSON file
./scripts/browser-use.sh cookies export <file> --url <url>  # Export cookies for specific URL
./scripts/browser-use.sh cookies import <file>         # Import cookies from JSON file
```

### Wait Conditions
```bash
./scripts/browser-use.sh wait selector "h1"            # Wait for element to be visible
./scripts/browser-use.sh wait selector ".loading" --state hidden  # Wait for element to disappear
./scripts/browser-use.sh wait selector "#btn" --state attached    # Wait for element in DOM
./scripts/browser-use.sh wait text "Success"           # Wait for text to appear
./scripts/browser-use.sh wait selector "h1" --timeout 5000  # Custom timeout in ms
```

### Python Execution
```bash
./scripts/browser-use.sh python "x = 42"               # Set variable
./scripts/browser-use.sh python "print(x)"             # Access variable (outputs: 42)
./scripts/browser-use.sh python "print(browser.url)"   # Access browser object
./scripts/browser-use.sh python --vars                 # Show defined variables
./scripts/browser-use.sh python --reset                # Clear Python namespace
./scripts/browser-use.sh python --file script.py       # Execute Python file
```

The Python session maintains state across commands. The `browser` object provides:
- `browser.url`, `browser.title`, `browser.html` — page info
- `browser.goto(url)`, `browser.back()` — navigation
- `browser.click(index)`, `browser.type(text)`, `browser.input(index, text)`, `browser.keys(keys)` — interactions
- `browser.screenshot(path)`, `browser.scroll(direction, amount)` — visual
- `browser.wait(seconds)`, `browser.extract(query)` — utilities


### Task Management
```bash
./scripts/browser-use.sh task list                     # List recent tasks
./scripts/browser-use.sh task list --limit 20          # Show more tasks
./scripts/browser-use.sh task list --status finished   # Filter by status (finished, stopped)
./scripts/browser-use.sh task list --session <id>      # Filter by session ID
./scripts/browser-use.sh task list --json              # JSON output

./scripts/browser-use.sh task status <task-id>         # Get task status (latest step only)
./scripts/browser-use.sh task status <task-id> -c      # All steps with reasoning
./scripts/browser-use.sh task status <task-id> -v      # All steps with URLs + actions
./scripts/browser-use.sh task status <task-id> --last 5  # Last N steps only
./scripts/browser-use.sh task status <task-id> --step 3  # Specific step number
./scripts/browser-use.sh task status <task-id> --reverse # Newest first

./scripts/browser-use.sh task stop <task-id>           # Stop a running task
./scripts/browser-use.sh task logs <task-id>           # Get task execution logs
```


### Session Management
```bash
./scripts/browser-use.sh sessions                      # List active sessions
./scripts/browser-use.sh close                         # Close current session
./scripts/browser-use.sh close --all                   # Close all sessions
```

### Profile Management

#### Local Chrome Profiles (`--browser real`)
```bash
./scripts/browser-use.sh -b real profile list          # List local Chrome profiles
./scripts/browser-use.sh -b real profile cookies "Default"  # Show cookie domains in profile
```

#### Cloud Profiles (`--browser remote`)

Remote profiles are not available at the moment.

#### Syncing
```bash
./scripts/browser-use.sh profile sync --from "Default" --domain github.com  # Domain-specific
./scripts/browser-use.sh profile sync --from "Default"                      # Full profile
./scripts/browser-use.sh profile sync --from "Default" --name "Custom Name" # With custom name
```

### Server Control
```bash
./scripts/browser-use.sh server logs                   # View server logs
```

## Common Workflows

### Authenticated Browsing with Profiles

Use when a task requires browsing a site the user is already logged into (e.g. Gmail, GitHub, internal tools).

**Core workflow:** Check existing profiles → ask user which profile and browser mode → browse with that profile. Only sync cookies if no suitable profile exists.

**Before browsing an authenticated site, the agent MUST:**
1. Ask the user whether to use **real** (local Chrome) or **remote** (cloud, not available) browser
2. List available profiles for that mode
3. Ask which profile to use
4. If no profile has the right cookies, offer to sync (see below)

#### Step 1: Check existing profiles

```bash
# Local Chrome profiles (--browser real)
./scripts/browser-use.sh -b real profile list
# → Default: Person 1 (user@gmail.com)
# → Profile 1: Work (work@company.com)

#### Step 2: Browse with the chosen profile

```bash
# Real browser — uses local Chrome with existing login sessions
./scripts/browser-use.sh --browser real --profile "Default" open https://github.com


The user is already authenticated — no login needed.


#### Managing & Stopping

```bash
./scripts/browser-use.sh task list --status finished      # See completed tasks
./scripts/browser-use.sh task stop task-abc               # Stop a task (session may continue if --keep-alive)
./scripts/browser-use.sh session stop sess-123            # Stop an entire session (terminates its tasks)
./scripts/browser-use.sh session stop --all               # Stop all sessions
```

#### Monitoring

**Task status is designed for token efficiency.** Default output is minimal — only expand when needed:

| Mode    | Flag   | Tokens | Use When            |
|---------|--------|--------|---------------------|
| Default | (none) | Low    | Polling progress    |
| Compact | `-c`   | Medium | Need full reasoning |
| Verbose | `-v`   | High   | Debugging actions   |

```bash
# For long tasks (50+ steps)
./scripts/browser-use.sh task status <id> -c --last 5   # Last 5 steps only
./scripts/browser-use.sh task status <id> -v --step 10  # Inspect specific step
```

**Live view**: `./scripts/browser-use.sh session get <session-id>` returns a live URL to watch the agent.

**Detect stuck tasks**: If cost/duration in `task status` stops increasing, the task is stuck — stop it and start a new agent.

**Logs**: `./scripts/browser-use.sh task logs <task-id>` — only available after task completes.

## Global Options

| Option                          | Description                                                                                                                                 |
|---------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `--session NAME`                | Use named session (default: "default")                                                                                                      |
| `--browser MODE`                | Browser mode: chromium, real, remote                                                                                                        |
| `--headed`                      | Show browser window (chromium mode)                                                                                                         |
| `--profile NAME`                | Browser profile (local name or cloud ID). Works with `open`, `session create`, etc. — does NOT work with `run` (use `--session-id` instead) |
| `--json`                        | Output as JSON                                                                                                                              |
| `--mcp`                         | Run as MCP server via stdin/stdout                                                                                                          |
| `--timeout DURATION`            | Global execution timeout (default: `5m`). Format follows GNU coreutils (e.g. `30s`, `5m`, `1h`).                                            |
| `--silent`                      | Discard all output, only propagate exit code. Use instead of `2>/dev/null`.                                                                  |
| `--head N`                      | Show only the first N lines of output.                                                                                                       |
| `--tail N`                      | Show only the last N lines of output.                                                                                                        |
| `--match PATTERN`               | Filter output to lines matching ERE regex pattern. Use instead of piping to `grep`.                                                          |
| `--replace PATTERN REPLACEMENT` | Search and replace in output using ERE regex (sed syntax). Use instead of piping to `sed`.                                                   |

**Session behavior**: All commands without `--session` use the same "default" session. The browser stays open and is reused across commands. Use `--session NAME` to run multiple browsers in parallel.

## Tips

1. **Always run `./scripts/browser-use.sh state` first** to see available elements and their indices
2. **Use `--headed` for debugging** to see what the browser is doing
3. **Sessions persist** — the browser stays open between commands
4. **Use `--json`** for programmatic parsing
5. **Python variables persist** across `./scripts/browser-use.sh python` commands within a session
6. **CLI aliases**: `bu`, `browser`, and `browseruse` all work identically to `./scripts/browser-use.sh

## Troubleshooting

**Run diagnostics first:**
```bash
./scripts/browser-use.sh doctor
```

**Browser won't start?**
```bash
./scripts/browser-use.sh close --all               # Close all sessions
./scripts/browser-use.sh --headed open <url>       # Try with visible window
```

**Element not found?**
```bash
./scripts/browser-use.sh state                     # Check current elements
./scripts/browser-use.sh scroll down               # Element might be below fold
./scripts/browser-use.sh state                     # Check again
```

**Session issues?**
```bash
./scripts/browser-use.sh sessions                  # Check active sessions
./scripts/browser-use.sh close --all               # Clean slate
./scripts/browser-use.sh open <url>                # Fresh start
```

**Session reuse fails after `task stop`**:
If you stop a task and try to reuse its session, the new task may get stuck at "created" status. Create a new session instead:
```bash
./scripts/browser-use.sh session create --profile <profile-id> --keep-alive
./scripts/browser-use.sh -b remote run "new task" --session-id <new-session-id>
```

**Task stuck at "started"**: Check cost with `task status` — if not increasing, the task is stuck. View live URL with `session get`, then stop and start a new agent.

**Sessions persist after tasks complete**: Tasks finishing doesn't auto-stop sessions. Run `./scripts/browser-use.sh session stop --all` to clean up.

## Cleanup

**Always close the browser when done:**

```bash
./scripts/browser-use.sh --silent close                     # Close browser session
./scripts/browser-use.sh --silent close --all               # Close all sessions
./scripts/browser-use.sh --silent session stop --all        # Stop cloud sessions (if any)
./scripts/browser-use.sh --silent tunnel stop --all         # Stop tunnels (if any)
```

# Additional resources

## File download

See [file download](./references/file_download.md) for more details.

## File upload

See [file upload](./references/file_upload.md) for more details.

## Architecture

See [architecture](./references/ARCHITECTURE.md) for details on the browser-use architecture (C4 model).

## Integration guide

See [integration guide](./references/integration_guide.md) for comparing integration approaches (Skill CLI, Python Library, etc.).
