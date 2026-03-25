# Browser-Use Integration Guide: Choosing the Right Approach for Your Agent

This guide compares four ways an external AI agent can integrate with browser-use
for web automation, with particular attention to the trade-offs between the
Skill CLI (pre-approved, low token cost) and the Python Library approach
(maximum capability, higher token cost).

## Architecture Overview

Browser-use has three cleanly separable layers:

```
┌─────────────────────────────────────────┐
│  Agent Loop  (agent/service.py)         │  LLM decision loop, memory, planning,
│                                         │  loop detection, multi-action guards
├─────────────────────────────────────────┤
│  Tools Layer (tools/service.py)         │  Action registry, ActionResult model,
│                                         │  custom action decorator, extraction
├─────────────────────────────────────────┤
│  Browser Layer (browser/session.py)     │  CDP connection, DOM service, watchdogs
│                                         │  (popups, captchas, downloads, security),
│                                         │  event bus, screenshot, element indexing
└─────────────────────────────────────────┘
```

Each integration approach taps into a different layer.

## The Four Approaches

### A. MCP Server

Browser-use runs as an MCP server (`uvx browser-use[cli] --mcp`). Your agent
calls tools via the Model Context Protocol.

**Pros:** Language-agnostic, standard protocol, works with Claude Desktop.
**Cons:** Smallest action subset, no custom actions, no coordinate clicking,
hardcoded tool set.

### B. Python Library (BrowserSession + Tools)

Your agent imports `BrowserSession` and `Tools` directly and builds its own
control loop in Python.

**Pros:** Full access to all 30+ actions, custom action registration,
structured extraction, coordinate clicking, direct CDP access.
**Cons:** Requires Python. If your agent writes this code dynamically, it costs
tokens and may trigger security prompts.

### C. Agent Class with Custom LLM

Your agent uses browser-use's `Agent` class but swaps the LLM.

**Pros:** Everything from B plus loop detection, planning, multi-action guards,
message compaction.
**Cons:** Your LLM must produce `AgentOutput` schema. Least flexible if you
have your own reasoning loop.

### D. Skill CLI (JSON over Unix Socket / TCP)

Browser-use runs a persistent session server. Your agent sends JSON commands
over a socket. This is what the `browser-use` CLI uses internally.

**Pros:** Language-agnostic, pre-approvable as a skill, persistent browser
session, low token cost (no code generation needed), supports coordinate
clicking, JS eval, cookie management, wait conditions.
**Cons:** Fixed command set (no custom actions), no structured extraction, no
`ActionResult` model, no multi-action batching.

## Comparison Matrix

| Feature | MCP (A) | Library (B) | Agent+LLM (C) | Skill CLI (D) |
|---|:---:|:---:|:---:|:---:|
| Language-agnostic | yes | no | no | yes |
| Pre-approvable as skill | yes | no | no | yes |
| Token cost to use | low | high | high | low |
| Watchdogs (popups, captcha, downloads) | yes | yes | yes | yes |
| DOM with element indexing | yes | yes | yes | yes |
| Screenshots | yes | yes | yes | yes |
| Coordinate clicking | no | yes | yes | yes |
| All 30+ actions | no | yes | yes | partial |
| Custom actions | no | yes | yes | no |
| Structured extraction (Pydantic) | no | yes | yes | no |
| ActionResult model | no | yes | yes | no |
| Element metadata (bbox, attrs) | no | yes | yes | yes |
| JavaScript execution | no | yes | yes | yes |
| Cookie management | no | yes | yes | yes |
| Wait conditions | no | yes | yes | yes |
| Direct CDP access | no | yes | yes | no |
| Multi-action safety guards | no | no | yes | no |
| Loop detection | no | no | yes | no |
| Planning/memory | no | no | yes | no |

## When the Library Approach (B) is Worth It

The Python Library approach costs more tokens (the agent must write and
potentially iterate on Python code) and may trigger security approval prompts.
It is worth the cost when:

