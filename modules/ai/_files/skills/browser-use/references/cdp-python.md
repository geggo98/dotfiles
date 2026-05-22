# Raw CDP & Python Session Reference

The CLI commands handle most browser interactions. Use `${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python` with raw CDP when you need browser-level control the CLI doesn't expose — activating a tab so the user sees it, intercepting network requests, emulating devices, or working with Chrome target IDs directly.

## How the Python session works

`${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "statement"` executes one Python statement per call. Variables persist across calls — set a value in one call, use it in the next.

A `browser` object is pre-injected with sync wrappers for common operations (`browser.goto()`, `browser.click()`, etc.). For anything beyond those, two internals give you full access:

- `browser._run(coroutine)` — run any async coroutine synchronously (60s timeout)
- `browser._session` — the raw `BrowserSession` with full CDP client access

## Getting a CDP client

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cdp = browser._run(browser._session.get_or_create_cdp_session())"
```

After this, `cdp` persists across calls. Use `cdp.cdp_client.send.<Domain>.<method>()` for any CDP command and `cdp.session_id` for the session parameter.

## Recipes

### Activate a tab (make it visible to the user)

The CLI's `tab switch` only changes the agent's internal focus — Chrome's visible tab doesn't change. To actually show the user a specific tab:

```bash
# Get all targets to find the target ID
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "targets = browser._session.session_manager.get_all_page_targets()"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "print([(i, t.url) for i, t in enumerate(targets)])"

# Activate target at index 1 so the user sees it
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cdp = browser._run(browser._session.get_or_create_cdp_session(target_id=None, focus=False))"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "browser._run(cdp.cdp_client.send.Target.activateTarget(params={'targetId': targets[1].target_id}))"
```

### List all tabs with target IDs

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "targets = browser._session.session_manager.get_all_page_targets()"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "
for i, t in enumerate(targets):
    print(f'{i}: {t.target_id[:12]}... {t.url}')
"
```

### Run JavaScript and get the result

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cdp = browser._run(browser._session.get_or_create_cdp_session())"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "result = browser._run(cdp.cdp_client.send.Runtime.evaluate(params={'expression': 'document.title', 'returnByValue': True}, session_id=cdp.session_id))"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "print(result['result']['value'])"
```

### Emulate a mobile device

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cdp = browser._run(browser._session.get_or_create_cdp_session())"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "browser._run(cdp.cdp_client.send.Emulation.setDeviceMetricsOverride(params={'width': 375, 'height': 812, 'deviceScaleFactor': 3, 'mobile': True}, session_id=cdp.session_id))"
```

### Get cookies via CDP

```bash
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cdp = browser._run(browser._session.get_or_create_cdp_session())"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "cookies = browser._run(cdp.cdp_client.send.Network.getCookies(params={}, session_id=cdp.session_id))"
${CLAUDE_SKILL_DIR}/scripts/browser-use.sh python "print(cookies)"
```

## Tips

- Each `python` call is one statement. Multi-line strings work for `for` loops and `if` blocks, but you can't mix statements and expressions. Use multiple calls.
- Variables persist: set `cdp = ...` in one call, use `cdp` in the next.
- The `browser._run()` bridge has a 60-second timeout. For long operations, increase it or use the async internals directly.
- All CDP domains are available via `cdp.cdp_client.send.<Domain>.<method>()`. See the [Chrome DevTools Protocol docs](https://chromedevtools.github.io/devtools-protocol/) for the full API.
