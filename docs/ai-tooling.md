---
paths:
  - "modules/ai/**"
  - "modules/ai-*.nix"
  - "modules/agent*.nix"
  - "modules/mcp-*.nix"
---

# Adding an MCP server; independent AI aspects

Read this before changing the files listed under `paths` in the front matter above. Claude loads it automatically when it reads one of them.

### Adding an MCP Server

**Prefer a remote endpoint to a local process.** `my.ai.mcp.servers` in
`modules/mcp-servers.nix` declares each server as `{ stdio = <pkg>; remote = {
url; auth; }; }`. `stdio` is required for portable exports; `remote` defaults to
`null`. `modules/mcp-clients.nix` renders the catalog into each client's shape,
and `modules/agent-integration.nix` installs it only for enabled Nix agents.
The catalog is an `attrsOf submodule` option: another aspect can add a server
through `my.ai.mcp.servers.<name>` without duplicating the client mappings.

The reason the distinction matters is measured, 2026-09-10: **claude-code
connects remote HTTP servers lazily, on first tool use, while stdio servers are
started at session start.** Seven stdio servers cost 13 processes and 491 MiB
RSS in *every* session — `npx -y` keeps an `npm exec` node VM alive beside each
server, so each one cost two processes — for 0,5–1,5 s of CPU over 53 minutes.
Nine concurrent sessions were running at the time.

Before writing a stdio wrapper, POST an `initialize` at the vendor's endpoint
and see whether it speaks streamable HTTP. Four of the seven servers here were
literally `npx mcp-remote@0.1.38 <url>`, i.e. a stdio-to-HTTP bridge for a
client that needs none.

**Credentials never go in the config.** `remote.auth` names a *sops file*, never
a value, so no renderer can put a secret in `/nix/store`. Each agent carries it
its own way: claude-code via `headersHelper` (a command printing JSON headers at
connection time — it must read the sops FILE, because claude-code runs
plugin-sourced helpers with `scrubCredentialEnv` and an inherited variable
arrives empty), codex via `bearer_token_env_var` loaded by `+agent-codex`.
Passing a key as a command-line argument is what this replaced: a plain
`ps -Ao args` printed three of them in clear text to every process of this user.
The stdio wrappers are held to the same bar since 2026-09-11: `+mcp-context7`
lets the server fall back to `CONTEXT7_API_KEY` from its environment, and
`+mcp-travily` passes `--header 'Authorization: Bearer ${TRAVILY_API_KEY}'` in
single quotes, which mcp-remote 0.1.38 expands itself — `ps` shows the pattern,
never the value. Measured on both by a real tool call with the probe's own
process tree checked against the secret. Two things that measurement also
turned up: **restrict such a check to your own process tree and never print
argv lines** — other sessions' servers run on the same machine, and their
command lines are exactly what must not land in a transcript — and MCP server
processes from older sessions outlive the session that started them, so a
wrapper fix only protects new starts.

**Antigravity CLI (`agy`) reads a different layout, and the online docs lag
the binary.** Verified against the installed 1.1.22 on 2026-09-11: the global
customization root is `~/.gemini/config/` (the built-in `agy-customizations`
skill and the binary's strings both say so; `/docs/cli/plugins` still names
`~/.gemini/antigravity-cli/{skills,plugins}/`, the pre-migration layout that
agy logged migrating away from on first start here). Skills and MCP servers go
in as ONE plugin, `~/.gemini/config/plugins/nix-darwin/{plugin.json,skills/,mcp_config.json}`,
the `home.file` entries in `modules/agent-integration.nix`. Rules
go to `~/.gemini/GEMINI.md` as a managed block (`modules/agent-integration.nix`),
because gemini-cli appends `/memory add` entries to the same file. Its
`mcp_config.json` schema, read back from what `agy mcp add` wrote in a scratch
HOME: a remote server is `serverUrl` + `headers` with the token as a
**literal** (`url`/`httpUrl` are documented as unsupported), a stdio one is
`command`/`args`/`env` — no headers helper, no env-var name, no `${VAR}`
interpolation. A literal would land in the store, so the antigravity row has
`authKinds = [ "none" ]`: javadocs is remote, context7 and travily go through
their stdio wrappers, exactly opencode's shape. `agy plugin validate <dir>`
checks a plugin directory (store symlinks are fine — a scratch plugin with
symlinked `SKILL.md` files validated); `agy mcp list` shows only the root
file's servers, plugin servers appear in the TUI's `/mcp`; `agy plugin disable
nix-darwin` is the off switch. `~/.gemini/antigravity-cli/settings.json` stays
unmanaged — agy writes to it.