1. **You need structured data extraction.** The `extract` action takes a Pydantic
   schema and returns validated JSON. The Skill CLI has no equivalent — you
   would have to parse DOM text yourself.

2. **You need custom actions.** The `@tools.action()` decorator lets you register
   domain-specific operations (e.g., 2FA handling, API calls, database writes)
   that become part of the action vocabulary. The Skill CLI command set is fixed.

3. **You need direct CDP access.** Some tasks require low-level browser control
   (network interception, performance profiling, custom event listeners) that
   only the CDP client exposes.

4. **You need the Agent loop.** If the task is complex enough to benefit from
   loop detection, planning, memory compaction, and multi-action sequencing
   with page-change guards, using the `Agent` class with your own LLM (Option C)
   is the most complete integration.

5. **You are doing multi-page extraction with pagination.** The `extract` action
   supports `already_collected` to deduplicate across pages and `start_from_char`
   for long documents. Replicating this over the CLI is verbose and error-prone.

**Stick with the Skill CLI (D) when:**

- The task is a sequence of navigate/click/type/read operations
- You only need the DOM text representation (which `state` provides)
- Token budget is a concern
- Security approval flow matters (pre-approved skill vs. arbitrary Python)
- Your agent is not written in Python

## How an Agent Should Use the Library Approach

### Strategy

1. **Write a self-contained async Python script** that imports `BrowserSession`
   and `Tools`, executes the task, and prints results to stdout.
2. **Keep it minimal.** Do not replicate browser-use's Agent loop unless you
   need planning/memory. For most tasks, a simple while loop with
   `get_browser_state_summary()` → decide → `tools.act()` is sufficient.
3. **Use `ActionResult` fields** to communicate back: `extracted_content` for
   data, `is_done` + `success` for completion status.
4. **Handle page changes.** After any navigation or click that might change the
   page, re-fetch state before acting on element indices.

### Minimal Template

```python
import asyncio
from browser_use import BrowserSession, Tools
from browser_use.tools.views import (
    NavigateAction, ClickElementAction, InputTextAction,
    ScrollAction, ExtractAction, DoneAction, SearchPageAction,
)

async def main():
    session = BrowserSession(headless=False)
    await session.start()
    tools = Tools()

    try:
        # Navigate
        await tools.act(
            NavigateAction(url='https://example.com'),
            browser_session=session,
        )

        # Get page state (DOM + screenshot)
        state = await session.get_browser_state_summary()
        dom_text = state.dom_state.llm_representation()
        # dom_text looks like:
        #   [1]<a href="/about">About</a>
        #   [2]<input type="text" placeholder="Search..."/>
        #   [3]<button>Submit</button>

        # Click element by index
        await tools.act(
            ClickElementAction(index=2),
            browser_session=session,
        )

        # Type into focused element
        await tools.act(
            InputTextAction(index=2, text='browser automation', clear=True),
            browser_session=session,
        )

        # Click submit
        await tools.act(
            ClickElementAction(index=3),
            browser_session=session,
        )

        # Re-fetch state after page change
        state = await session.get_browser_state_summary()
        print(state.dom_state.llm_representation())

    finally:
        await session.stop()

asyncio.run(main())
```

### Common Patterns

#### Pattern 1: Extract Structured Data

```python
from pydantic import BaseModel
from browser_use import BrowserSession, Tools
from browser_use.tools.views import NavigateAction, ExtractAction
from browser_use.llm.openai.chat import ChatOpenAI

class Product(BaseModel):
    name: str
    price: float
    in_stock: bool

class ProductList(BaseModel):
    products: list[Product]

async def extract_products():
    session = BrowserSession(headless=True)
    await session.start()
    tools = Tools()
    llm = ChatOpenAI(model='gpt-4.1-mini')

    await tools.act(
        NavigateAction(url='https://shop.example.com/products'),
        browser_session=session,
    )

    result = await tools.act(
        ExtractAction(
            query='Extract all products with name, price, and stock status',
            output_schema=ProductList.model_json_schema(),
        ),
        browser_session=session,
        page_extraction_llm=llm,
    )

    print(result.extracted_content)  # Validated JSON matching ProductList
    await session.stop()
```

