# Dendritic Pattern Examples

## User Module

A user module configures everything about a user
across all configuration classes:

```nix
# modules/users/vic.nix
let
  userName = "vic";
in
{
  flake.modules = {
    nixos.${userName} = {
      users.users.${userName} = { isNormalUser = true; };
    };

    darwin.${userName} = {
      system.primaryUser = userName;
    };

    homeManager.${userName} = {
      home.username = userName;
      # shell, git, editor, dotfiles...
    };
  };
}
```

`userName` shares across all classes through `let`,
not through `specialArgs`.

## Incremental Features

Split a growing feature into sub-files
without introducing dependencies between them:

```
modules/
  editor/
    basic.nix       # Core editor config
    lsp.nix         # Language server setup
    ai.nix          # AI completion
    _experiments.nix # Disabled (underscore prefix)
```

Each file contributes to the same aspect independently.
Prefix with `_` to temporarily disable during refactoring.

## Sharing Values via Flake-Parts Options

For values that multiple aspect files need,
define flake-parts options instead of `specialArgs`:

```nix
# modules/network-config.nix
{ lib, ... }:
{
  options.network = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "example.com";
    };
  };
}
```

```nix
# modules/ssh.nix
{ config, ... }:
{
  flake.modules.nixos.ssh = {
    # Access shared value through config
    services.openssh.banner = "Welcome to ${config.network.domain}";
  };
}
```

This replaces the `specialArgs` pattern entirely.
All modules share the same top-level `config` namespace.

## The deferredModule Type

`flake.modules.<class>.<aspect>` uses the `deferredModule` type.
This means multiple files can contribute to the same aspect
and their values merge:

```nix
# modules/ssh/server.nix
{
  flake.modules.nixos.ssh = {
    services.openssh.enable = true;
  };
}

# modules/ssh/hardening.nix
{
  flake.modules.nixos.ssh = {
    services.openssh.settings.PermitRootLogin = "no";
    services.openssh.settings.PasswordAuthentication = false;
  };
}
```

Both modules contribute to `flake.modules.nixos.ssh`.
The `deferredModule` type merges them
using standard Nixpkgs module merge semantics.

Aspect values can also be functions
to access the lower-level module arguments:

```nix
# modules/shell.nix
{ config, ... }:
{
  flake.modules.nixos.shell = nixosArgs: {
    programs.fish.enable = true;
    users.users.${config.username}.shell =
      nixosArgs.config.programs.fish.package;
  };
}
```

Here `config` is the flake-parts top-level config,
while `nixosArgs.config` is the NixOS evaluation config.

## Pinning One Package to an Older nixpkgs

A second nixpkgs input, pinned to the commit that ships the wanted version, and exactly
one package taken from it. Every other package keeps following `nixpkgs`, and
`nix flake update` never moves an input whose URL carries a commit — measured
2026-09-10: an update that moved `nixpkgs` from `661c262` to `8ce4ef6` left
`nixpkgs-duckdb` at `35d3407a`.

Find the commit with the nix-shell skill, `nix_shell.sh versions duckdb 1.5.3`, or on
nixhub.io, and let the same command confirm that cache.nixos.org holds the build before
you pin — otherwise Nix compiles it. The devenv skill's `references/pinning.md` has the
API, the measured costs and the traps in full.

```nix
# flake.nix
inputs.nixpkgs-duckdb.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac"; # duckdb 1.5.3
```

Take the package where it is needed, inside the aspect module:

```nix
# modules/duckdb.nix
{ inputs, ... }:
{
  flake.modules.homeManager.duckdb = { pkgs, ... }:
    let
      pinned = inputs.nixpkgs-duckdb.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = [ pinned.duckdb ];
    };
}
```

Or replace `pkgs.duckdb` for every module of a host, when other modules read it:

```nix
# modules/duckdb.nix
{ inputs, ... }:
{
  flake.modules.darwin.duckdb-pin = { pkgs, ... }: {
    nixpkgs.overlays = [
      (final: prev: {
        duckdb = inputs.nixpkgs-duckdb.legacyPackages.${prev.stdenv.hostPlatform.system}.duckdb;
      })
    ];
  };
}
```

`legacyPackages.${system}` is the pinned nixpkgs with its default config — the same
derivation Hydra built, so the store path matches the cache. Cost of the second input,
measured: a 52 MB tarball once, 328 MiB in the store, well under half a second more evaluation, and
on Linux a closure of its own (duckdb 1.5.3: 7 paths, 199.5 MiB, none shared with the
current nixpkgs). Moving the pin is an edit of the commit plus
`nix flake update nixpkgs-duckdb`; update tooling that walks `flake.lock` sees an
immutable pin and skips it, which is what a pin is for. Never let the pinned input
`follows` `nixpkgs` — that undoes the pin.

## Community Sharing with Dendrix

Repos can share subsets of their configuration:

```
modules/
  community/       # Shared publicly via Dendrix
    ai.nix
    macos-keys.nix
  hosts/           # Private, host-specific
    myhost/
      hardware.nix
  users/           # Private, user-specific
    vic/
      secrets.nix
```

Import community aspects from other repos:

```nix
# modules/ai.nix
{ inputs, ... }:
{
  imports = [ inputs.dendrix.some-repo.ai ];
}
```

Dendrix discovers aspects and classes from community repos,
enabling reuse of generic, host-independent configurations.

## Feature-Centric Naming

Name files around usability concerns, not technical layers:

Prefer:
- `macos-like-bindings.nix`
- `scrolling-desktop.nix`
- `tui.nix`
- `cli.nix`
- `ai.nix`

Avoid:
- `keybindings.nix` (too generic)
- `desktop.nix` (too broad)
- `packages.nix` (organized by type, not feature)

File paths serve as documentation.
A reader scanning `modules/` should understand
what the system does from file names alone.
