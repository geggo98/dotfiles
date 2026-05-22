---
name: browser-use
description: "Automates browser interactions for web testing, form filling, screenshots, and data extraction. Use when the user needs to navigate websites, interact with web pages, fill forms, take screenshots, or extract information from web pages."
argument-hint: "<task description or URL>"
allowed-tools: Read(references/*) Bash(./scripts/browser-use.sh *) Bash(zsh *) Read
dependencies: "uv, gtimeout"
---

# Browser Automation with browser-use CLI

The `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh` command provides fast, persistent browser automation. A background daemon keeps the browser open across commands, giving ~50ms latency per call.

For upstream documentation, see https://github.com/browser-use/browser-use/blob/main/browser_use/skill_cli/README.md

> **Important:** Run the script directly (`${CLAUDE_SKILL_DIR}/scripts/browser-use.sh`). Do **not** prefix with `bash` — the script requires zsh and will fail under bash.

> **Security:** Never use compound commands (`cd ... &&`), shell redirects (`2>/dev/null`), or pipes with this script. These trigger manual approval prompts. Instead, use the built-in output control flags below.

## Prerequisites

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh doctor    # Verify installation
```

## Output Control Flags

These flags are handled by the wrapper script and work with any command. They eliminate the need for shell redirects or pipes, avoiding security prompts.

```bash
# Silent mode — discard all output, only propagate exit code
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --silent close
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --silent close --all

# Head/tail — limit output to first/last N lines
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --head 20 state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --tail 10 state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --head 5 --tail 5 get html

# Regex match — filter output lines matching an ERE pattern
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --match "button|link" state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --match "^\[[0-9]" state

# Regex replace — search and replace using sed ERE syntax (| delimiter)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --replace "\s+$" "" state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --replace "(https?://)[^ ]+" "\\1..." get html
```

**Combining flags:** Filters apply in order: match → replace → head → tail.

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --match "button" --head 10 state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --replace "<[^>]+>" "" --tail 5 get html --selector "main"
```

## Core Workflow

1. **Navigate**: `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open <url>` — launches headless browser and opens page
2. **Inspect**: `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state` — returns clickable elements with indices
3. **Interact**: use indices from state (`${CLAUDE_SKILL_DIR}/scripts/browser-use.sh click 5`, `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh input 3 "text"`)
4. **Verify**: `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state` or `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh screenshot` to confirm
5. **Repeat**: browser stays open between commands

If a command fails, run `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close` first to clear any broken session, then retry.

To use the user's existing Chrome (preserves logins/cookies): run `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh connect` first.
To use a cloud browser instead: run `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud connect` first.
After either, commands work the same way.

### If `connect` fails

When `connect` cannot find a running Chrome with remote debugging, prompt the user with two options:

1. **Use their real Chrome browser** — they need to enable remote debugging first:
   - Open `chrome://inspect/#remote-debugging` in Chrome, or relaunch Chrome with `--remote-debugging-port=9222`
   - Then retry `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh connect`
2. **Use managed Chromium with their Chrome profile** — no Chrome setup needed:
   - Run `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh profile list` to show available profiles
   - Ask which profile they want, then use `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --profile "ProfileName" open <url>`
   - This launches a separate Chromium instance with their profile data (cookies, logins, extensions)

Let the user choose — don't assume one path over the other.

## Browser Modes

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open <url>                      # Default: headless Chromium
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --headed open <url>             # Visible window (for debugging)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh connect                         # Connect to user's Chrome (preserves logins)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud connect                   # Cloud browser (zero-config, requires API key)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --profile "Default" open <url>  # Real Chrome with specific profile
```

After `connect` or `cloud connect`, all subsequent commands go to that browser — no extra flags needed.

## Commands

```bash
# Navigation
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open <url>                    # Navigate to URL
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh back                          # Go back in history
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh scroll down                   # Scroll down (--amount N for pixels)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh scroll up                     # Scroll up
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tab list                      # List all tabs
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tab new [url]                 # Open a new tab
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tab switch <index>            # Switch to tab by index
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tab close <index> [index...]  # Close one or more tabs

# Page State — always run state first to get element indices
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state                         # URL, title, clickable elements
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh screenshot [path.png]         # base64 if no path, --full for full page

# Interactions — use indices from state
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh click <index>                 # Click element by index
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh click <x> <y>                 # Click at pixel coordinates
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh type "text"                   # Type into focused element
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh input <index> "text"          # Click element, clear, then type
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh input <index> ""              # Clear a field without typing
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh keys "Enter"                  # Send keys (also "Control+a", etc.)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh select <index> "option"       # Select dropdown option
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh upload <index> <path>         # Upload file to file input
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh hover <index>                 # Hover over element
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh dblclick <index>              # Double-click element
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh rightclick <index>            # Right-click element

# Data Extraction
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh eval "js code"                # Execute JavaScript, return result
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get title                     # Page title
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get html [--selector "h1"]    # Page HTML (or scoped to selector)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get text <index>              # Element text content
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get value <index>             # Input/textarea value
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get attributes <index>        # Element attributes
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh get bbox <index>              # Bounding box (x, y, w, h)

# Wait
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh wait selector "css"           # Wait for element (--state, --timeout ms)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh wait text "text"              # Wait for text to appear

# Cookies
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cookies get [--url <url>]     # Get cookies (optionally filtered)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cookies set <name> <value>    # Set cookie (--domain, --secure, …)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cookies clear [--url <url>]   # Clear cookies
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cookies export <file>         # Export to JSON
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cookies import <file>         # Import from JSON

# Session
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close                         # Close browser and stop daemon
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh sessions                      # List active sessions
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close --all                   # Close all sessions
```

For advanced browser control (CDP, device emulation, tab activation), see [`references/cdp-python.md`](./references/cdp-python.md).

## Cloud API

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud connect                 # Provision cloud browser and connect
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud login <api-key>         # Save API key (or BROWSER_USE_API_KEY)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud logout                  # Remove API key
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud v2 GET /browsers        # REST passthrough (v2 or v3)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud v2 POST /tasks '{"task":"...","url":"..."}'
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud v2 poll <task-id>       # Poll task until done
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud v2 --help               # Show API endpoints
```

`cloud connect` provisions a cloud browser with a persistent profile, connects via CDP, and prints a live URL. `close` disconnects AND stops the cloud browser. For custom browser settings (proxy, timeout, specific profile), use `cloud v2 POST /browsers` directly.

### Agent Self-Registration

Only use this if you don't already have an API key (check `doctor` to see if api_key is set). If already logged in, skip this entirely.

1. `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud signup` — get a challenge
2. Solve the challenge
3. `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud signup --verify <challenge-id> <answer>` — verify and save API key
4. `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh cloud signup --claim` — generate URL for a human to claim the account

## Tunnels

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tunnel <port>                 # Start Cloudflare tunnel (idempotent)
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tunnel list                   # Show active tunnels
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tunnel stop <port>            # Stop tunnel
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tunnel stop --all             # Stop all tunnels
```

## Profile Management

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh profile list                  # List detected browsers and profiles
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh profile sync --all            # Sync profiles to cloud
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh profile update                # Download/update profile-use binary
```

## Common Workflows

### Authenticated Browsing

When a task requires an authenticated site (Gmail, GitHub, internal tools), use Chrome profiles:

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh profile list                           # Check available profiles
# Ask the user which profile to use, then:
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --profile "Default" open https://github.com
```

### Exposing Local Dev Servers

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh tunnel 3000                            # → https://abc.trycloudflare.com
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open https://abc.trycloudflare.com
```

## Multiple Browsers

For subagent workflows or running multiple browsers in parallel, use `--session NAME`. Each session gets its own daemon and browser. See [`references/multi-session.md`](./references/multi-session.md).

## Configuration

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh config list                            # Show all config values
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh config set cloud_connect_proxy jp      # Set a value
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh config get cloud_connect_proxy         # Get a value
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh config unset cloud_connect_timeout     # Remove a value
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh doctor                                 # Config + diagnostics
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh setup                                  # Interactive post-install setup
```

Config stored in `~/.browser-use/config.json`.

## Global Options

| Option                          | Description                                                                                                  |
|---------------------------------|--------------------------------------------------------------------------------------------------------------|
| `--headed`                      | Show browser window                                                                                          |
| `--profile [NAME]`              | Use real Chrome (bare `--profile` uses "Default")                                                            |
| `--cdp-url <url>`               | Connect via CDP URL (`http://` or `ws://`)                                                                   |
| `--session NAME`                | Target a named session (default: "default"). See `references/multi-session.md`.                              |
| `--json`                        | Output as JSON                                                                                               |
| `--mcp`                         | Run as MCP server via stdin/stdout                                                                           |
| `--timeout DURATION`            | Wrapper-level timeout (default: `5m`). GNU coreutils format (`30s`, `5m`, `1h`).                             |
| `--silent`                      | Discard all output, only propagate exit code. Use instead of `2>/dev/null`.                                  |
| `--head N`                      | Show only the first N lines of output.                                                                       |
| `--tail N`                      | Show only the last N lines of output.                                                                        |
| `--match PATTERN`               | Filter output to lines matching ERE regex. Use instead of piping to `grep`.                                  |
| `--replace PATTERN REPLACEMENT` | Search-and-replace using ERE (sed syntax). Use instead of piping to `sed`.                                   |

## Tips

1. **Always run `state` first** to see available elements and their indices
2. **Use `--headed` for debugging** to see what the browser is doing
3. **Sessions persist** — browser stays open between commands
4. **Use `--json`** for programmatic parsing
5. **If commands fail**, run `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close` first, then retry
6. **CLI aliases**: `bu`, `browser`, `browseruse` all work identically to the wrapper

## Troubleshooting

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh doctor                  # Run diagnostics first
```

**Browser won't start?**
```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close --all
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --headed open <url>     # Try with visible window
```

**Element not found?**
```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state                   # Check current elements
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh scroll down             # Element might be below fold
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state                   # Check again
```

**Session issues?**
```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh sessions
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close --all
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open <url>
```

## Cleanup

**Always close the browser when done:**

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --silent close                     # Close browser session
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --silent close --all               # Close all sessions
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --silent tunnel stop --all         # Stop tunnels (if any)
```

# Additional resources

- [CDP & Python session reference](./references/cdp-python.md) — raw CDP via `browser-use python`
- [Multiple browser sessions](./references/multi-session.md) — `--session NAME` daemon model
- [Waiting for elements](./references/waiting_for_elements.md) — avoid `sleep`; how browser-use waits internally
- [File download](./references/file_download.md) — automatic download path, `downloaded_files` API
- [File upload](./references/file_upload.md) — uploading to `<input type="file">` via CDP
- [Architecture](./references/ARCHITECTURE.md) — C4 model of the browser-use stack
- [Integration guide](./references/integration_guide.md) — Skill CLI vs Python library, when to pick which