#### Pattern 2: Register Custom Actions

```python
from browser_use import ActionResult, BrowserSession, Tools

tools = Tools()

@tools.registry.action('Save data to local file')
async def save_data(filename: str, content: str):
    from pathlib import Path
    Path(filename).write_text(content)
    return ActionResult(extracted_content=f'Saved {len(content)} chars to {filename}')

@tools.registry.action('Query database for user info')
async def query_user(user_id: str, browser_session: BrowserSession):
    # browser_session is auto-injected
    # You can combine browser state with external data
    state = await browser_session.get_browser_state_summary()
    return ActionResult(
        extracted_content=f'User {user_id} found',
        long_term_memory=f'Current page: {state.url}',
    )
```

#### Pattern 3: Coordinate-Based Clicking

```python
# Useful for canvas elements, SVGs, or when DOM indices are unreliable
await tools.act(
    ClickElementAction(coordinate_x=450, coordinate_y=300),
    browser_session=session,
)
```

#### Pattern 4: Search Page Content

```python
# Fast text search without LLM cost (unlike extract)
result = await tools.act(
    SearchPageAction(
        pattern=r'price:\s*\$[\d.]+',
        regex=True,
        max_results=10,
    ),
    browser_session=session,
)
print(result.extracted_content)  # Matching text with surrounding context
```

#### Pattern 5: Full Agent Loop with Custom LLM

```python
from browser_use import Agent, BrowserSession
from browser_use.llm.anthropic.chat import ChatAnthropic

session = BrowserSession(headless=False)
agent = Agent(
    task='Find and compare prices for "wireless keyboard" on three stores',
    llm=ChatAnthropic(model='claude-sonnet-4-20250514'),
    browser_session=session,
    extend_system_message='Always prefer DuckDuckGo over Google for searches.',
    max_actions_per_step=3,
)

history = await agent.run(max_steps=50)
result = history.final_result()
print(result)
```

### Reading the DOM State

The DOM representation returned by `state.dom_state.llm_representation()` is
the core interface between browser-use and any LLM. It looks like this:

```
[1]<a href="/products">Products</a>
[2]<input type="search" placeholder="Search..." value=""/>
[3]<button type="submit">Go</button>
[4]<div role="navigation">
  [5]<a href="/about">About Us</a>
  [6]<a href="/contact">Contact</a>
</div>
[7]<select name="category">
  <option value="all">All Categories</option>
  <option value="electronics">Electronics</option>
</select>
```

Key points:
- Numbers in brackets are **element indices** — use them with `ClickElementAction(index=N)`
- Only interactive/visible elements get indices
- Occluded elements are filtered out (paint-order analysis)
- Accessibility attributes (`role`, `aria-label`, `placeholder`) are included
- iframes and shadow DOM are traversed (configurable depth)

The `selector_map` dict maps these indices to `EnhancedDOMTreeNode` objects for
programmatic access:

```python
state = await session.get_browser_state_summary()
for idx, node in state.dom_state.selector_map.items():
    print(f"[{idx}] <{node.tag_name}> attrs={node.attributes}")
```

### Page Info and Scroll Position

```python
state = await session.get_browser_state_summary()
if state.page_info:
    pi = state.page_info
    print(f"Viewport: {pi.viewport_width}x{pi.viewport_height}")
    print(f"Page: {pi.page_width}x{pi.page_height}")
    print(f"Scroll: ({pi.scroll_x}, {pi.scroll_y})")
    print(f"Pixels below fold: {pi.pixels_below}")
```

## Skill CLI Wire Protocol Reference

For agents using the Skill CLI (Option D), the protocol is line-delimited JSON
over a Unix socket at `/tmp/browser-use-{session}.sock`:

