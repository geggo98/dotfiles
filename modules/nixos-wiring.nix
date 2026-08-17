{ lib, config, inputs, ... }:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options.module = lib.mkOption {
        type = lib.types.deferredModule;
      };
    });
    default = { };
  };

  config.flake.nixosConfigurations = lib.mapAttrs
    (name: { module }: inputs.nixpkgs.lib.nixosSystem { modules = [ module ]; })
    config.configurations.nixos;

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
