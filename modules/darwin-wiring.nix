{ lib, config, inputs, ... }:
{
  options.configurations.darwin = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.submodule {
      options.module = lib.mkOption {
        type = lib.types.deferredModule;
      };
    });
    default = { };
  };

  config.flake.darwinConfigurations = lib.mapAttrs
    (name: { module }: inputs.darwin.lib.darwinSystem { modules = [ module ]; })
    config.configurations.darwin;

  # Surface each darwinConfiguration as a flake check so `nix flake check`
  # (and `just check`) build them. Without this, flake-check only validates
  # the top-level flake, not that hosts actually evaluate.
  config.flake.checks = lib.mkMerge (lib.mapAttrsToList
    (name: drv: {
      ${drv.config.nixpkgs.hostPlatform.system}."configurations:darwin:${name}" = drv.system;
    })
    config.flake.darwinConfigurations);
}