`just mcp-check` probes every remote server with its real credential. It is the
startup check that lazy connect removes. Do **not** reach for `alwaysLoad`
instead — that also opts the server out of tool-schema deferral, putting every
tool schema into every turn's context.

**Not everything belongs in an MCP server at all.** A stateless query API is
often better as a skill CLI: `nixos` was a server holding 15,2 MiB per session
to answer HTTP lookups, and is now `+nix-query`, which imports the same upstream
code (`mcp_nixos.server.nix.fn`) and reimplements none of it. See
`modules/ai/_files/mcp-nixos/nixos-cli.py`. The same reasoning retired
`atlassian` in favour of the `jira` and `bitbucket-pr` skills.

1. Add the server entry through `my.ai.mcp.servers`, with a `stdio` wrapper and,
   where supported, a `remote` endpoint.
2. Load credentials at runtime from `$XDG_CONFIG_HOME/sops-nix/secrets`.
3. Gate host-specific servers with their feature option. `my.ai.atlassian.enable`
   remains the host gate for Atlassian MCP and the Jira/Bitbucket skills.
4. Use `my.ai.mcp.clients.<name>.exclude` to hide servers from one client.
   Claude and Antigravity exclude `atlassian` by default. Set
   `my.ai.mcp.servers.<name>.enable = false` to exclude a server from every
   client and export while retaining its wrapper. Devenv is disabled centrally
   until devenv#3065 is fixed; its skill supplies direct CLI calls instead.
   `programs.claude-code.mcpServers` feeds Home Manager's generated plugin,
   so removing an entry removes its plugin tools too.


### Claude Code: Code Mode

Code Mode (experimental) lets Claude write JavaScript that makes the tool calls. The built-in
`REPL` tool runs that code inside the Claude Code process. It is on for every session:
`programs.claude-code.settings.env.CLAUDE_CODE_EXPERIMENTAL_CODE_MODE = "1"` in
`modules/agents.nix`. Source: <https://code.claude.com/docs/en/code-mode>, read 2026-11-26.

- **Off for one run:** `+agent-claude --no-code-mode`. The wrapper is `wrappers.claude` in
  `modules/agents.nix`; `+agent-claude-superlite` (`modules/superlite.nix`) passes its
  arguments through to it. The wrapper removes the flag, wherever it stands, and sets
  the variable to `0`. The docs say a `0` anywhere wins over a `1` elsewhere.
  Limit: a session that ran with Code Mode on can be resumed only with it on, so
  `--no-code-mode --resume <id>` fails for such a session. The test is
  `modules/ai/_tests/test_agent_claude_wrapper.py`, part of `just ai-check`.
- **Off for good:** set the value to `"0"` in `modules/agents.nix`.
- **First start:** Claude Code asks once for confirmation and stores the answer in
  `~/.claude.json`. That file is writable and not managed here.
- **Minimum version:** 2.1.323. `ai-checks.nix` asserts it. From 2.1.328 on, Claude Code no
  longer passes the code's output to `UserPromptSubmit` hooks (commands that run each time
  a prompt is submitted); the iTerm2 hook (`modules/iterm2-claude-hooks.nix`) is one of them. The docs also say it runs only in
  an interactive terminal session, not in the VS Code panel or ACP.
- **What it changes for security:** the JavaScript and its file, web and MCP calls run
  outside the sandbox. In `auto` mode (`permissions.defaultMode = "auto"` in
  `modules/agents.nix`, where a classifier model decides instead of a prompt) the classifier
  reviews each piece of code, not the values computed at run time. A script can therefore read a secret and pass
  it on in one run without a prompt. `deny` rules and `PreToolUse` hooks still apply to
  each call inside the code. `permissions.ask = [ "REPL" ]` would make every script need
  approval; this repository deliberately does not set it (user decision, 2026-11-26).
  Prompt injection from a dependency, a web page or an MCP answer can now chain several
  actions in one script.
- **Remote switch:** Anthropic can turn the feature off through downloaded settings, and may
  change or remove it in any release.

### Independent AI aspects

