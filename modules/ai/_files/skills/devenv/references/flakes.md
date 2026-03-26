# Devenv with Nix Flakes & flake-parts

Documentation:
- Using with Flakes: https://devenv.sh/guides/using-with-flakes/
- Feature comparison: https://devenv.sh/guides/using-with-flakes/#comparison-of-features
- Using with flake-parts: https://devenv.sh/guides/using-with-flake-parts/
- flake-parts docs: https://flake.parts/

## When to use Flakes vs standalone devenv

The devenv CLI (`devenv shell`) is the recommended default. Use Flakes when:

- You maintain an existing flake-based project ecosystem
- Your dev environment needs to be consumed by downstream flakes
- You need to combine devenv shells with other flake outputs (packages, NixOS modules, etc.)
- You want `nix develop` compatibility

### Feature comparison (devenv CLI vs Flakes)

| Feature | devenv CLI | Nix Flakes |
|---|---|---|
| Evaluation caching | Yes (incremental) | No |
| Faster evaluation (lazy trees) | Yes | No |
| Protection from garbage-collection | Yes | No |
| Built-in container support | Yes | Yes |
| External flake inputs | Yes | Yes |
| Shared remote configs | Yes | Yes |
| Pure evaluation | No (impure by default) | Yes |
| Cross-project references | Yes | Yes |
| SecretSpec | Yes | No |
| Running processes when testing | Yes | No |

Key takeaway: Flakes integration loses evaluation caching, lazy trees, GC protection,
SecretSpec, and process-in-test. These are significant trade-offs.

## Approach 1: Plain flake.nix (manual system iteration)

### Scaffold

```bash
nix flake init --template github:cachix/devenv
```

### Minimal flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
    devenv.url = "github:cachix/devenv";
  };

  nixConfig = {
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
    extra-substituters = "https://devenv.cachix.org";
  };

  outputs = { self, nixpkgs, devenv, ... } @ inputs:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = f: builtins.listToAttrs (map (system: {
        name = system;
        value = f system;
      }) systems);
    in {
      devShells = forEachSystem (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = devenv.lib.mkShell {
            inherit inputs pkgs;
            modules = [
              {
                languages.java.enable = true;
                services.mysql.enable = true;
                packages = [ pkgs.kubectl ];
              }
            ];
          };
        }
      );
    };
}
```

### Entering the shell

```bash
nix develop --no-pure-eval
```

`--no-pure-eval` is required because devenv needs to query the working directory.
Alternative: set `devenv.root` to an absolute path (breaks portability).

### Processes, services, tests inside flake shell

```bash
nix develop --no-pure-eval
# Now inside the shell:
devenv up          # Start processes
devenv test        # Run tests
```

### Direnv with flakes

```bash
# .envrc
if ! has nix_direnv_version || ! nix_direnv_version 3.0.4; then
  source_url "https://raw.githubusercontent.com/nix-community/nix-direnv/3.0.4/direnvrc" \
    "sha256-DzlYZ33mWF/Gs8DDeyjr8mnVmQGx7ASYqA5WlxwrBG4="
fi
nix_direnv_watch_file devenv.nix devenv.lock
use flake . --no-pure-eval
```

### Multiple shells

```nix
# In outputs:
devShells.${system} = {
  default = devenv.lib.mkShell {
    inherit inputs pkgs;
    modules = [ ./devenv.nix ];
  };
  backend = devenv.lib.mkShell {
    inherit inputs pkgs;
    modules = [{
      languages.java.enable = true;
      services.mysql.enable = true;
    }];
  };
  frontend = devenv.lib.mkShell {
    inherit inputs pkgs;
    modules = [{
      languages.javascript.enable = true;
    }];
  };
};
```

Enter a specific shell: `nix develop .#backend --no-pure-eval`

## Approach 2: flake-parts (recommended for multi-system)

flake-parts eliminates the manual `forEachSystem` boilerplate and provides
a modular framework. The `systems` attribute defines which platforms to build for.

### Scaffold

```bash
nix flake init --template github:cachix/devenv#flake-parts
```

### Minimal flake.nix with flake-parts

```nix
{
  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    devenv.url = "github:cachix/devenv";
    nixpkgs.url = "github:cachix/devenv-nixpkgs/rolling";
  };

  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.devenv.flakeModule ];

      systems = nixpkgs.lib.systems.flakeExposed;
      # Or be explicit:
      # systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { config, pkgs, ... }: {
        packages.default = pkgs.hello;

        devenv.shells.default = {
          packages = [ config.packages.default ];

          languages.java.enable = true;
          services.mysql.enable = true;

          enterShell = ''
            echo "Java $(java --version | head -1)"
          '';
        };
      };
    };
}
```

Key elements:
- `imports = [ inputs.devenv.flakeModule ]` — registers the devenv flake-parts module
- `systems = ...` — defines which platforms to build for (linux, macOS, x86, ARM)
- `perSystem` — config that is evaluated once per system
- `devenv.shells.default` — the devenv configuration (same options as `devenv.nix`)

### Multi-platform benefit

`nixpkgs.lib.systems.flakeExposed` covers all commonly used platforms.
The same devenv config is automatically built for every listed system.
This is the main advantage of flake-parts over the plain flake approach:
no manual `forEachSystem` iteration.

### Multiple shells with flake-parts

```nix
perSystem = { pkgs, ... }: {
  devenv.shells.default = {
    languages.java.enable = true;
    services.mysql.enable = true;
  };

  devenv.shells.frontend = {
    languages.javascript.enable = true;
  };

  devenv.shells.ci = {
    languages.java.enable = true;
    # No services — CI uses external DB
  };
};
```

### Importing a devenv module

You can extract your devenv config to a separate file:

```nix
devenv.shells.default = {
  imports = [ ./devenv.nix ];
  # Additional overrides here
};
```

### Entering the shell

```bash
nix develop --no-pure-eval           # default shell
nix develop .#frontend --no-pure-eval  # named shell
```

### Direnv with flake-parts

Same as plain flakes:

```bash
# .envrc
if ! has nix_direnv_version || ! nix_direnv_version 3.0.4; then
  source_url "https://raw.githubusercontent.com/nix-community/nix-direnv/3.0.4/direnvrc" \
    "sha256-DzlYZ33mWF/Gs8DDeyjr8mnVmQGx7ASYqA5WlxwrBG4="
fi
nix_direnv_watch_file devenv.nix devenv.lock
use flake . --no-pure-eval
```

## When to use which approach

| Scenario | Recommendation |
|---|---|
| New project, no existing flake | Standalone devenv CLI |
| Existing flake-based project | Flake integration (plain or flake-parts) |
| Single system (e.g., only x86_64-linux) | Plain flake.nix is fine |
| Multi-platform (linux + macOS, x86 + ARM) | flake-parts |
| Need evaluation caching & performance | Standalone devenv CLI |
| Dev environment consumed by downstream flakes | Flake integration |
| NixOS homelab with existing flake infra | Flake integration (compose with NixOS modules) |
