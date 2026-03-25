# Devenv Tasks — Full Reference

Tasks enable dependency-ordered, parallel execution of commands. They integrate with
shell entry, tests, and processes.

## Defining tasks

```nix
{ pkgs, config, ... }:
{
  tasks."myapp:hello" = {
    exec = ''echo "Hello, world!"'';
  };
}
```

Naming convention: `namespace:name` (e.g. `myapp:build`, `myapp:test`).

## Running tasks

```bash
devenv tasks run myapp:hello          # Run a single task
devenv tasks run myapp                # Run all tasks in namespace
devenv tasks run myapp:hello --input key=value  # Pass input (2.0+)
devenv tasks run myapp:hello --input-json '{"key": "value"}'
```

## Lifecycle events

Two built-in events hook into devenv operations:

| Event | Triggers before | Notes |
|---|---|---|
| `devenv:enterShell` | `devenv shell`, `devenv up` | |
| `devenv:enterTest` | `devenv test` | Auto-depends on `devenv:enterShell` |

Use `before` to run a task before a lifecycle event or another task:

```nix
{
  tasks."bash:hello" = {
    exec = "echo 'Hello world from bash!'";
    before = [ "devenv:enterShell" ];
  };
}
```

Use `after` to run a task after another task completes:

```nix
{
  tasks."app:cleanup" = {
    exec = "rm -f ./server.pid";
    after = [ "devenv:processes:app-server" ];
  };
}
```

## Language-specific tasks

Use `package` to run with a specific interpreter:

```nix
{
  tasks."python:hello" = {
    exec = ''print("Hello world from Python!")'';
    package = config.languages.python.package;
  };
}
```

## Status checking (skip when up-to-date)

```nix
{
  tasks."myapp:migrations" = {
    exec = "db-migrate";
    status = "db-needs-migrations";
  };
}
```

If `status` exits 0, `exec` is skipped. Cached outputs are restored for dependent tasks.

## File modification tracking

```nix
{
  tasks."myapp:build" = {
    exec = "npm run build";
    execIfModified = [
      "src/**/*.ts"
      "package.json"
    ];
    cwd = "./frontend";
  };
}
```

Tracks modification times and content hashes. Skipped tasks pass cached outputs to dependents.

## Input / output

Environment variables available inside task `exec`:

| Variable | Description |
|---|---|
| `$DEVENV_TASK_INPUT` | JSON object of task inputs |
| `$DEVENV_TASKS_OUTPUTS` | JSON from dependent tasks |
| `$DEVENV_TASK_OUTPUT_FILE` | Writable file for task outputs |
| `$DEVENV_TASK_EXPORTS_FILE` | For exporting environment variables |

```nix
{
  tasks."myapp:mytask" = {
    exec = ''
      echo $DEVENV_TASK_INPUT > $DEVENV_ROOT/input.json
      echo '{ "output": 1 }' > $DEVENV_TASK_OUTPUT_FILE
    '';
    input = { value = 1; };
  };
}
```

CLI input override (2.0+):

```bash
devenv tasks run myapp:mytask --input value=42 --input name=hello
devenv tasks run myapp:mytask --input-json '{"value": 42}'
```

`--input-json` applies first, then individual `--input` flags override.

## Process integration

Processes automatically become tasks with the `devenv:processes:` prefix (since 1.4):

```nix
{
  processes.web-server.exec = "python -m http.server 8080";

  tasks."app:setup-data" = {
    exec = "echo 'Setting up data...'";
    before = [ "devenv:processes:web-server" ];
  };
}
```

## Git root reference (monorepo)

```nix
{
  tasks."build:frontend" = {
    exec = "npm run build";
    cwd = "${config.git.root}/frontend";
  };
}
```

## Agent-friendly tasks pattern

Wrap frequently used agent commands as devenv tasks so users can allowlist
`devenv tasks run *` (or a specific namespace like `devenv tasks run agent:*`)
in Claude Code's permissions. This avoids repeated security prompts for common
operations.

```nix
{
  # Namespace for agent-invoked commands
  tasks."agent:build" = {
    exec = "mvn package -DskipTests";
  };

  tasks."agent:test" = {
    exec = "mvn test";
  };

  tasks."agent:lint" = {
    exec = "npm run lint";
  };

  tasks."agent:fmt" = {
    exec = "prettier --write .";
  };

  tasks."agent:typecheck" = {
    exec = "npx tsc --noEmit";
  };

  tasks."agent:db-migrate" = {
    exec = "db-migrate up";
    status = "db-needs-migrations";  # skip if already migrated
  };
}
```

### Claude Code allowlist setup

Users add to `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(devenv tasks run agent:*)"
    ]
  }
}
```

Or at project level in `.claude/settings.local.json`. This grants the agent
permission to run any task in the `agent:` namespace without prompting.

### Recommended agent task namespaces

| Namespace | Purpose | Examples |
|---|---|---|
| `agent:` | Generic agent commands | `agent:build`, `agent:test`, `agent:lint` |
| `check:` | Validation / verification | `check:types`, `check:format`, `check:deps` |
| `db:` | Database operations | `db:migrate`, `db:seed`, `db:reset` |
| `dev:` | Development helpers | `dev:setup`, `dev:clean`, `dev:docs` |

### Benefits over raw shell commands

- **Declarative**: tasks are versioned in `devenv.nix` — the whole team gets the same commands
- **Dependency ordering**: tasks can depend on each other and run in parallel
- **Caching**: `status` and `execIfModified` skip unnecessary work
- **Allowlisting**: one permission rule covers all agent tasks
- **Discoverability**: `devenv tasks run` lists available tasks