Home Manager can import `homeManager.agents`, `agent-content`, `mcp-servers`
and `agent-integration` independently through `config.flake.modules`.
They import a shared, inert `ai-options` schema; none enables another aspect.
The workstation base imports all four and enables agents, content and MCP to
preserve the existing defaults. `ai-tools` separately provides general tools
such as `llm`, Ollama and `+nix-query`.

| Option | Default outside the workstation base | Effect |
|---|---|---|
| `my.ai.agents.enable` | `false` | Agent packages, settings and wrappers |
| `my.ai.agents.<name>.enable` | `true` | Select individual agents within that global gate |
| `my.ai.agents.codex.model` | `"gpt-6.2-sol"` | Default model merged into Codex's writable config.toml; `null` leaves it unmanaged |
| `my.ai.agents.codex.reasoningEffort` | `"medium"` | `model_reasoning_effort` for Codex's default (execute) mode |
| `my.ai.agents.codex.planReasoningEffort` | `"xhigh"` | `plan_mode_reasoning_effort` for Codex's Plan mode (`Shift+Tab`); CLI only — Codex Desktop ignores it ([openai/codex#18712](https://github.com/openai/codex/issues/18712)) |
| `my.ai.agents.codex.reasoningEffortOverride` | `true` | Upstream `[features] reasoning_effort_override` (experimental): Plan mode's effort change is sent as a `configuration_update` item instead of changing the request. Codex sends it only to models whose catalog entry sets `supports_reasoning_effort_updates` — in 0.160.0 that is `gpt-6-astra` and `gpt-6.1-sol`, in 0.170.0 also `gpt-6.2-sol` and `gpt-6.2-astra` (0.167.0 gets the 6.2 models from the remote catalog), not `gpt-6-sol`/`gpt-6-luna` (which therefore never get it; the HTTP 400 of [openai/codex#44751](https://github.com/openai/codex/issues/44751) is avoided by that gate, the issue itself is still open) |
| `my.ai.agents.codex.daemonAutoStart` | `false` | Upstream `[features] daemon_auto_start`: since 0.157.0 each interactive start launches a persistent `codex app-server --managed-daemon` with a detached hourly self-updater that bypasses the Nix pin and supply-chain cooldown ([openai/codex#48195](https://github.com/openai/codex/issues/48195)). `null` leaves it unmanaged |
| `my.ai.content.enable` | `false` | Skills and rules exported under `$XDG_CONFIG_HOME/ai/content/` |
| `my.ai.monitoring.enable` | `false` | Work Grafana monitoring MCP (`+mcp-monitoring`). stdio only: the endpoint speaks legacy SSE, so `mcp-remote` bridges it, and its URL is the sops secret `monitoring_mcp_url`, which cannot sit in a `remote` entry |
| `my.ai.superlite.enable` | `false` | `+agent-claude-superlite` (needs the Claude agent); the plugin is never loaded into plain `claude` |
| `my.ai.mcp.enable` | `false` | MCP wrappers, exports and integration |
| `my.ai.mcp.clients.<name>.enable` | `true` | MCP integration for this Nix agent; does not suppress explicit exports |
| `my.ai.mcp.clients.<name>.exclude` | Client-specific | Server names excluded from integration and exports |
| `my.ai.mcp.servers.<name>.enable` | `true` (devenv: `false`) | Expose server to clients and exports; retain wrapper when disabled |
| `my.ai.mcp.exports` | `[ ]` | Portable client formats under `$XDG_CONFIG_HOME/ai/mcp/` |

Agent names: `claude`, `codex`, `opencode`, `gemini`, `antigravity`.
MCP client/export names are the same except `gemini`, which has no adapter here.
The workstation base uses `lib.mkDefault`, so a host can override it directly:

```nix
# Keep agents and skills, but remove Nix-managed MCP integration and wrappers.
my.ai.mcp.enable = false;

# Or keep MCP for other agents and disable only Codex's integration.
my.ai.mcp.clients.codex.enable = false;
```

For standalone MCP, import only `homeManager.mcp-servers` and set:

```nix
my.ai.mcp = {
  enable = true;
  exports = [ "claude" "codex" "opencode" "antigravity" ];
};
```

Exports are `claude.json`, `codex.toml`, `opencode.json` and `antigravity.json`.
They use public HTTP endpoints directly and authenticated servers through stdio
wrappers that load their own credentials. They require no agent installation or
agent wrapper, but still require the referenced runtime secret files.
Bind these exports in the external client yourself; Nix does not overwrite its
configuration. Native Nix-agent transport choices stay unchanged.

Content-only users import `homeManager.agent-content` and enable
`my.ai.content.enable`. Neutral exports contain `skills/`, `rules/` and
`rules.md`. The integration aspect additionally delivers these to enabled agents
through their existing paths. Worktrunk plugins and Claude-based commit generation
are gated by the corresponding agent; Worktrunk itself remains independent.

**External plugins come in as `flake = false` inputs and load by store path.**
`programs.claude-code.plugins` turns each entry into a `--plugin-dir` on the
`claude` wrapper, so nothing is installed through `/plugin` and no marketplace
state exists to drift. Worktrunk and the official Gradle skills
(`modules/gradle.nix`, input `gradle-skills`) work this way; Codex gets the
individual skill directories through `programs.codex.skills`. Both are gated by
the agent toggles. Move such an input with `just update-input <name>`, never
`nix flake update`, so the cooldown applies.

**IntelliJ worktrees get the worktrunk hooks through `+wt-intellij-setup`.**
IntelliJ creates worktrees with `git worktree add`, so no `wt switch` runs and no
worktrunk hook fires. Enter `/etc/profiles/per-user/<user>/bin/+wt-intellij-setup` as
"Run setup script" in IntelliJ's New Worktree dialog; it runs `wt hook pre-start`,
`post-start` and `post-switch` in the new worktree and logs to
`~/Library/Logs/wt-intellij-setup/`. The user hooks in `modules/worktrunk.nix` copy the
gitignored files and call `+wt-inherit-trust`. It runs `direnv allow` only for an
`.envrc` identical to the approved one in the primary worktree, and, independently,
`devenv allow` only when `devenv.nix` and `devenv.yaml` are identical to the primary
worktree's and that worktree is approved (a blind `allow` would run code from a foreign branch). Both helpers are built in
`modules/worktrunk.nix`; the helper's tests run in `checks.wt-inherit-trust`. Details,
the project `.config/wt.toml` template and the open questions about IntelliJ's argument
position and the background hooks: `modules/ai/_files/skills/devenv/references/worktrees.md`.

**superlite is the exception: opt-in, one process.** Its SessionStart hook
injects a skill into every session and its PreToolUse hooks run on every
Bash/Edit/Agent call, so it is not in `programs.claude-code.plugins`. Run
`+agent-claude-superlite` (`modules/superlite.nix`) to load it with
`--plugin-dir` for that process only. The wrapper pins bash 5 and python 3
because the hooks use bash 4 syntax and `/bin/bash` is 3.2.57. The input is
days old and moves daily: `just update-input superlite` applies the cooldown,
and a brand-new input needs `--allow-rollback` once, because Nix first locks
the branch HEAD, which is inside the window.

**Keep the integration aspect imported when disabling previously managed agents.**
Its activation hooks remove managed rules blocks and owned Codex MCP entries.
Codex keeps a writable config; the ownership journal lives at
`$XDG_STATE_HOME/nix-darwin/codex-mcp.json`. First migration reads the previous
Home Manager generation's generated MCP table. Only owned entries are updated
or removed; personal entries and other settings survive. A modified owned entry
or conflicting name fails before writing. Rename the personal entry or restore
the managed definition, then retry. A pending journal makes interrupted updates
recoverable; do not delete it to silence a conflict.

A small table of owned leaves — `tui.status_line` (a list), `model`,
`model_reasoning_effort`, `plan_mode_reasoning_effort` (strings), and
`features.reasoning_effort_override` and `features.daemon_auto_start` (booleans) — is instead
authoritative: activation sets each one every run while it is managed, wins
over a later `/model` or `/statusline` edit made in between, and on disable
removes it only if the file still holds the value this script last wrote (a
differing value, e.g. a fresh interactive choice, is left standing). This is
deliberately not the `mcp_servers` conflict semantics: a pre-existing `model`
is replaced without error, because the whole point is to override whatever
Codex's own picker last wrote, not to detect and reject it. `false` is a
managed value like any other, not "unmanaged" — only `null` on the Nix side
leaves a leaf alone. A leaf inside a table (`[tui]`, `[features]`) takes its
parent with it on disable only when that table would be left empty, so
personal `[features]` keys survive.

`just ai-check` tests isolated combinations, portable exports, transitive package
closures and writable-config migrations without live credentials or activation.

