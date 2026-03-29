{ config, inputs, lib, ... }:
{
  flake.overlays = {
    apple-silicon = final: prev: lib.optionalAttrs (prev.stdenv.hostPlatform.system == "aarch64-darwin") {
      pkgs-x86 = import inputs.nixpkgs {
        system = "x86_64-darwin";
        config = { allowUnfree = true; };
      };
    };

    fix-gcm = final: prev: {
      git-credential-manager = prev.symlinkJoin {
        name = "git-credential-manager-wrapped";
        paths = [ prev.git-credential-manager ];
        nativeBuildInputs = [ prev.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/git-credential-manager \
            --set DOTNET_SYSTEM_GLOBALIZATION_INVARIANT 1
        '';
      };
    };
  };

  flake.modules.darwin.overlays = {
    nixpkgs.overlays = lib.attrValues config.flake.overlays;
  };
}
