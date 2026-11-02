---
name: web-research
description: "Researches the web thoroughly, e.g., how to use an API, library, or reference architecture. Can also be used as fallback when the WebSearch tool fails. Use when the user asks to research a complex topic. Also use it to cross-check findings from other sources (a second, independent opinion on claims, versions, or recommendations). For extensive research, use it in addition to the built-in WebSearch tool to save WebSearch calls, which are rate-limited."
argument-hint: "<research query>"
allowed-tools: Bash(./scripts/gemini_research.sh *) Bash(./scripts/perplexity_open_router_research.sh *) Bash(zsh *)
dependencies: "uv, gtimeout"
---

# Web Research Skill

## Usage

Run the scripts:

```bash
zsh ${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh $ARGUMENTS
zsh ${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh $ARGUMENTS
```

## 1. Purpose

Use this skill to research the web, e.g, for APIs, libraries, or design patterns before implementation.
It produces concise best-practice summaries, including alternatives, and tradeoffs. It produces a Markdown-formatted doocument containing the research results, including references as URLs.

> **Important:** Run scripts directly (`${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh`, `${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh`). Do **not** prefix with `bash` — the scripts require zsh and will fail under bash.

## 2. Usage Scenarios

Run before:

- Using a new API or library.
- Designing an unfamiliar feature or architecture.
- Evaluating alternative implementations.

## 3. Helper Scripts

| Script                                       | Purpose                          | Quick Mode | Deep Mode |
| -------------------------------------------- | -------------------------------- | ---------- | --------- |
| `${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh` | General-purpose quick research.  | Default    | `--deep`  |
| `${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh`                 | Deep research via Google Gemini. | `--flash`  | `--deep` (`--deeper`: flagship) |

The two scripts spell depth differently, and the difference matters when reading
their output. Perplexity switches **models** (`sonar-pro` → `sonar-reasoning-pro`
→ `sonar-deep-research`). Gemini stays on **one** model, `gemini-3.8-flash`, and
moves its *thinking level* instead — so `--flash`, no flag and `--deep` are
`low`, `medium` and `high` thinking on the same grounded search. The one exception
is `--deeper`, which switches to the flagship `gemini-4-argon` at `high` (several
times the price; use it only when `--deep` was not enough). Each Gemini run
prints the model and level it used on stderr; stdout stays pure Markdown.

### Arguments

- Provide the **research topic** as a natural-language sentence.
- Do **not** include year numbers; the agent fetches up-to-date data.
- More context ⇒ better results.

## 4. Examples

Always start with `--flash`. If the result doesn't work or if important parts are missing, use `--deep` to get more information.

### Quick Search

```bash
${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh --flash "Which Python HTTP client libraries support caching headers, and with which backends?"
```

### API Research

```bash
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh "Research Python best-practices for using the Atlassian Confluence API."
${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh "Write a Python best-practice manual for using the Atlassian Confluence API."
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh --deep "Give a second opinion on the Atlassian API usage. Alternatives and tradeoffs?"
```

### Library Research

```bash
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh "Best practices for using the os-lib library in Scala."
${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh "Create a manual for using os-lib in Scala with up-to-date best-practices."
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh --deep "Second opinion on using os-lib in Scala. Alternatives and tradeoffs?"
```

### Implementation Planning

```bash
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh "How to parse cron expressions in Rust, using stdlib or third-party crates?"
${CLAUDE_SKILL_DIR}/scripts/gemini_research.sh "Manual for parsing cron expressions in Rust with the cron crate."
${CLAUDE_SKILL_DIR}/scripts/perplexity_open_router_research.sh --deep "Evaluate the cron crate. Alternatives and tradeoffs?"
```

## 5. Tool Modes

| Option                   | Description                                       |
| ------------------------ | ------------------------------------------------- |
| `--flash`                | Fast, shallow lookup. Gemini: thinking level `low`. |
| `--deep`                 | Multi-step synthesis. Gemini: thinking level `high`. |
| *(no depth flag)*        | Gemini: thinking level `medium`, the model's own default. |
| `--deeper`               | Gemini only: flagship `gemini-4-argon`, thinking level `high`. Contradicts `--flash`/`--deep`. |
| `--backend B`            | Gemini only: `auto` (default), `google` or `openrouter`. See section 6. |
| `--thinking-level LEVEL` | Gemini only: `low`, `medium` or `high`, explicitly. Beats `--flash`/`--deep`. `minimal` is rejected — `gemini-3.8-flash` does not accept it. |
| `--model ID`             | Override the model. Gemini defaults to `gemini-3.8-flash`. |
| `--timeout DURATION`     | Global execution timeout (default: `5m`). Format follows GNU coreutils (e.g. `30s`, `5m`, `1h`). |
| `perplexity_open_router` | Breadth-first research across multiple sources.   |
| `gemini_research`        | Depth-first synthesis for comprehensive analysis. |

Passing two of `--flash`, `--deep` and `--deeper` together is refused with exit 2 rather than
silently resolved: they are two ends of one knob, not two preferences.

## 6. Fallbacks and Error Handling

If one agent fails, retry with the alternate tool.
Ensure network access and required API keys are configured.

**Gemini switches backend by itself.** It talks to Google directly (Interactions API,
Google Search grounding). If Google answers **402** (prepayment credits depleted — the
account must be topped up, the key is fine) or **429** (quota), `gemini_research`
retries the same request through OpenRouter (`google/<model>`, native Google search,
`OPENROUTER_API_KEY`) and says so on stderr:

```
gemini_research: google failed (HTTP 402) -> retrying via openrouter
gemini_research: backend=openrouter model=gemini-3.8-flash thinking_level=medium
```

Any other error (400, wrong model name, network) does **not** switch — it would fail
the same way on the other side. `--backend google` or `--backend openrouter` pins one
backend and disables the fallback. OpenRouter itself can answer 504/429 when Google
rate-limits it upstream; a repeat a few seconds later usually works. An answer without
any `Sources:` block means the model did not ground that time — repeat it.

## 7. Output Format

- Markdown-formatted structured output
- Sections for: Overview, Best Practices, Alternatives, Tradeoffs
- Links to primary references where available

## 8. Comparison Table

| Tool       | Scope   | Depth              | Response Speed |
| ---------- | ------- | ------------------ | -------------- |
| Perplexity | Broad   | Medium             | Fast           |
| Gemini     | Focused | Tunable, low..high | Scales with the thinking level |

## 9. Exit Codes

Read off both scripts, not aspirational — they agree:

| Code | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | Success                                                              |
| 1    | The request to the model failed (network, quota, model rejected it)  |
| 2    | Usage or configuration: no prompt, no API key, contradictory or unknown flags (argparse exits 2 too) |

`1` and `2` used to be listed the other way round here, beside a `3` that no
script has ever produced. That matters for `--thinking-level`: an unsupported
level is caught by argparse and exits **2**, before anything reaches Google.

## 10. Environment Variables

| Variable             | Description                    |
| -------------------- | ------------------------------ |
| `OPENROUTER_API_KEY` | Required for Perplexity agent. |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Gemini agent, direct to Google. |
| `OPENROUTER_API_KEY` | Also the Gemini fallback when Google answers 402/429. |

## 11. Troubleshooting

| Problem                       | Possible Cause                    | Fix                           |
| ----------------------------- | --------------------------------- | ----------------------------- |
| `Error: No response from API` | Connectivity issue or invalid key | Check internet or credentials |
| `Error: Model not found`      | Backend API changed               | Use different script          |
| `Output incomplete`           | Timeout or token limit            | Retry with `--deep`           |
| `Invalid topic format`        | Missing sentence structure        | Use full sentences            |

