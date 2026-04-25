---
name: slack-ui
description: "Interact with Slack workspaces via browser automation: check unread channels, navigate the sidebar, send messages, search conversations, extract data from messages and threads. Triggers: 'check my Slack', 'what channels have unreads', 'send a message to', 'search Slack for', 'find who said'. Connects to an existing Slack browser tab or Slack desktop (via electron-ui) on port 9222."
argument-hint: "<slack task>"
allowed-tools: Read(references/*) Read(templates/*) Bash(./scripts/slack-ui.sh *) Bash(zsh *) Skill(web-browser) Skill(electron-ui) Read
dependencies: "agent-browser, gtimeout"
---

# Slack Automation

Interact with Slack workspaces to check messages, extract data, and automate
common tasks. For Slack desktop, launch the app with
`--remote-debugging-port=9222` first (see `Skill(electron-ui)`); for the web
client just open `https://app.slack.com` in a browser.

## Usage

Run the script:

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh $ARGUMENTS
```

> **Important:** Run the script directly. Do **not** prefix with `bash` — the
> script requires zsh.

> **Security:** Never use compound commands, shell redirects, or pipes with
> this script. Use the built-in `--silent`, `--head`, `--tail`, `--match`,
> `--replace` flags instead.

## Output Control Flags

```bash
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh --silent close
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh --head 30 snapshot -i
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh --match "treeitem|button" snapshot -i
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh --replace "\\s+$" "" snapshot -i
```

Filters apply in order: match → replace → head → tail.

## Quick Start

Connect to an existing Slack browser session or open Slack:

```bash
# Connect to existing session on port 9222 (typical for already-open Slack desktop)
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh connect 9222

# Or open Slack web if not already running
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh open https://app.slack.com
```

Then take a snapshot to see what's available:

```bash
${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh snapshot -i
```

> The remaining examples use the bare `agent-browser <subcommand>` form for
> readability. Substitute `${CLAUDE_SKILL_DIR}/scripts/slack-ui.sh
> <subcommand>` when running them.

## Core Workflow

1. **Connect/Navigate**: Open or connect to Slack
2. **Snapshot**: Get interactive elements with refs (`@e1`, `@e2`, …)
3. **Navigate**: Click tabs, expand sections, navigate to channels
4. **Extract/Interact**: Read data or perform actions
5. **Screenshot**: Capture evidence of findings

```bash
agent-browser connect 9222
agent-browser snapshot -i
# Look for "More unreads" button
agent-browser click @e21        # Ref for "More unreads"
agent-browser screenshot slack-unreads.png
```

## Common Tasks

### Checking Unread Messages

```bash
agent-browser connect 9222
agent-browser snapshot -i

# Look for:
# - "More unreads" button (usually near top of sidebar)
# - "Unreads" toggle in Activity tab (shows unread count)
# - Channel names with badges/bold text indicating unreads

# Activity tab: all unreads in one view
agent-browser click @e14
agent-browser wait 1000
agent-browser screenshot activity-unreads.png

# DMs tab
agent-browser click @e13
agent-browser screenshot dms.png

# Expand "More unreads" in sidebar
agent-browser click @e21
agent-browser wait 500
agent-browser screenshot expanded-unreads.png
```

### Navigating to a Channel

```bash
agent-browser snapshot -i
# Find the channel in the sidebar list (e.g., "engineering")
agent-browser click @e94
agent-browser wait --load networkidle
agent-browser screenshot channel.png
```

### Finding Messages / Threads

```bash
agent-browser snapshot -i
agent-browser click @e5             # Search button
agent-browser fill @e_search "keyword"
agent-browser press Enter
agent-browser wait --load networkidle
agent-browser screenshot search-results.png
```

### Extracting Channel Information

```bash
# JSON snapshot for programmatic parsing
agent-browser snapshot --json > slack-snapshot.json
# Look for treeitem elements with level=2 (sub-channels under sections)
```

### Checking Channel Details

```bash
agent-browser click @e_channel_ref
agent-browser wait 1000
agent-browser snapshot -i
agent-browser screenshot channel-details.png

agent-browser scroll down 500
agent-browser screenshot channel-messages.png
```

### Capturing State

```bash
agent-browser screenshot --annotate slack-state.png  # numbered labels
agent-browser screenshot --full slack-full.png
agent-browser get url
agent-browser get title
```

See [references/slack-tasks.md](references/slack-tasks.md) for more
task-specific recipes.

## Sidebar Structure

```
- Threads
- Huddles
- Drafts & sent
- Directories
- [Section Headers — External connections, Starred, Channels, …]
  - [Channels listed as treeitems]
- Direct Messages
  - [DMs listed]
- Apps
  - [App shortcuts]
- [More unreads] button (toggles unread channels list)
```

Typical refs (vary per session — always re-snapshot):
- `@e12` — Home tab
- `@e13` — DMs tab
- `@e14` — Activity tab
- `@e5`  — Search button
- `@e21` — More unreads button

## Tabs in Slack

After clicking on a channel:
- **Messages** — Channel conversation
- **Files** — Shared files
- **Pins** — Pinned messages
- **Add canvas** — Collaborative canvas

## Extracting Data

### Get Text Content

```bash
agent-browser get text @e_message_ref
```

### Parse the Accessibility Tree

```bash
agent-browser snapshot --json > output.json

# Look for:
# - Channel names (name field in treeitem)
# - Message content (in listitem/document elements)
# - User names (button elements with user info)
# - Timestamps (link elements with time info)
```

### Count Unreads (rough)

```bash
agent-browser snapshot -i --match "treeitem" --tail 100
# Each treeitem with a channel name in the unreads section is one unread
```

## Best Practices

- **Connect to existing sessions** — `connect 9222` is faster than opening a new browser.
- **Take snapshots before clicking** — always `snapshot -i` to identify refs.
- **Re-snapshot after navigation** — refs change on every page change.
- **Use JSON snapshots for parsing** — `snapshot --json` is machine-readable.
- **Pace interactions** — add `sleep 1` between rapid clicks/types.
- **Scroll the sidebar** — `agent-browser scroll down 300 --selector ".p-sidebar"` if the channel list is long.

## Limitations

- **No Slack API**: this is browser automation. No OAuth, webhooks, or bot
  tokens needed — but no rate-limit-friendly API access either.
- **Session-specific**: snapshots tie to the current browser session.
- **Rate limiting**: Slack may throttle rapid interactions; add delays.
- **Workspace-specific**: only your own workspace, no cross-workspace.

## Debugging

```bash
agent-browser console
agent-browser errors
agent-browser get url
agent-browser get title
agent-browser screenshot page-state.png
```

## Templates

| Template                                                                             | Purpose                                                  |
|--------------------------------------------------------------------------------------|----------------------------------------------------------|
| [templates/slack-report-template.md](templates/slack-report-template.md)             | Starter report for capturing findings from a Slack scan |

## References

- **Task recipes**: [references/slack-tasks.md](references/slack-tasks.md)
- **Slack docs**: <https://slack.com/help>
- **Web client**: <https://app.slack.com>
- **Keyboard shortcuts**: type `?` in Slack