```
→  {"id":"r1", "action":"open", "session":"default", "params":{"url":"https://example.com"}}
←  {"id":"r1", "success":true, "data":{"url":"https://example.com"}}

→  {"id":"r2", "action":"state", "session":"default", "params":{}}
←  {"id":"r2", "success":true, "data":{"_raw_text":"viewport: 1280x720\npage: ...\n[1]<a>..."}}

→  {"id":"r3", "action":"click", "session":"default", "params":{"args":[1]}}
←  {"id":"r3", "success":true, "data":{"clicked":1}}

→  {"id":"r4", "action":"click", "session":"default", "params":{"args":[100, 200]}}
←  {"id":"r4", "success":true, "data":{"clicked_coordinate":{"x":100,"y":200}}}

→  {"id":"r5", "action":"input", "session":"default", "params":{"index":2, "text":"hello"}}
←  {"id":"r5", "success":true, "data":{"input":"hello", "element":2}}

→  {"id":"r6", "action":"screenshot", "session":"default", "params":{}}
←  {"id":"r6", "success":true, "data":{"screenshot":"<base64>", "size":12345}}

→  {"id":"r7", "action":"eval", "session":"default", "params":{"js":"document.title"}}
←  {"id":"r7", "success":true, "data":{"result":"Page Title"}}

→  {"id":"r8", "action":"get", "session":"default", "params":{"get_command":"bbox","index":3}}
←  {"id":"r8", "success":true, "data":{"index":3, "bbox":{"x":100,"y":50,"width":200,"height":40}}}

→  {"id":"r9", "action":"wait", "session":"default", "params":{"wait_command":"selector","selector":".loaded","timeout":5000}}
←  {"id":"r9", "success":true, "data":{"selector":".loaded", "found":true}}
```

Available commands: `open`, `click`, `type`, `input`, `scroll`, `back`,
`screenshot`, `state`, `switch`, `close-tab`, `keys`, `select`, `eval`,
`extract`, `cookies`, `wait`, `hover`, `dblclick`, `rightclick`, `get`.

The `get` sub-commands: `title`, `html`, `text`, `value`, `attributes`, `bbox`.

The `cookies` sub-commands: `get`, `set`, `clear`, `export`, `import`.

## Decision Flowchart

```
Is your agent written in Python?
├─ No → Use Skill CLI (D) or MCP (A)
│       ├─ Need standard protocol? → MCP (A)
│       └─ Need more commands? → Skill CLI (D)
│
└─ Yes
    ├─ Is the task a simple navigate/click/type sequence?
    │   └─ Yes → Skill CLI (D) — saves tokens, pre-approvable
    │
    ├─ Do you need structured extraction or custom actions?
    │   └─ Yes → Python Library (B)
    │
    ├─ Do you need loop detection, planning, memory?
    │   └─ Yes → Agent + Custom LLM (C)
    │
    └─ Is token cost or security approval a primary concern?
        ├─ Yes → Skill CLI (D)
        └─ No → Python Library (B) — strictly more capable
```

## Security Considerations

| Approach | Approval surface | Risk |
|---|---|---|
| Skill CLI (D) | Pre-approvable as a single skill | Commands are fixed; `eval` allows arbitrary JS in the browser context |
| MCP (A) | Per-tool approval or blanket MCP trust | Similar to CLI; smaller command set |
| Library (B) | Arbitrary Python execution | Full system access; each script may need user approval |
| Agent+LLM (C) | Same as B | Same as B, plus the LLM controls the browser autonomously |

The Skill CLI's `eval` command deserves attention: it executes arbitrary
JavaScript in the page context. This is equivalent to the browser devtools
console — powerful but scoped to the browser sandbox. It cannot access the local
filesystem or execute system commands (unlike Python).

The Library approach (B/C) runs arbitrary Python, which has full system access.
An agent writing and executing Python scripts is functionally equivalent to
code execution. If your security model requires pre-approval of capabilities,
the Skill CLI is the safer boundary — though `eval` still allows page-context
code execution.
