# Multiple Browser Sessions

## Why use multiple sessions

When you need more than one browser at a time:
- Cloud browser for scraping + local Chrome for authenticated tasks
- Two different Chrome profiles simultaneously
- Isolated browser for testing that won't affect the user's browsing
- Running a headed browser for debugging while headless runs in background

## How sessions are isolated

Each `--session NAME` gets:
- Its own daemon process
- Its own Unix socket (`~/.browser-use/{name}.sock`)
- Its own PID file and state file
- Its own browser instance (completely independent)
- Its own tab ownership state (multi-agent locks don't cross sessions)

## The `--session` flag

Must be passed on every command targeting that session:

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session work open <url>      # goes to 'work' daemon
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session work state           # reads from 'work' daemon
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh state                          # goes to 'default' daemon (different browser)
```

If you forget `--session`, the command goes to the `default` session. This is the most common mistake — you'll interact with the wrong browser.

## Combining sessions with browser modes

```bash
# Session 1: cloud browser
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session cloud cloud connect

# Session 2: connect to user's Chrome
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session chrome connect

# Session 3: headed Chromium for debugging
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session debug --headed open <url>
```

Each session is fully independent. The cloud session talks to a remote browser, the chrome session talks to the user's Chrome, and the debug session manages its own Chromium — all running simultaneously.

## Listing and managing sessions

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh sessions
```

Output:
```
SESSION          PHASE          PID      CONFIG
cloud            running        12345    cloud
chrome           running        12346    cdp
debug            ready          12347    headed
```

PHASE shows the daemon lifecycle state: `initializing`, `ready`, `starting`, `running`, `shutting_down`, `stopped`, `failed`.

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session cloud close           # close one session
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh close --all                     # close every session
```

## Common patterns

**Cloud + local authenticated:**
```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session scraper cloud connect
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session scraper open https://example.com
# ... scrape data ...

${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session auth --profile "Default" open https://github.com
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session auth state
# ... interact with authenticated site ...
```

**Throwaway test browser:**
```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session test --headed open https://localhost:3000
# ... test, debug, inspect ...
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh --session test close    # done, clean up
```

**Environment variable:**
```bash
export BROWSER_USE_SESSION=work
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh open <url>              # uses 'work' session without --session flag
```
