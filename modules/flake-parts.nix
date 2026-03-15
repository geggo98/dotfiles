{ lib, inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
  flake.modules = lib.mkDefault { };
  systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
}
