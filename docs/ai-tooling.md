# Adding an MCP server; independent AI aspects

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

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
| `my.ai.agents.codex.model` | `"gpt-6-sol"` | Default model merged into Codex's writable config.toml; `null` leaves it unmanaged |
| `my.ai.agents.codex.reasoningEffort` | `"medium"` | `model_reasoning_effort` for Codex's default (execute) mode |
| `my.ai.agents.codex.planReasoningEffort` | `"xhigh"` | `plan_mode_reasoning_effort` for Codex's Plan mode (`Shift+Tab`); CLI only — Codex Desktop ignores it ([openai/codex#18712](https://github.com/openai/codex/issues/18712)) |
| `my.ai.agents.codex.reasoningEffortOverride` | `false` | Upstream `[features] reasoning_effort_override`; off on purpose — from codex 0.154.0 it makes Plan mode's effort change emit a `configuration_update` that `gpt-5.6-luna/terra/sol` reject with HTTP 400 ([openai/codex#44751](https://github.com/openai/codex/issues/44751)) |
| `my.ai.content.enable` | `false` | Skills and rules exported under `$XDG_CONFIG_HOME/ai/content/` |
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
`features.reasoning_effort_override` (a boolean) — is instead
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

