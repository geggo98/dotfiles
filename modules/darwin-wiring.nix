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
}
