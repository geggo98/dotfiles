# Waiting for Elements (Avoid sleep)

Browser-use has built-in waiting mechanisms — **never use `sleep()` or the `wait` action** to wait for elements to appear. The framework handles element readiness automatically.

## How browser-use waits internally

### 1. Polling for minimum elements (`_wait_for_minimum_elements`)

Before executing element-dependent actions, the agent polls `state.dom_state.selector_map` until enough interactive elements are present (1-second interval, 30-second timeout). This handles SPAs, shadow DOM, and dynamically loaded content.

### 2. CDP lifecycle events for navigation

Navigation waits for Chrome DevTools Protocol lifecycle events (`DOMContentLoaded`, `load`, `networkIdle`) instead of arbitrary delays. Cross-domain navigations get longer timeouts (8s) than same-domain (3s).

### 3. Network idle detection (DOM Watchdog)

The DOM watchdog checks `performance.getEntriesByType('resource')` for pending requests and `document.readyState`. It filters out ads, tracking pixels, and stuck requests (>10s) so the agent doesn't wait forever.

## Best practices for prompts

Instead of telling the agent to sleep or wait, use these patterns:

### Let the agent retry naturally

The agent's step loop already re-reads the DOM each step. If an element isn't found, the agent will see updated state on the next step and try again.

**Bad prompt:**
> "Click the submit button, wait 5 seconds, then extract the confirmation message"

**Good prompt:**
> "Click the submit button, then extract the confirmation message from the result page"

### Use `search_page` or `find_elements` to check for content

If you need to verify that content has appeared, instruct the agent to look for it rather than sleep:

**Bad prompt:**
> "Wait 3 seconds for the table to load, then extract the data"

**Good prompt:**
> "Extract the data from the results table once it appears"

### Rely on navigation detection

After clicks that trigger navigation, browser-use automatically waits for the new page to load (lifecycle events + network idle). No explicit wait is needed.

### For AJAX/dynamic content

The agent re-fetches the full DOM state each step. If a click triggers an AJAX update (e.g., accordion expand, modal open), the updated DOM is visible on the next step automatically.

## Configuration options

These `BrowserProfile` settings control wait behavior:

| Setting | Default | Description |
|---------|---------|-------------|
| `minimum_wait_page_load_time` | `0.25` | Minimum seconds before capturing page state after load |
| `wait_for_network_idle_page_load_time` | `0.5` | Seconds to wait for network idle after page load |
| `wait_between_actions` | `0.1` | Seconds between sequential actions in a multi-action step |

### Timeout overrides via environment variables

Every action type supports timeout override:

```bash
TIMEOUT_NavigateToUrlEvent=45.0
TIMEOUT_ClickElementEvent=20.0
TIMEOUT_BrowserStateRequestEvent=40.0
```

## When explicit waiting IS appropriate

The only legitimate case for explicit waiting is when dealing with time-gated UI (e.g., a countdown timer, rate-limited API responses). Even then, prefer instructing the agent to "check if X is ready" rather than sleeping a fixed duration.
