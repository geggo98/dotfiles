---
name: browser-use
description: Automates browser interactions for web testing, form filling, screenshots, and data extraction. Use when the user needs to navigate websites, interact with web pages, fill forms, take screenshots, or extract information from web pages.
allowed-tools:
  - "Bash(./scripts/browser-use.sh:*)"
  - "Bash(bash ./scripts/browser-use.sh:*)"

---

# Browser Automation with browser-use CLI

The `./scripts/browser-use.sh` command provides fast, persistent browser automation. It maintains browser sessions across commands, enabling complex multi-step workflows.

For more information, see https://github.com/browser-use/browser-use/blob/main/browser_use/skill_cli/README.md

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

### Cloud Session Management
```bash
./scripts/browser-use.sh session list                  # List cloud sessions
./scripts/browser-use.sh session list --limit 20       # Show more sessions
./scripts/browser-use.sh session list --status active  # Filter by status
./scripts/browser-use.sh session list --json           # JSON output

./scripts/browser-use.sh session get <session-id>      # Get session details + live URL
./scripts/browser-use.sh session get <session-id> --json

./scripts/browser-use.sh session stop <session-id>     # Stop a session
./scripts/browser-use.sh session stop --all            # Stop all active sessions

./scripts/browser-use.sh session create                          # Create with defaults
./scripts/browser-use.sh session create --profile <id>           # With cloud profile
./scripts/browser-use.sh session create --proxy-country uk       # With geographic proxy
./scripts/browser-use.sh session create --start-url https://example.com
./scripts/browser-use.sh session create --screen-size 1920x1080
./scripts/browser-use.sh session create --keep-alive
./scripts/browser-use.sh session create --persist-memory

./scripts/browser-use.sh session share <session-id>              # Create public share URL
./scripts/browser-use.sh session share <session-id> --delete     # Delete public share
```

### Tunnels
```bash
./scripts/browser-use.sh tunnel <port>           # Start tunnel (returns URL)
./scripts/browser-use.sh tunnel <port>           # Idempotent - returns existing URL
./scripts/browser-use.sh tunnel list             # Show active tunnels
./scripts/browser-use.sh tunnel stop <port>      # Stop tunnel
./scripts/browser-use.sh tunnel stop --all       # Stop all tunnels
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
```bash
./scripts/browser-use.sh -b remote profile list            # List cloud profiles
./scripts/browser-use.sh -b remote profile list --page 2 --page-size 50
./scripts/browser-use.sh -b remote profile get <id>        # Get profile details
./scripts/browser-use.sh -b remote profile create          # Create new cloud profile
./scripts/browser-use.sh -b remote profile create --name "My Profile"
./scripts/browser-use.sh -b remote profile update <id> --name "New"
./scripts/browser-use.sh -b remote profile delete <id>
```

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
1. Ask the user whether to use **real** (local Chrome) or **remote** (cloud) browser
2. List available profiles for that mode
3. Ask which profile to use
4. If no profile has the right cookies, offer to sync (see below)

#### Step 1: Check existing profiles

```bash
# Option A: Local Chrome profiles (--browser real)
./scripts/browser-use.sh -b real profile list
# → Default: Person 1 (user@gmail.com)
# → Profile 1: Work (work@company.com)

# Option B: Cloud profiles (--browser remote)
./scripts/browser-use.sh -b remote profile list
# → abc-123: "Chrome - Default (github.com)"
# → def-456: "Work profile"
```

#### Step 2: Browse with the chosen profile

```bash
# Real browser — uses local Chrome with existing login sessions
./scripts/browser-use.sh --browser real --profile "Default" open https://github.com

# Cloud browser — uses cloud profile with synced cookies
./scripts/browser-use.sh --browser remote --profile abc-123 open https://github.com
```

The user is already authenticated — no login needed.

**Note:** Cloud profile cookies can expire over time. If authentication fails, re-sync cookies from the local Chrome profile.

#### Step 3: Syncing cookies (only if needed)

If the user wants to use a cloud browser but no cloud profile has the right cookies, sync them from a local Chrome profile.

**Before syncing, the agent MUST:**
1. Ask which local Chrome profile to use
2. Ask which domain(s) to sync — do NOT default to syncing the full profile
3. Confirm before proceeding

**Check what cookies a local profile has:**
```bash
./scripts/browser-use.sh -b real profile cookies "Default"
# → youtube.com: 23
# → google.com: 18
# → github.com: 2
```

**Domain-specific sync (recommended):**
```bash
./scripts/browser-use.sh profile sync --from "Default" --domain github.com
# Creates new cloud profile: "Chrome - Default (github.com)"
# Only syncs github.com cookies
```

**Full profile sync (use with caution):**
```bash
./scripts/browser-use.sh profile sync --from "Default"
# Syncs ALL cookies — includes sensitive data, tracking cookies, every session token
```
Only use when the user explicitly needs their entire browser state.

**Fine-grained control (advanced):**
```bash
# Export cookies to file, manually edit, then import
./scripts/browser-use.sh --browser real --profile "Default" cookies export /tmp/cookies.json
./scripts/browser-use.sh --browser remote --profile <id> cookies import /tmp/cookies.json
```

**Use the synced profile:**
```bash
./scripts/browser-use.sh --browser remote --profile <id> open https://github.com
```

### Running Subagents

Use cloud sessions to run autonomous browser agents in parallel.

**Core workflow:** Launch task(s) with `run` → poll with `task status` → collect results → clean up sessions.

- **Session = Agent**: Each cloud session is a browser agent with its own state
- **Task = Work**: Jobs given to an agent; an agent can run multiple tasks sequentially
- **Session lifecycle**: Once stopped, a session cannot be revived — start a new one

#### Launching Tasks

```bash
# Single task (async by default — returns immediately)
./scripts/browser-use.sh -b remote run "Search for AI news and summarize top 3 articles"
# → task_id: task-abc, session_id: sess-123

# Parallel tasks — each gets its own session
./scripts/browser-use.sh -b remote run "Research competitor A pricing"
# → task_id: task-1, session_id: sess-a
./scripts/browser-use.sh -b remote run "Research competitor B pricing"
# → task_id: task-2, session_id: sess-b
./scripts/browser-use.sh -b remote run "Research competitor C pricing"
# → task_id: task-3, session_id: sess-c

# Sequential tasks in same session (reuses cookies, login state, etc.)
./scripts/browser-use.sh -b remote run "Log into example.com" --keep-alive
# → task_id: task-1, session_id: sess-123
./scripts/browser-use.sh task status task-1  # Wait for completion
./scripts/browser-use.sh -b remote run "Export settings" --session-id sess-123
# → task_id: task-2, session_id: sess-123 (same session)
```

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

| Option           | Description                                                                                                                                 |
|------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `--session NAME` | Use named session (default: "default")                                                                                                      |
| `--browser MODE` | Browser mode: chromium, real, remote                                                                                                        |
| `--headed`       | Show browser window (chromium mode)                                                                                                         |
| `--profile NAME` | Browser profile (local name or cloud ID). Works with `open`, `session create`, etc. — does NOT work with `run` (use `--session-id` instead) |
| `--json`         | Output as JSON                                                                                                                              |
| `--mcp`          | Run as MCP server via stdin/stdout                                                                                                          |

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
./scripts/browser-use.sh close                     # Close browser session
./scripts/browser-use.sh session stop --all        # Stop cloud sessions (if any)
./scripts/browser-use.sh tunnel stop --all         # Stop tunnels (if any)
```