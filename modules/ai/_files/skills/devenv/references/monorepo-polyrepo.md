# Monorepo & Polyrepo Setups

Documentation:
- Monorepo: https://devenv.sh/guides/monorepo/
- Polyrepo: https://devenv.sh/guides/polyrepo/
- Composing using imports: https://devenv.sh/composing-using-imports/
- Inputs: https://devenv.sh/inputs/

## Monorepo (single repo, multiple services)

Since devenv 1.10. Multiple services share common configuration via imports.

### Directory structure

```
my-monorepo/
├── shared/
│   └── devenv.nix       # Shared config (common packages, services, git-hooks)
├── services/
│   ├── api/
│   │   ├── devenv.yaml  # imports: [/shared]
│   │   └── devenv.nix   # API-specific config
│   └── frontend/
│       ├── devenv.yaml  # imports: [/shared]
│       └── devenv.nix   # Frontend-specific config
```

### Shared configuration

```nix
# shared/devenv.nix
{ pkgs, ... }:
{
  packages = [ pkgs.curl pkgs.jq ];

  services.postgres = {
    enable = true;
    initialDatabases = [{ name = "myapp"; }];
  };

  git-hooks.hooks = {
    prettier.enable = true;
    nixpkgs-fmt.enable = true;
  };
}
```

### Service configuration

```yaml
# services/api/devenv.yaml
imports:
  - /shared       # Absolute path = relative to repo root (where .git is)
```

```nix
# services/api/devenv.nix
{ pkgs, ... }:
{
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_20;
  };

  env.API_PORT = "3000";

  scripts.dev.exec = "npm run dev";
  scripts.test.exec = "npm test";
}
```

### Key mechanism: absolute import paths

Paths starting with `/` in `devenv.yaml` imports are resolved from the
repository root (where `.git` is located). This allows services in different
subdirectories to reference shared configurations consistently.

### Referencing the repo root in processes

Use `config.git.root` to get the absolute path to the repository root:

```nix
# services/api/devenv.nix
{ pkgs, config, ... }:
{
  processes.api.exec = {
    exec = "npm run dev";
    cwd = "${config.git.root}/services/api";
  };

  processes.frontend.exec = {
    exec = "npm run dev";
    cwd = "${config.git.root}/services/frontend";
  };
}
```

This allows running multiple service processes from a single devenv shell,
regardless of which directory you're in.

### Working with a specific service

```bash
cd services/api
devenv shell        # Gets shared + api-specific config
```

## Polyrepo (multiple repos)

New in devenv 2.0. Two approaches for cross-repo composition.

**Important caveat**: The remote repository must use `devenv.nix` only —
`devenv.yaml` from imported projects is NOT evaluated (GitHub issue #2205).

### Approach 1: Composing with imports

Merge an entire project's config (packages, services, env, etc.) into your environment.

```yaml
# devenv.yaml
inputs:
  my-service:
    url: github:myorg/my-service
    flake: false

imports:
  - my-service
```

```nix
# devenv.nix
{ pkgs, ... }:
{
  # Your local config — everything from my-service is merged in
  languages.javascript.enable = true;
}
```

This gives you all packages, services, env vars, etc. from the remote project
plus your local additions.

### Approach 2: Referencing config across inputs

Access specific options/outputs from another project WITHOUT merging everything.

```yaml
# devenv.yaml
inputs:
  my-service:
    url: github:myorg/my-service
    flake: false
```

```nix
# devenv.nix
{ inputs, ... }:
let
  my-service = inputs.my-service.devenv.config.outputs.my-service;
in {
  packages = [ my-service ];
  processes.my-service.exec = "${my-service}/bin/my-service";
}
```

The key: `inputs.<name>.devenv.config` gives access to any option from the
remote project's evaluated configuration.

### When to use which approach

| Scenario | Approach |
|---|---|
| Shared base environment (common tools, services) | Import (merge everything) |
| Consuming a built artifact from another project | Reference specific config |
| Backend needs frontend's build output | Reference specific output |
| Multiple services share identical DB config | Import shared config |
| Tight coupling (need all of remote's env) | Import |
| Loose coupling (need one output/package) | Reference |

### Exposing outputs from a project

For Approach 2 to work, the remote project must declare outputs:

```nix
# remote repo: devenv.nix
{ config, ... }:
{
  languages.python.enable = true;

  outputs.my-service = config.languages.python.import ./. {};
}
```

## Out-of-tree devenvs (devenv 2.0)

Use a devenv configuration from another repo without the local project
having its own `devenv.nix`:

```bash
devenv --from github:myorg/configs shell
devenv --from github:myorg/configs test
```

Useful for: standardized team environments, bootstrapping new projects,
CI environments where you don't want config per repo.

## Combining with direnv

For monorepos, each service directory can have its own `.envrc`:

```bash
# services/api/.envrc
#!/usr/bin/env bash
eval "$(devenv direnvrc)"
use devenv
```

For polyrepos, each repo has its own `.envrc` pointing to its local devenv.
Cross-repo references are handled via `devenv.yaml` inputs, not direnv.
