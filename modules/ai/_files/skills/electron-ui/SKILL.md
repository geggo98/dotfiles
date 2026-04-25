---
name: electron-ui
description: "Automate Electron desktop apps (VS Code, Slack, Discord, Microsoft Teams, Figma, Notion, Spotify, Obsidian, Linear, 1Password, …) by connecting to their Chrome DevTools Protocol port. Use when the user wants to control or test a native desktop app, or when the workflow needs CDP connect / --remote-debugging-port. Same snapshot + @eN ref workflow as web pages."
argument-hint: "<app name or CDP port>"
allowed-tools: Bash(./scripts/electron-ui.sh *) Bash(zsh *) Skill(web-browser) Read
dependencies: "agent-browser, gtimeout"
---

# Electron App Automation

Automate any Electron desktop app using agent-browser. Electron apps are built
on Chromium and expose a Chrome DevTools Protocol (CDP) port — agent-browser
connects to that port and uses the same snapshot-interact workflow as web
pages.

## Usage

Run the script:

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh $ARGUMENTS
```

> **Important:** Run the script directly. Do **not** prefix with `bash` — the
> script requires zsh.

> **Security:** Never use compound commands, shell redirects, or pipes with
> this script. Use the built-in `--silent`, `--head`, `--tail`, `--match`,
> `--replace` flags instead.

## Output Control Flags

```bash
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh --silent close
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh --head 20 snapshot -i
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh --tail 10 snapshot -i
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh --match "button|menuitem" snapshot -i
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh --replace "\\s+$" "" snapshot -i
```

Filters apply in order: match → replace → head → tail.

## Core Workflow

1. **Launch** the Electron app with remote debugging enabled
2. **Connect** agent-browser to the CDP port
3. **Snapshot** to discover interactive elements
4. **Interact** using element refs
5. **Re-snapshot** after navigation or state changes

```bash
# Launch an Electron app with remote debugging
open -a "Slack" --args --remote-debugging-port=9222

# Connect agent-browser to the app
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh connect 9222

# Standard workflow from here
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh snapshot -i
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh click @e5
${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh screenshot slack-desktop.png
```

> The remaining examples use the bare `agent-browser <subcommand>` form for
> readability. Substitute `${CLAUDE_SKILL_DIR}/scripts/electron-ui.sh
> <subcommand>` when running them.

## Launching Electron Apps with CDP

Every Electron app supports the `--remote-debugging-port` flag since it's
built into Chromium.

### macOS

```bash
open -a "Slack" --args --remote-debugging-port=9222
open -a "Visual Studio Code" --args --remote-debugging-port=9223
open -a "Discord" --args --remote-debugging-port=9224
open -a "Figma" --args --remote-debugging-port=9225
open -a "Notion" --args --remote-debugging-port=9226
open -a "Spotify" --args --remote-debugging-port=9227
```

### Linux

```bash
slack --remote-debugging-port=9222
code --remote-debugging-port=9223
discord --remote-debugging-port=9224
```

### Windows

```bash
"C:\Users\%USERNAME%\AppData\Local\slack\slack.exe" --remote-debugging-port=9222
"C:\Users\%USERNAME%\AppData\Local\Programs\Microsoft VS Code\Code.exe" --remote-debugging-port=9223
```

**Important:** If the app is already running, quit it first, then relaunch
with the flag. The `--remote-debugging-port` flag must be present at launch
time.

## Connecting

```bash
agent-browser connect 9222            # connect to a specific port
agent-browser --cdp 9222 snapshot -i  # or pass --cdp on each command
agent-browser --auto-connect snapshot -i  # auto-discover a running Chromium-based app
```

After `connect`, all subsequent commands target the connected app without
needing `--cdp`.

## Tab Management

Electron apps often have multiple windows or webviews. Use tab commands to
list and switch between them:

```bash
agent-browser tab                    # list all targets (windows, webviews, …)
agent-browser tab 2                  # switch to a tab by index
agent-browser tab --url "*settings*" # switch by URL pattern
```

## Webview Support

Electron `<webview>` elements are auto-discovered and can be controlled like
regular pages. Webviews appear as separate targets in the tab list with
`type: "webview"`:

```bash
agent-browser connect 9222
agent-browser tab
# 0: [page]    Slack - Main Window     https://app.slack.com/
# 1: [webview] Embedded Content        https://example.com/widget

agent-browser tab 1
agent-browser snapshot -i
agent-browser click @e3
agent-browser screenshot webview.png
```

Webview support works via raw CDP connection.

## Common Patterns

### Inspect and navigate

```bash
open -a "Slack" --args --remote-debugging-port=9222
sleep 3
agent-browser connect 9222
agent-browser snapshot -i
agent-browser click @e10           # navigate to a section
agent-browser snapshot -i          # re-snapshot after navigation
```

### Take screenshots

```bash
agent-browser connect 9222
agent-browser screenshot app-state.png
agent-browser screenshot --full full-app.png
agent-browser screenshot --annotate annotated-app.png
```

### Extract data

```bash
agent-browser connect 9222
agent-browser snapshot -i
agent-browser get text @e5
agent-browser snapshot --json > app-state.json
```

### Fill forms

```bash
agent-browser connect 9222
agent-browser snapshot -i
agent-browser fill @e3 "search query"
agent-browser press Enter
agent-browser wait 1000
agent-browser snapshot -i
```

### Run multiple apps simultaneously

Use named sessions to control multiple Electron apps in parallel:

```bash
agent-browser --session slack  connect 9222
agent-browser --session vscode connect 9223
agent-browser --session slack  snapshot -i
agent-browser --session vscode snapshot -i
```

## Color Scheme

The default color scheme when connecting via CDP may be `light`. To preserve
dark mode:

```bash
agent-browser connect 9222
agent-browser --color-scheme dark snapshot -i
```

Or set it globally:

```bash
AGENT_BROWSER_COLOR_SCHEME=dark agent-browser connect 9222
```

## Troubleshooting

**"Connection refused" or "Cannot connect"**
- Make sure the app was launched with `--remote-debugging-port=NNNN`
- If the app was already running, quit and relaunch with the flag
- Check that the port isn't in use: `lsof -i :9222`

**App launches but connect fails**
- Wait a few seconds after launch before connecting (`sleep 3`)
- Some apps take time to initialize their webview

**Elements not appearing in snapshot**
- The app may use multiple webviews. Use `agent-browser tab` to list targets
  and switch to the right one

**Cannot type in input fields**
- Try `agent-browser keyboard type "text"` to type at the current focus
  without a selector
- Some Electron apps use custom input components — try `agent-browser
  keyboard inserttext "text"` to bypass key events

## Supported Apps

Any app built on Electron works, including:

- **Communication:** Slack, Discord, Microsoft Teams, Signal, Telegram Desktop
- **Development:** VS Code, GitHub Desktop, Postman, Insomnia
- **Design:** Figma, Notion, Obsidian
- **Media:** Spotify, Tidal
- **Productivity:** Todoist, Linear, 1Password

If an app is built with Electron, it supports `--remote-debugging-port` and
can be automated with this skill. For Slack-specific helpers see
`Skill(slack-ui)`. For general web automation see `Skill(web-browser)`.
