{ inputs, lib, ... }:
{
  flake.overlays = {
    apple-silicon = final: prev: lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
      pkgs-x86 = import inputs.nixpkgs {
        system = "x86_64-darwin";
        config = { allowUnfree = true; };
      };
    };
  };
}
