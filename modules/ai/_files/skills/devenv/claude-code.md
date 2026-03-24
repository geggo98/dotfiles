# Claude Code — Devenv Integration Reference

Documentation: https://devenv.sh/integrations/claude-code/
Options reference: https://devenv.sh/reference/options/ (search for `claude.code`)

## Overview

Devenv provides a first-class integration module for Claude Code (`src/modules/integrations/claude.nix`).
It generates `.claude/` configuration files declaratively from `devenv.nix`, making agent configuration
versioniert, reproduzierbar, and part of the project setup.

## Enable

```nix
{
  claude.code.enable = true;
}
```

## Custom slash commands

Commands are available as `/command-name` in Claude Code.

```nix
{
  claude.code.commands = {
    test = ''
      Run all tests in the project
      ```bash
      mvn test
      ```
    '';
    fmt = ''
      Format all code
      ```bash
      mvn spotless:apply
      nixfmt **/*.nix
      ```
    '';
    build = ''
      Build the project
      ```bash
      mvn package -DskipTests
      ```
    '';
  };
}
```

## Hooks

Hooks run scripts in response to Claude Code tool events.

### Automatic formatting (default)

When `git-hooks.enable = true`, a PostToolUse hook runs git-hooks automatically
after Claude edits files. This is enabled by default.

```nix
{
  # This is the default — shown for clarity
  claude.code.hooks.postEdit = {
    enable = config.git-hooks.enable;
    name = "Run git-hooks";
    hookType = "PostToolUse";
    matcher = "^(Edit|MultiEdit|Write)$";
    command = ''cd "$DEVENV_ROOT" && ${config.git-hooks.package.meta.mainProgram} run'';
  };
}
```

### Custom hooks

```nix
{
  claude.code.hooks = {
    lint-on-save = {
      enable = true;
      name = "Lint after edits";
      hookType = "PostToolUse";
      matcher = "^(Edit|MultiEdit|Write)$";
      command = "cd $DEVENV_ROOT && mvn checkstyle:check -q";
    };

    notify-on-complete = {
      enable = true;
      name = "Notify completion";
      hookType = "Stop";
      command = "notify-send 'Claude Code' 'Task completed'";
    };
  };
}
```

### Available hook types

| Hook Type | Trigger |
|---|---|
| `PreToolUse` | Before a tool runs (use `matcher` to filter by tool name) |
| `PostToolUse` | After a tool runs successfully |
| `PostToolUseFailure` | After a tool fails |
| `Notification` | On notifications |
| `UserPromptSubmit` | When user submits a prompt |
| `SessionStart` | When a session begins |
| `SessionEnd` | When a session ends |
| `Stop` | When Claude stops |
| `SubagentStart` | When a sub-agent starts |
| `SubagentStop` | When a sub-agent stops |
| `PreCompact` | Before context compaction |
| `PermissionRequest` | On permission prompts |
| `WorktreeCreate` | When a git worktree is created |
| `WorktreeRemove` | When a git worktree is removed |
| `TeammateIdle` | When a teammate agent is idle |
| `TaskCompleted` | When a task completes |
| `ConfigChange` | When config changes |

## Sub-agents

Specialized AI assistants with their own context window and tool restrictions.

```nix
{
  claude.code.agents = {
    code-reviewer = {
      description = "Expert code review specialist";
      proactive = true;    # Automatically invoked when relevant
      model = "opus";      # null, "opus", "sonnet", "haiku"
      permissionMode = "plan";  # null, "default", "acceptEdits", "plan", "bypassPermissions"
      tools = [ "Read" "Grep" "TodoWrite" ];
      prompt = ''
        You are an expert code reviewer. Check for:
        - Code readability and maintainability
        - Proper error handling
        - Security vulnerabilities
        - Performance issues
        - Adherence to project conventions
      '';
    };

    test-writer = {
      description = "Writes comprehensive test suites";
      proactive = false;   # Only invoked explicitly
      tools = [ "Read" "Write" "Edit" "Bash" ];
      prompt = "You are a test writing specialist...";
    };

    nix-helper = {
      description = "Helps with devenv.nix and Nix configuration";
      proactive = true;
      tools = [ "Read" "Write" "Edit" "Bash" "Grep" ];
      prompt = ''
        You are a Nix and devenv specialist. Help with:
        - Writing and debugging devenv.nix configurations
        - Adding languages, services, and packages
        - Configuring processes with proper dependencies
        - Troubleshooting Nix evaluation errors
        Always run commands via `devenv shell -- <command>`.
      '';
    };
  };
}
```

### Available tools for agents

`Read`, `Write`, `Edit`, `MultiEdit`, `Grep`, `Glob`, `Bash`, `TodoWrite`, `WebFetch`, `WebSearch`

### Best practices

- Limit tool access: Only give agents the tools they need
- Clear descriptions: Help Claude understand when to use each agent
- Focused prompts: Keep agent prompts specific to their task
- Use proactive mode carefully: Only for agents that should run automatically
- Proactive agents are auto-invoked; non-proactive must be explicitly requested

## MCP servers

Configure MCP servers for additional context:

```nix
{
  claude.code.mcpServers = {
    devenv = {
      type = "stdio";
      command = "devenv";
      args = [ "mcp" ];
    };
    # Example: filesystem MCP
    filesystem = {
      type = "stdio";
      command = "npx";
      args = [ "-y" "@anthropic/mcp-server-filesystem" "/path/to/project" ];
    };
  };
}
```

## Global configuration for devenv-aware agents

Create `~/.claude/CLAUDE.md`:

```markdown
When devenv.nix doesn't exist and a command/tool is missing, create ad-hoc environment:

    $ devenv -O languages.rust.enable:bool true -O packages:pkgs "mypackage mypackage2" shell -- cli args

When the setup becomes complex create `devenv.nix` and run commands within:

    $ devenv shell -- cli args

See https://devenv.sh/ad-hoc-developer-environments/
```

## Agent workflow patterns

### Pattern 1: Ad-hoc (no project config)

The agent detects a missing tool and creates an environment on the fly:
```bash
devenv -O languages.python.enable:bool true \
       -O packages:pkgs "httpie jq" \
       shell -- python analyze.py
```

### Pattern 2: Project-bound (existing devenv.nix)

The agent executes within the project's declared environment:
```bash
devenv shell -- mvn test
devenv shell -- kubectl apply -f k8s/
```

### Pattern 3: Full declarative (hooks + commands + agents)

Everything is in `devenv.nix`: the agent's slash commands, hooks for auto-formatting,
sub-agents for specialized tasks, and MCP servers for extended context. The configuration
is versioned and reproducible — every developer and CI runner gets the same setup.
