{ lib, config, inputs, ... }:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options.module = lib.mkOption {
        type = lib.types.deferredModule;
      };

      # Where `just nixos-deploy` activates this host. Kept here rather than in
      # the justfile so adding a server means editing only its own host module —
      # the deploy recipe never learns about individual machines. It is also the
      # first place the address is declared in Nix at all; until now it lived
      # only in AGENTS.md prose and infra/src/inventory.ts.
      options.deployTarget = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "root@87.106.149.208";
        description = "SSH destination for `just nixos-deploy`, or null to refuse deployment.";
      };
    });
    default = { };
  };

  # `{ module, ... }`, not `{ module }`: the submodule now carries deployTarget
  # too, and a closed pattern would fail to match every host at once.
  config.flake.nixosConfigurations = lib.mapAttrs
    (name: { module, ... }: inputs.nixpkgs.lib.nixosSystem { modules = [ module ]; })
    config.configurations.nixos;

  # Flat attrset so the justfile can read one target with a plain `nix eval`
  # instead of parsing the whole configuration.
  config.flake.deployTargets = lib.filterAttrs (_: v: v != null)
    (lib.mapAttrs (_: cfg: cfg.deployTarget) config.configurations.nixos);

  # Mirrors modules/darwin-wiring.nix: surface each host as a flake check so
  # `nix flake check` proves it still evaluates and builds. Keyed by the host's
  # own system, so an x86_64-linux host does not make `just check` on an
  # aarch64-darwin workstation try to build Linux without a builder — Nix only
  # realises checks for the system it is running on.
  config.flake.checks = lib.mkMerge (lib.mapAttrsToList
    (name: drv: {
      ${drv.config.nixpkgs.hostPlatform.system}."configurations:nixos:${name}" =
        drv.config.system.build.toplevel;
    })
    config.flake.nixosConfigurations);
}
